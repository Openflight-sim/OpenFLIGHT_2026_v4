# ──────────────────────────────────────────────────────────────
# solver.jl — Setup, factorization, and unit-solution computation
#              (matching AVL's asetup.f)
# ──────────────────────────────────────────────────────────────

"""
Cached AIC data for a given Mach number, avoiding refactorization.
"""
mutable struct AICData
    mach::Float64
    AICN_LU::LU{Float64, Matrix{Float64}, Vector{Int64}}
    WC_GAM::Array{Float64,3}   # (3, nvor, nvor)
    WV_GAM::Array{Float64,3}   # (3, nvor, nvor)
    valid::Bool
end

"""
    setup_aic(vl, config) → AICData

Build and LU-factor the AIC matrix. This is the expensive O(N³) step.
"""
function setup_aic(vl::VortexLattice, config::AVLConfig)
    AICN, WC_GAM, WV_GAM = build_aic_matrix(vl, config)

    nv = vl.nvor

    # apply Kutta condition for NOWAKE strips
    for strip in vl.strips
        if !strip.has_wake && strip.nelem > 0
            # last element in strip: replace its AIC row with Kutta condition
            # sum of GAM across this strip = 0
            ite = strip.ifirst + strip.nelem - 1
            if ite <= nv
                AICN[ite, :] .= 0.0
                for k in strip.ifirst:ite
                    if k <= nv
                        AICN[ite, k] = 1.0
                    end
                end
            end
        end
    end

    # LU factorize
    lu_aic = lu(AICN)

    return AICData(config.mach, lu_aic, WC_GAM, WV_GAM, true)
end

"""
    solve_unit_rhs(vl, config, aic; wcsrd_u=nothing) → (gam_u0, gam_u_d)

Solve for unit-freestream circulations:
- gam_u0[i, iu]: circulation at element i for unit freestream component iu (u,v,w,p,q,r)
- gam_u_d[i, iu, n]: d(gam_u)/d(control n) for unit component iu
- wcsrd_u: optional body-source velocity influence (3, nvor, 6)
"""
function solve_unit_rhs(vl::VortexLattice, config::AVLConfig, aic::AICData;
                        wcsrd_u::Union{Nothing,Array{Float64,3}}=nothing)
    nv = vl.nvor
    nc = vl.ncontrol

    gam_u0 = zeros(nv, NUMAX)
    gam_u_d = zeros(nv, NUMAX, nc)

    for iu in 1:NUMAX
        rhs = zeros(nv)
        rhs_d = zeros(nv, nc)

        for i in 1:nv
            elem = vl.elements[i]
            strip = vl.strips[elem.istrip]

            if !strip.has_wake || true  # flow-tangency BC for all normal rows
                # unit velocity vector for component iu
                vunit = _unit_velocity(iu, elem, strip, config)

                # add body-source velocity influence (matching GUCALC in asetup.f)
                if wcsrd_u !== nothing && size(wcsrd_u, 2) >= i
                    vunit = (vunit[1] + wcsrd_u[1,i,iu],
                             vunit[2] + wcsrd_u[2,i,iu],
                             vunit[3] + wcsrd_u[3,i,iu])
                end

                # RHS = -dot(enc, vunit)
                rhs[i] = -(elem.enc[1]*vunit[1] + elem.enc[2]*vunit[2] + elem.enc[3]*vunit[3])

                # control sensitivity of RHS
                for n in 1:nc
                    enc_d = (vl.enc_d[1,i,n], vl.enc_d[2,i,n], vl.enc_d[3,i,n])
                    rhs_d[i, n] = -(enc_d[1]*vunit[1] + enc_d[2]*vunit[2] + enc_d[3]*vunit[3])
                end
            end

            # Kutta condition rows have RHS = 0
            if !strip.has_wake && i == strip.ifirst + strip.nelem - 1
                rhs[i] = 0.0
                rhs_d[i, :] .= 0.0
            end
        end

        # solve via LU
        gam_u0[:, iu] = aic.AICN_LU \ rhs

        for n in 1:nc
            gam_u_d[:, iu, n] = aic.AICN_LU \ rhs_d[:, n]
        end
    end

    return gam_u0, gam_u_d
end

"""Compute unit velocity vector for component iu at an element."""
function _unit_velocity(iu::Int, elem::VortexElement, strip::Strip, config::AVLConfig)
    # iu: 1=u, 2=v, 3=w (freestream), 4=p, 5=q, 6=r (rotation)
    if !strip.sees_freestream
        return (0.0, 0.0, 0.0)
    end

    if iu <= 3
        # direct freestream component
        v = [0.0, 0.0, 0.0]
        v[iu] = 1.0
        return (v[1], v[2], v[3])
    else
        # rotation: v = omega × r where omega has one unit component
        # r is vector from rotation center (xyzref) to control point
        rx = elem.rc[1] - config.xyzref[1]
        ry = elem.rc[2] - config.xyzref[2]
        rz = elem.rc[3] - config.xyzref[3]

        if iu == 4  # p (roll rate): omega = (1, 0, 0)
            return (0.0, -rz, ry)
        elseif iu == 5  # q (pitch rate): omega = (0, 1, 0)
            return (rz, 0.0, -rx)
        else  # r (yaw rate): omega = (0, 0, 1)
            return (-ry, rx, 0.0)
        end
    end
end

"""
    compute_gammas(vl, config, gam_u0, gam_u_d, vinf, wrot, delcon) → (gam, gam_u, gam_d)

Combine unit solutions into actual circulation distribution.
"""
function compute_gammas(vl::VortexLattice, config::AVLConfig,
                        gam_u0::Matrix{Float64}, gam_u_d::Array{Float64,3},
                        vinf::NTuple{3,Float64}, wrot::NTuple{3,Float64},
                        delcon::Vector{Float64})
    nv = vl.nvor
    nc = vl.ncontrol

    # combine unit solutions with control deflections
    gam_u = zeros(nv, NUMAX)
    for iu in 1:NUMAX
        for i in 1:nv
            gam_u[i, iu] = gam_u0[i, iu]
            for n in 1:nc
                gam_u[i, iu] += gam_u_d[i, iu, n] * delcon[n]
            end
        end
    end

    # total circulation: GAM = sum over iu of gam_u * q_iu
    q = [vinf[1], vinf[2], vinf[3], wrot[1], wrot[2], wrot[3]]
    gam = gam_u * q

    # control sensitivities
    gam_d = zeros(nv, nc)
    for n in 1:nc
        for i in 1:nv
            for iu in 1:NUMAX
                gam_d[i, n] += gam_u_d[i, iu, n] * q[iu]
            end
        end
    end

    return gam, gam_u, gam_d
end

"""
    compute_velocities(aic, gam, vinf, wrot, vl, config) → (wv, wc)

Compute induced velocities at vortex midpoints and control points.
"""
function compute_velocities(aic::AICData, gam::Vector{Float64},
                            vinf::NTuple{3,Float64}, wrot::NTuple{3,Float64},
                            vl::VortexLattice, config::AVLConfig)
    nv = vl.nvor

    # wv[k, i] = sum_j WV_GAM[k, i, j] * gam[j] + freestream + rotation
    wv = zeros(3, nv)
    wc = zeros(3, nv)

    # matrix-vector multiply for induced velocity
    for i in 1:nv
        for j in 1:nv
            wv[1, i] += aic.WV_GAM[1, i, j] * gam[j]
            wv[2, i] += aic.WV_GAM[2, i, j] * gam[j]
            wv[3, i] += aic.WV_GAM[3, i, j] * gam[j]

            wc[1, i] += aic.WC_GAM[1, i, j] * gam[j]
            wc[2, i] += aic.WC_GAM[2, i, j] * gam[j]
            wc[3, i] += aic.WC_GAM[3, i, j] * gam[j]
        end
    end

    return wv, wc
end
