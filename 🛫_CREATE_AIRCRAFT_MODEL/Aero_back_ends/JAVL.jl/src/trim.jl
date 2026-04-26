# ──────────────────────────────────────────────────────────────
# trim.jl — Newton iteration for trim / operating-point solution
#            (matching AVL's aoper.f/EXEC)
# ──────────────────────────────────────────────────────────────

"""
    vinfab(alpha, beta) → (vinf, vinf_a, vinf_b)

Compute freestream velocity vector from angle of attack and sideslip.
Returns unit velocity and its derivatives w.r.t. alpha and beta.
"""
function vinfab(alpha::Float64, beta::Float64)
    ca = cos(alpha); sa = sin(alpha)
    cb = cos(beta);  sb = sin(beta)

    vinf = (ca*cb, -sb, sa*cb)
    vinf_a = (-sa*cb, 0.0, ca*cb)   # d(vinf)/d(alpha)
    vinf_b = (-ca*sb, -cb, -sa*sb)  # d(vinf)/d(beta)

    return vinf, vinf_a, vinf_b
end

"""
    exec_case!(sol, vl, config, aic, gam_u0, gam_u_d, rc; niter=20, src_u=nothing, wvsrd_u=nothing)

Execute the Newton iteration to solve for the operating point defined by run case rc.
wvsrd_u: body-source unit velocity at vortex midpoints (3, nvor, 6), added to sol.wv for forces.
"""
function exec_case!(sol::AVLSolution, vl::VortexLattice, config::AVLConfig,
                    aic::AICData, gam_u0::Matrix{Float64}, gam_u_d::Array{Float64,3},
                    rc::RunCase; niter::Int=20,
                    src_u::Union{Nothing,Matrix{Float64}}=nothing,
                    wvsrd_u::Union{Nothing,Array{Float64,3}}=nothing)
    nc = vl.ncontrol
    nvtot = IVTOT + nc
    eps_conv = 2e-5

    # initialize operating point from run case parameters
    alpha = rc.parval[IPALFA]
    beta = rc.parval[IPBETA]
    wrot = (rc.parval[IPROTX], rc.parval[IPROTY], rc.parval[IPROTZ])
    delcon = zeros(nc)

    # set CG location
    config_work = deepcopy(config)
    if rc.parval[IPXCG] != 0.0 || rc.parval[IPYCG] != 0.0 || rc.parval[IPZCG] != 0.0
        config_work = deepcopy(config)  # avoid modifying original
        config_work.xyzref = (rc.parval[IPXCG], rc.parval[IPYCG], rc.parval[IPZCG])
    end

    sol.mach = rc.parval[IPMACH]

    # first pass: set variables that are directly constrained
    for iv in 1:nvtot
        ic = iv <= length(rc.icon) ? rc.icon[iv] : 0
        ic <= 0 && continue
        cv = ic <= length(rc.conval) ? rc.conval[ic] : 0.0

        if iv == IVALFA && ic == ICALFA
            alpha = cv
        elseif iv == IVBETA && ic == ICBETA
            beta = cv
        elseif iv == IVROTX && ic == ICROTX
            wrot = (cv * 2.0 / config.bref, wrot[2], wrot[3])
        elseif iv == IVROTY && ic == ICROTY
            wrot = (wrot[1], cv * 2.0 / config.cref, wrot[3])
        elseif iv == IVROTZ && ic == ICROTZ
            wrot = (wrot[1], wrot[2], cv * 2.0 / config.bref)
        elseif iv > IVTOT && ic > ICTOT
            n = iv - IVTOT
            if n <= nc
                delcon[n] = cv  # control deflection in radians
            end
        end
    end

    # Newton iteration
    for iter in 1:niter
        # compute flow
        vinf, vinf_a, vinf_b = vinfab(alpha, beta)
        sol.alpha = alpha
        sol.beta = beta
        sol.vinf = vinf
        sol.wrot = wrot
        sol.delcon = nc > 0 ? copy(delcon) : Float64[]

        # solve for circulations
        gam, gam_u, gam_d = compute_gammas(vl, config_work, gam_u0, gam_u_d,
                                             vinf, wrot, delcon)
        sol.gam = gam
        sol.gam_u = gam_u
        sol.gam_d = gam_d

        # compute velocities (horseshoe-induced only = VV in Fortran)
        wv, wc = compute_velocities(aic, gam, vinf, wrot, vl, config_work)
        sol.wv = wv
        # Note: Fortran's LNFLD_WV flag (default FALSE) controls whether body
        # source velocity (WVSRD) is added to VEFF for force computation.
        # When FALSE (default), forces use VV only (no body velocity in VEFF).
        # The wvsrd_u infrastructure is kept for future LNFLD_WV=TRUE support.

        # compute forces
        sol.dcp = zeros(vl.nvor)
        compute_forces!(sol, vl, config_work, aic, gam_u0, gam_u_d)

        # body forces
        if src_u !== nothing && vl.nbody > 0
            src = compute_body_src(src_u, vinf, wrot)
            body_forces!(sol, vl, config_work, src, src_u)
        end

        # Trefftz plane
        trefftz_drag!(sol, vl, config_work)

        # build Newton system
        nvar = nvtot
        vsys = zeros(nvar, nvar)
        vres = zeros(nvar)

        for iv in 1:nvtot
            ic = iv <= length(rc.icon) ? rc.icon[iv] : 0
            ic <= 0 && continue
            cv = ic <= length(rc.conval) ? rc.conval[ic] : 0.0

            # residual for this constraint
            if ic == ICALFA
                vres[iv] = alpha - cv
            elseif ic == ICBETA
                vres[iv] = beta - cv
            elseif ic == ICROTX
                vres[iv] = wrot[1]*config.bref/2.0 - cv
            elseif ic == ICROTY
                vres[iv] = wrot[2]*config.cref/2.0 - cv
            elseif ic == ICROTZ
                vres[iv] = wrot[3]*config.bref/2.0 - cv
            elseif ic == ICCL
                vres[iv] = sol.cl - cv
            elseif ic == ICCY
                vres[iv] = sol.cy - cv
            elseif ic == ICMOMX
                ca = cos(alpha); sa = sin(alpha)
                vres[iv] = sol.cmx*ca + sol.cmz*sa - cv
            elseif ic == ICMOMY
                vres[iv] = sol.cmy - cv
            elseif ic == ICMOMZ
                ca = cos(alpha); sa = sin(alpha)
                vres[iv] = sol.cmz*ca - sol.cmx*sa - cv
            elseif ic > ICTOT
                n = ic - ICTOT
                if n <= nc
                    vres[iv] = delcon[n] - cv
                end
            end

            # Jacobian row: d(residual)/d(variable_jv)
            for jv in 1:nvtot
                if ic == ICALFA
                    vsys[iv, jv] = (jv == IVALFA) ? 1.0 : 0.0
                elseif ic == ICBETA
                    vsys[iv, jv] = (jv == IVBETA) ? 1.0 : 0.0
                elseif ic == ICROTX
                    vsys[iv, jv] = (jv == IVROTX) ? config.bref/2.0 : 0.0
                elseif ic == ICROTY
                    vsys[iv, jv] = (jv == IVROTY) ? config.cref/2.0 : 0.0
                elseif ic == ICROTZ
                    vsys[iv, jv] = (jv == IVROTZ) ? config.bref/2.0 : 0.0
                elseif ic == ICCL
                    vsys[iv, jv] = _dcl_dvar(jv, sol, config_work, vinf_a, vinf_b, nc)
                elseif ic == ICCY
                    vsys[iv, jv] = _dcy_dvar(jv, sol, config_work, vinf_a, vinf_b, nc)
                elseif ic == ICMOMX
                    ca = cos(alpha); sa = sin(alpha)
                    dcmx = _dcmx_dvar(jv, sol, config_work, vinf_a, vinf_b, nc)
                    dcmz = _dcmz_dvar(jv, sol, config_work, vinf_a, vinf_b, nc)
                    vsys[iv, jv] = dcmx*ca + dcmz*sa
                    if jv == IVALFA
                        vsys[iv, jv] += -sol.cmx*sa + sol.cmz*ca  # d/dalpha of ca,sa
                    end
                elseif ic == ICMOMY
                    vsys[iv, jv] = _dcmy_dvar(jv, sol, config_work, vinf_a, vinf_b, nc)
                elseif ic == ICMOMZ
                    ca = cos(alpha); sa = sin(alpha)
                    dcmx = _dcmx_dvar(jv, sol, config_work, vinf_a, vinf_b, nc)
                    dcmz = _dcmz_dvar(jv, sol, config_work, vinf_a, vinf_b, nc)
                    vsys[iv, jv] = dcmz*ca - dcmx*sa
                    if jv == IVALFA
                        vsys[iv, jv] += -sol.cmz*sa - sol.cmx*ca
                    end
                elseif ic > ICTOT
                    n = ic - ICTOT
                    if jv > IVTOT && (jv - IVTOT) == n
                        vsys[iv, jv] = 1.0
                    end
                end
            end
        end

        # check convergence
        maxres = maximum(abs.(vres))
        if maxres < eps_conv
            sol.converged = true
            sol.iterations = iter
            return
        end

        # solve Newton update
        local dvars::Vector{Float64}
        try
            dvars = vsys \ vres
        catch
            @warn "Newton system singular at iteration $iter"
            sol.converged = false
            sol.iterations = iter
            return
        end

        # apply updates with limiting
        dmax = π/2
        for iv in 1:nvtot
            if iv == IVALFA
                alpha -= clamp(dvars[iv], -dmax, dmax)
            elseif iv == IVBETA
                beta -= clamp(dvars[iv], -dmax, dmax)
            elseif iv == IVROTX
                wrot = (wrot[1] - clamp(dvars[iv], -dmax, dmax), wrot[2], wrot[3])
            elseif iv == IVROTY
                wrot = (wrot[1], wrot[2] - clamp(dvars[iv], -dmax, dmax), wrot[3])
            elseif iv == IVROTZ
                wrot = (wrot[1], wrot[2], wrot[3] - clamp(dvars[iv], -dmax, dmax))
            elseif iv > IVTOT
                n = iv - IVTOT
                if n <= nc
                    delcon[n] -= clamp(dvars[iv], -dmax, dmax)
                end
            end
        end
    end

    sol.converged = false
    sol.iterations = niter
end

# ── Jacobian helper functions ───────────────────────────────

function _dcl_dvar(jv, sol, config, vinf_a, vinf_b, nc)
    ca = cos(sol.alpha); sa = sin(sol.alpha)
    if jv == IVALFA
        # d(CL)/d(alpha): CL = CFZ*ca - CFX*sa
        # d(CL)/d(alpha) = dCL/dvinf * dvinf/dalpha + (-CFZ*sa - CFX*ca)
        dcl = sol.cl_u[1]*vinf_a[1] + sol.cl_u[2]*vinf_a[2] + sol.cl_u[3]*vinf_a[3]
        dcl += (-sol.cfz*sa - sol.cfx*ca)
        return dcl
    elseif jv == IVBETA
        return sol.cl_u[1]*vinf_b[1] + sol.cl_u[2]*vinf_b[2] + sol.cl_u[3]*vinf_b[3]
    elseif jv == IVROTX
        return sol.cl_u[4]
    elseif jv == IVROTY
        return sol.cl_u[5]
    elseif jv == IVROTZ
        return sol.cl_u[6]
    elseif jv > IVTOT
        n = jv - IVTOT
        return n <= nc ? sol.cl_d[n] : 0.0
    end
    return 0.0
end

function _dcy_dvar(jv, sol, config, vinf_a, vinf_b, nc)
    if jv == IVALFA
        return sol.cy_u[1]*cos(sol.vinf[1]) # simplified
    elseif jv == IVBETA
        return sol.cy_u[1]*vinf_b[1] + sol.cy_u[2]*vinf_b[2] + sol.cy_u[3]*vinf_b[3]
    elseif jv == IVROTX
        return sol.cy_u[4]
    elseif jv == IVROTY
        return sol.cy_u[5]
    elseif jv == IVROTZ
        return sol.cy_u[6]
    elseif jv > IVTOT
        n = jv - IVTOT
        return n <= nc ? sol.cy_d[n] : 0.0
    end
    return 0.0
end

function _dcmx_dvar(jv, sol, config, vinf_a, vinf_b, nc)
    if jv == IVALFA
        return sol.cmx_u[1]*vinf_a[1] + sol.cmx_u[2]*vinf_a[2] + sol.cmx_u[3]*vinf_a[3]
    elseif jv == IVBETA
        return sol.cmx_u[1]*vinf_b[1] + sol.cmx_u[2]*vinf_b[2] + sol.cmx_u[3]*vinf_b[3]
    elseif jv == IVROTX; return sol.cmx_u[4]
    elseif jv == IVROTY; return sol.cmx_u[5]
    elseif jv == IVROTZ; return sol.cmx_u[6]
    elseif jv > IVTOT
        n = jv - IVTOT
        return n <= nc ? sol.cmx_d[n] : 0.0
    end
    return 0.0
end

function _dcmy_dvar(jv, sol, config, vinf_a, vinf_b, nc)
    if jv == IVALFA
        return sol.cmy_u[1]*vinf_a[1] + sol.cmy_u[2]*vinf_a[2] + sol.cmy_u[3]*vinf_a[3]
    elseif jv == IVBETA
        return sol.cmy_u[1]*vinf_b[1] + sol.cmy_u[2]*vinf_b[2] + sol.cmy_u[3]*vinf_b[3]
    elseif jv == IVROTX; return sol.cmy_u[4]
    elseif jv == IVROTY; return sol.cmy_u[5]
    elseif jv == IVROTZ; return sol.cmy_u[6]
    elseif jv > IVTOT
        n = jv - IVTOT
        return n <= nc ? sol.cmy_d[n] : 0.0
    end
    return 0.0
end

function _dcmz_dvar(jv, sol, config, vinf_a, vinf_b, nc)
    if jv == IVALFA
        return sol.cmz_u[1]*vinf_a[1] + sol.cmz_u[2]*vinf_a[2] + sol.cmz_u[3]*vinf_a[3]
    elseif jv == IVBETA
        return sol.cmz_u[1]*vinf_b[1] + sol.cmz_u[2]*vinf_b[2] + sol.cmz_u[3]*vinf_b[3]
    elseif jv == IVROTX; return sol.cmz_u[4]
    elseif jv == IVROTY; return sol.cmz_u[5]
    elseif jv == IVROTZ; return sol.cmz_u[6]
    elseif jv > IVTOT
        n = jv - IVTOT
        return n <= nc ? sol.cmz_d[n] : 0.0
    end
    return 0.0
end
