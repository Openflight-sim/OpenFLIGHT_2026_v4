# ──────────────────────────────────────────────────────────────
# aero.jl — Near-field force and moment calculations
#            (matching AVL's aero.f / SFFORC)
# ──────────────────────────────────────────────────────────────

"""
    compute_forces!(sol, vl, config, aic, gam_u0, gam_u_d)

Compute all aerodynamic forces and moments via Kutta-Joukowski integration.
Updates sol in-place with total and per-strip forces.
"""
function compute_forces!(sol::AVLSolution, vl::VortexLattice, config::AVLConfig,
                         aic::AICData, gam_u0::Matrix{Float64}, gam_u_d::Array{Float64,3})
    nv = vl.nvor
    nc = vl.ncontrol
    alpha = sol.alpha
    beta = sol.beta
    vinf = sol.vinf
    wrot = sol.wrot
    sref = config.sref
    cref = config.cref
    bref = config.bref
    xyzref = config.xyzref

    # reset totals
    cfx_tot = 0.0; cfy_tot = 0.0; cfz_tot = 0.0
    cmx_tot = 0.0; cmy_tot = 0.0; cmz_tot = 0.0
    cdv_tot = 0.0

    # unit-component force sensitivities
    cfx_u = zeros(NUMAX); cfy_u = zeros(NUMAX); cfz_u = zeros(NUMAX)
    cmx_u = zeros(NUMAX); cmy_u = zeros(NUMAX); cmz_u = zeros(NUMAX)

    # control force sensitivities
    cfx_d = zeros(nc); cfy_d = zeros(nc); cfz_d = zeros(nc)
    cmx_d = zeros(nc); cmy_d = zeros(nc); cmz_d = zeros(nc)

    # hinge moments
    chinge = zeros(nc)

    # per-strip results
    nstrip = vl.nstrip
    strip_cl = zeros(nstrip)
    strip_cd = zeros(nstrip)
    strip_cnc = zeros(nstrip)

    q = [vinf[1], vinf[2], vinf[3], wrot[1], wrot[2], wrot[3]]

    for js in 1:nstrip
        strip = vl.strips[js]
        !strip.contributes_load && continue

        s_cfx = 0.0; s_cfy = 0.0; s_cfz = 0.0
        s_cmx = 0.0; s_cmy = 0.0; s_cmz = 0.0
        s_cnc = 0.0

        for k in 1:strip.nelem
            ie = strip.ifirst + k - 1
            ie > nv && continue

            elem = vl.elements[ie]
            gam_i = sol.gam[ie]

            # bound leg vector
            gx = elem.rv2[1] - elem.rv1[1]
            gy = elem.rv2[2] - elem.rv1[2]
            gz = elem.rv2[3] - elem.rv1[3]

            # effective velocity at vortex midpoint
            veff_x = vinf[1] + sol.wv[1, ie]
            veff_y = vinf[2] + sol.wv[2, ie]
            veff_z = vinf[3] + sol.wv[3, ie]

            # add rotation velocity: v_rot = wrot × (rv - xyzref)
            rx = elem.rv[1] - xyzref[1]
            ry = elem.rv[2] - xyzref[2]
            rz = elem.rv[3] - xyzref[3]
            veff_x += wrot[2]*rz - wrot[3]*ry
            veff_y += wrot[3]*rx - wrot[1]*rz
            veff_z += wrot[1]*ry - wrot[2]*rx

            # Kutta-Joukowski: F = 2 * GAM * (Veff × G)
            # factor of 2 from normalization (q_inf = 0.5*rho*V^2, V=1)
            fx = 2.0 * gam_i * (veff_y*gz - veff_z*gy)
            fy = 2.0 * gam_i * (veff_z*gx - veff_x*gz)
            fz = 2.0 * gam_i * (veff_x*gy - veff_y*gx)

            # normalize to coefficients
            fx /= sref; fy /= sref; fz /= sref

            s_cfx += fx; s_cfy += fy; s_cfz += fz

            # moment about reference point
            dx = elem.rv[1] - xyzref[1]
            dy = elem.rv[2] - xyzref[2]
            dz = elem.rv[3] - xyzref[3]
            s_cmx += (dy*fz - dz*fy) / bref
            s_cmy += (dz*fx - dx*fz) / cref
            s_cmz += (dx*fy - dy*fx) / bref

            # delta Cp
            dxv = max(elem.dxv, 1e-20)
            wstr = max(strip.wstrip, 1e-20)
            # DCP = dot(env, F_gam) / (dxv * wstrip)
            fgam_x = 2.0 * gam_i * (veff_y*gz - veff_z*gy)
            fgam_y = 2.0 * gam_i * (veff_z*gx - veff_x*gz)
            fgam_z = 2.0 * gam_i * (veff_x*gy - veff_y*gx)
            sol.dcp[ie] = (elem.env[1]*fgam_x + elem.env[2]*fgam_y + elem.env[3]*fgam_z) /
                          (dxv * wstr * sref)

            # spanloading c*Cn
            s_cnc += 2.0 * gam_i * sqrt(gx^2 + gy^2 + gz^2) / sref

            # ── Force sensitivities ──
            # d(force)/d(q_iu) via chain rule through gam and veff
            for iu in 1:NUMAX
                gam_u_i = sol.gam_u[ie, iu]

                # d(veff)/d(q_iu) from freestream + body velocities
                # (ignoring induced velocity sensitivity for simplicity in first version)
                dveff = _unit_velocity(iu, elem, strip, config)

                dfx = 2.0 * (gam_u_i * (veff_y*gz - veff_z*gy) +
                              gam_i * (dveff[2]*gz - dveff[3]*gy)) / sref
                dfy = 2.0 * (gam_u_i * (veff_z*gx - veff_x*gz) +
                              gam_i * (dveff[3]*gx - dveff[1]*gz)) / sref
                dfz = 2.0 * (gam_u_i * (veff_x*gy - veff_y*gx) +
                              gam_i * (dveff[1]*gy - dveff[2]*gx)) / sref

                cfx_u[iu] += dfx
                cfy_u[iu] += dfy
                cfz_u[iu] += dfz
                cmx_u[iu] += (dy*dfz - dz*dfy) / bref
                cmy_u[iu] += (dz*dfx - dx*dfz) / cref
                cmz_u[iu] += (dx*dfy - dy*dfx) / bref
            end

            # d(force)/d(control)
            for n in 1:nc
                gam_d_i = sol.gam_d[ie, n]
                dfx = 2.0 * gam_d_i * (veff_y*gz - veff_z*gy) / sref
                dfy = 2.0 * gam_d_i * (veff_z*gx - veff_x*gz) / sref
                dfz = 2.0 * gam_d_i * (veff_x*gy - veff_y*gx) / sref

                cfx_d[n] += dfx
                cfy_d[n] += dfy
                cfz_d[n] += dfz
                cmx_d[n] += (dy*dfz - dz*dfy) / bref
                cmy_d[n] += (dz*dfx - dx*dfz) / cref
                cmz_d[n] += (dx*dfy - dy*dfx) / bref

                # hinge moment (simplified)
                if abs(vl.dcontrol[ie, n]) > 1e-20
                    chinge[n] += s_cmy  # approximate
                end
            end
        end

        # viscous drag for this strip
        if strip.has_cdcl && length(strip.cdcl) >= 6
            # compute strip lift coefficient
            cl_strip = _strip_cl(s_cfx, s_cfy, s_cfz, alpha)
            cdv = _cdcl_lookup(cl_strip, strip.cdcl)
            cdv_force = cdv * strip.wstrip * strip.chord / sref
            cdv_tot += cdv_force
        end

        # accumulate
        cfx_tot += s_cfx; cfy_tot += s_cfy; cfz_tot += s_cfz
        cmx_tot += s_cmx; cmy_tot += s_cmy; cmz_tot += s_cmz
        strip_cnc[js] = s_cnc

        # strip Cl (projection onto lift direction)
        area_strip = strip.wstrip * strip.chord
        if area_strip > 1e-30
            strip_cl[js] = _strip_cl(s_cfx, s_cfy, s_cfz, alpha) * sref / area_strip
        end
    end

    # apply symmetry doubling for iysym
    if config.iysym == 1
        cfx_tot *= 2.0; cfz_tot *= 2.0  # symmetric
        cmy_tot *= 2.0
        cfy_tot = 0.0; cmx_tot = 0.0; cmz_tot = 0.0  # antisymmetric → zero
        cfx_u .*= 2.0; cfz_u .*= 2.0; cmy_u .*= 2.0
        cfx_d .*= 2.0; cfz_d .*= 2.0; cmy_d .*= 2.0
        cdv_tot *= 2.0
    end

    # transform to stability axes
    # In our convention: CFZ positive = upward (lift direction)
    # CL = CFZ*cos(alpha) - CFX*sin(alpha)  (projection onto lift axis)
    # CD = CFX*cos(alpha) + CFZ*sin(alpha)  (projection onto drag axis)
    ca = cos(alpha); sa = sin(alpha)
    cl_tot =  cfz_tot*ca - cfx_tot*sa
    cd_tot =  cfx_tot*ca + cfz_tot*sa

    # store results
    sol.cfx = cfx_tot; sol.cfy = cfy_tot; sol.cfz = cfz_tot
    sol.cmx = cmx_tot; sol.cmy = cmy_tot; sol.cmz = cmz_tot
    sol.cl = cl_tot
    sol.cd = cd_tot + config.cdref
    sol.cdi = cd_tot
    sol.cdv = cdv_tot
    sol.cy = cfy_tot

    # stability axis moments
    sol.cmx_s = cmx_tot*ca + cmz_tot*sa
    sol.cmz_s = cmz_tot*ca - cmx_tot*sa

    sol.chinge = chinge

    # stability derivatives: transform body-axis force sensitivities
    for iu in 1:NUMAX
        cl_u =  cfz_u[iu]*ca - cfx_u[iu]*sa
        cd_u =  cfx_u[iu]*ca + cfz_u[iu]*sa
        sol.cl_u[iu] = cl_u
        sol.cd_u[iu] = cd_u
        sol.cy_u[iu] = cfy_u[iu]
        sol.cmx_u[iu] = cmx_u[iu]
        sol.cmy_u[iu] = cmy_u[iu]
        sol.cmz_u[iu] = cmz_u[iu]
    end
    for n in 1:nc
        sol.cl_d[n] =  cfz_d[n]*ca - cfx_d[n]*sa
        sol.cd_d[n] =  cfx_d[n]*ca + cfz_d[n]*sa
        sol.cy_d[n] = cfy_d[n]
        sol.cmx_d[n] = cmx_d[n]
        sol.cmy_d[n] = cmy_d[n]
        sol.cmz_d[n] = cmz_d[n]
    end

    sol.strip_cl = strip_cl
    sol.strip_cd = strip_cd
    sol.strip_cnc = strip_cnc

    return nothing
end

"""Compute strip CL from body-axis forces and angle of attack."""
function _strip_cl(cfx, cfy, cfz, alpha)
    ca = cos(alpha); sa = sin(alpha)
    return cfz*ca - cfx*sa
end

"""Look up viscous CD from piecewise-parabolic CD(CL) polar."""
function _cdcl_lookup(cl::Float64, cdcl::Vector{Float64})
    length(cdcl) < 6 && return 0.0
    cl1 = cdcl[1]; cd1 = cdcl[2]
    cl2 = cdcl[3]; cd2 = cdcl[4]
    cl3 = cdcl[5]; cd3 = cdcl[6]

    if cl <= cl2
        # lower parabola
        dcl = cl2 - cl1
        abs(dcl) < 1e-20 && return cd2
        t = (cl - cl1) / dcl
        return cd1 + (cd2 - cd1) * t^2   # parabolic
    else
        # upper parabola
        dcl = cl3 - cl2
        abs(dcl) < 1e-20 && return cd2
        t = (cl - cl2) / dcl
        return cd2 + (cd3 - cd2) * t^2
    end
end
