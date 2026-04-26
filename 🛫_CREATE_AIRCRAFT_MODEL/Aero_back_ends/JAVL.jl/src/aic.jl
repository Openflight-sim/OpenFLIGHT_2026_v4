# ──────────────────────────────────────────────────────────────
# aic.jl — Aerodynamic Influence Coefficients (Biot-Savart)
#           (matching AVL's aic.f)
# ──────────────────────────────────────────────────────────────

"""
    horseshoe_velocity(xp, yp, zp, x1, y1, z1, x2, y2, z2, rcore) → (u, v, w)

Compute velocity induced at point (xp,yp,zp) by a unit horseshoe vortex
with bound leg from (x1,y1,z1) to (x2,y2,z2) and two semi-infinite
trailing legs in the +x direction. Uses Leishman R⁴ finite-core model
(matching AVL's VORVELC).
"""
function horseshoe_velocity(xp::Float64, yp::Float64, zp::Float64,
                            x1::Float64, y1::Float64, z1::Float64,
                            x2::Float64, y2::Float64, z2::Float64,
                            rcore::Float64)
    u = 0.0; v = 0.0; w = 0.0
    inv4pi = 1.0 / (4.0 * π)

    # ── Bound vortex segment (1 → 2) ──────────────────────
    ax = xp - x1; ay = yp - y1; az = zp - z1
    bx = xp - x2; by = yp - y2; bz = zp - z2

    # cross product A × B
    cx = ay*bz - az*by
    cy = az*bx - ax*bz
    cz = ax*by - ay*bx

    asq = ax^2 + ay^2 + az^2
    bsq = bx^2 + by^2 + bz^2
    amag = sqrt(asq)
    bmag = sqrt(bsq)

    # |A × B|²
    cmagsq = cx^2 + cy^2 + cz^2
    rcore4 = rcore^4

    if amag > 1e-20 && bmag > 1e-20 && cmagsq > 1e-30
        adb = ax*bx + ay*by + az*bz      # A · B
        alsq = asq + bsq - 2.0*adb       # |P1-P2|² (bound leg length²)

        # Leishman R⁴ core model (matching AVL's VORVELC):
        # regularize |A|, |B|, and |A×B|² individually
        amag_reg = sqrt(sqrt(asq^2 + rcore4))
        bmag_reg = sqrt(sqrt(bsq^2 + rcore4))
        denom = sqrt(cmagsq^2 + alsq^2 * rcore4)

        if denom > 1e-30
            T = ((bsq - adb)/bmag_reg + (asq - adb)/amag_reg) / denom

            u += cx * T * inv4pi
            v += cy * T * inv4pi
            w += cz * T * inv4pi
        end
    end

    # ── Trailing leg from point 1 (+∞ → rv1, direction -x) ───
    # Horseshoe circuit: +∞ → rv1 → rv2 → +∞
    # This leg goes from +∞ to rv1, which is the REVERSE of rv1→+∞,
    # so we negate the standard semi-infinite vortex formula.
    rsq1 = (yp-y1)^2 + (zp-z1)^2
    rsq1_reg = sqrt(rsq1^2 + rcore4)

    if rsq1_reg > 1e-30
        r1 = sqrt((xp-x1)^2 + rsq1)
        factor1 = inv4pi * (1.0 + (xp-x1)/max(r1,1e-20)) * rsq1 / rsq1_reg

        if rsq1 > 1e-30
            v +=  (zp-z1) * factor1 / rsq1
            w += -(yp-y1) * factor1 / rsq1
        end
    end

    # ── Trailing leg from point 2 (rv2 → +∞, direction +x) ───
    # Standard semi-infinite vortex from rv2 to +∞.
    rsq2 = (yp-y2)^2 + (zp-z2)^2
    rsq2_reg = sqrt(rsq2^2 + rcore4)

    if rsq2_reg > 1e-30
        r2 = sqrt((xp-x2)^2 + rsq2)
        factor2 = inv4pi * (1.0 + (xp-x2)/max(r2,1e-20)) * rsq2 / rsq2_reg

        if rsq2 > 1e-30
            v += -(zp-z2) * factor2 / rsq2
            w +=  (yp-y2) * factor2 / rsq2
        end
    end

    return (u, v, w)
end

"""
    build_aic_matrix(vl, config) → (AICN, WC_GAM, WV_GAM)

Build the aerodynamic influence coefficient matrices:
- AICN[i,j]: normalwash at control point i due to unit vortex j
- WC_GAM[3,i,j]: velocity at control point i due to unit vortex j
- WV_GAM[3,i,j]: velocity at vortex midpoint i due to unit vortex j
"""
function build_aic_matrix(vl::VortexLattice, config::AVLConfig)
    nv = vl.nvor
    mach = config.mach
    beta_pg = sqrt(max(1.0 - mach^2, 0.01))  # Prandtl-Glauert factor

    iysym = config.iysym
    izsym = config.izsym
    ysym = config.ysym
    zsym = config.zsym

    AICN = zeros(nv, nv)
    WC_GAM = zeros(3, nv, nv)
    WV_GAM = zeros(3, nv, nv)

    # compute velocities at control points
    for j in 1:nv
        ej = vl.elements[j]
        # bound vortex endpoints (with PG correction)
        x1 = ej.rv1[1] / beta_pg; y1 = ej.rv1[2]; z1 = ej.rv1[3]
        x2 = ej.rv2[1] / beta_pg; y2 = ej.rv2[2]; z2 = ej.rv2[3]

        for i in 1:nv
            ei = vl.elements[i]

            # determine core radius
            rcore = _compute_core_radius(ei, ej, config, vl)

            # control point (with PG correction)
            xp = ei.rc[1] / beta_pg
            yp = ei.rc[2]
            zp = ei.rc[3]

            # real horseshoe
            u, v, w = horseshoe_velocity(xp, yp, zp, x1, y1, z1, x2, y2, z2, rcore)

            # Y-symmetry image (swap endpoints, matching AVL's VVOR)
            if iysym != 0
                u2, v2, w2 = horseshoe_velocity(xp, yp, zp,
                                                  x2, 2*ysym-y2, z2,
                                                  x1, 2*ysym-y1, z1, rcore)
                fysym = Float64(iysym)
                u += fysym * u2
                v += fysym * v2
                w += fysym * w2
            end

            # Z-symmetry image (swap endpoints, matching AVL's VVOR)
            if izsym != 0
                u3, v3, w3 = horseshoe_velocity(xp, yp, zp,
                                                  x2, y2, 2*zsym-z2,
                                                  x1, y1, 2*zsym-z1, rcore)
                fzsym = Float64(izsym)
                u += fzsym * u3
                v += fzsym * v3
                w += fzsym * w3
            end

            # combined YZ image (no swap — double reflection, matching AVL's VVOR)
            if iysym != 0 && izsym != 0
                u4, v4, w4 = horseshoe_velocity(xp, yp, zp,
                                                  x1, 2*ysym-y1, 2*zsym-z1,
                                                  x2, 2*ysym-y2, 2*zsym-z2, rcore)
                fyzs = Float64(iysym * izsym)
                u += fyzs * u4
                v += fyzs * v4
                w += fyzs * w4
            end

            # undo PG correction for x-velocity
            u /= beta_pg

            WC_GAM[1, i, j] = u
            WC_GAM[2, i, j] = v
            WC_GAM[3, i, j] = w

            # normalwash: dot product with normal vector
            AICN[i, j] = u*ei.enc[1] + v*ei.enc[2] + w*ei.enc[3]
        end
    end

    # velocity at vortex midpoints
    for j in 1:nv
        ej = vl.elements[j]
        x1 = ej.rv1[1] / beta_pg; y1 = ej.rv1[2]; z1 = ej.rv1[3]
        x2 = ej.rv2[1] / beta_pg; y2 = ej.rv2[2]; z2 = ej.rv2[3]

        for i in 1:nv
            ei = vl.elements[i]
            rcore = _compute_core_radius(ei, ej, config, vl)

            xp = ei.rv[1] / beta_pg
            yp = ei.rv[2]
            zp = ei.rv[3]

            if i == j
                # diagonal: only trailing legs, skip bound leg entirely
                u, v, w = _trailing_legs_velocity(xp, yp, zp,
                                                    x1, y1, z1, x2, y2, z2, rcore)
            else
                u, v, w = horseshoe_velocity(xp, yp, zp, x1, y1, z1, x2, y2, z2, rcore)
            end

            if iysym != 0
                u2, v2, w2 = horseshoe_velocity(xp, yp, zp,
                                                  x2, 2*ysym-y2, z2,
                                                  x1, 2*ysym-y1, z1, rcore)
                fysym = Float64(iysym)
                u += fysym*u2; v += fysym*v2; w += fysym*w2
            end
            if izsym != 0
                u3, v3, w3 = horseshoe_velocity(xp, yp, zp,
                                                  x2, y2, 2*zsym-z2,
                                                  x1, y1, 2*zsym-z1, rcore)
                fzsym = Float64(izsym)
                u += fzsym*u3; v += fzsym*v3; w += fzsym*w3
            end
            if iysym != 0 && izsym != 0
                u4, v4, w4 = horseshoe_velocity(xp, yp, zp,
                                                  x1, 2*ysym-y1, 2*zsym-z1,
                                                  x2, 2*ysym-y2, 2*zsym-z2, rcore)
                fyzs = Float64(iysym * izsym)
                u += fyzs*u4; v += fyzs*v4; w += fyzs*w4
            end

            u /= beta_pg

            WV_GAM[1, i, j] = u
            WV_GAM[2, i, j] = v
            WV_GAM[3, i, j] = w
        end
    end

    return AICN, WC_GAM, WV_GAM
end

"""Compute vortex core radius between two elements (matching AVL's VVOR)."""
function _compute_core_radius(ei::VortexElement, ej::VortexElement,
                              config::AVLConfig, vl::VortexLattice)
    # DSYZ: spanwise size of sending element j (matching AVL's VVOR)
    dsyz = sqrt((ej.rv2[2] - ej.rv1[2])^2 + (ej.rv2[3] - ej.rv1[3])^2)

    if ei.icomp == ej.icomp
        # same component: very small core (0.0001 * DSYZ, matching AVL)
        return 0.0001 * dsyz
    else
        # different component: use core parameters
        vrcc = config.vrcorec
        vrcw = config.vrcorew

        # check surface-level overrides
        if ej.isurf <= length(vl.surf_comp)
            sidx_orig = 0
            for (k, sdef) in enumerate(config.surfaces)
                if sdef.component == ej.icomp
                    sidx_orig = k
                    break
                end
            end
            if sidx_orig > 0
                sdef = config.surfaces[sidx_orig]
                if sdef.vrcorec >= 0
                    vrcc = sdef.vrcorec
                end
                if sdef.vrcorew >= 0
                    vrcw = sdef.vrcorew
                end
            end
        end

        return max(vrcc * ej.chord, vrcw * dsyz)
    end
end

"""Compute velocity from trailing legs only (no bound leg). For diagonal elements."""
function _trailing_legs_velocity(xp, yp, zp, x1, y1, z1, x2, y2, z2, rcore)
    inv4pi = 1.0 / (4.0 * π)
    u = 0.0; v = 0.0; w = 0.0
    rcore4 = rcore^4

    # trailing leg from point 1 (+∞ → rv1, direction -x: negate rv1→+∞)
    rsq1 = (yp-y1)^2 + (zp-z1)^2
    rsq1_reg = sqrt(rsq1^2 + rcore4)
    if rsq1_reg > 1e-30 && rsq1 > 1e-30
        r1 = sqrt((xp-x1)^2 + rsq1)
        factor1 = inv4pi * (1.0 + (xp-x1)/max(r1,1e-20)) * rsq1 / rsq1_reg
        v +=  (zp-z1) * factor1 / rsq1
        w += -(yp-y1) * factor1 / rsq1
    end

    # trailing leg from point 2 (rv2 → +∞, direction +x: standard formula)
    rsq2 = (yp-y2)^2 + (zp-z2)^2
    rsq2_reg = sqrt(rsq2^2 + rcore4)
    if rsq2_reg > 1e-30 && rsq2 > 1e-30
        r2 = sqrt((xp-x2)^2 + rsq2)
        factor2 = inv4pi * (1.0 + (xp-x2)/max(r2,1e-20)) * rsq2 / rsq2_reg
        v += -(zp-z2) * factor2 / rsq2
        w +=  (yp-y2) * factor2 / rsq2
    end

    return (u, v, w)
end

"""Compute only the bound-leg velocity contribution (Leishman core model)."""
function _bound_leg_velocity(xp, yp, zp, x1, y1, z1, x2, y2, z2, rcore)
    inv4pi = 1.0 / (4.0 * π)

    ax = xp - x1; ay = yp - y1; az = zp - z1
    bx = xp - x2; by = yp - y2; bz = zp - z2

    cx = ay*bz - az*by
    cy = az*bx - ax*bz
    cz = ax*by - ay*bx

    asq = ax^2 + ay^2 + az^2
    bsq = bx^2 + by^2 + bz^2
    amag = sqrt(asq)
    bmag = sqrt(bsq)

    cmagsq = cx^2 + cy^2 + cz^2
    rcore4 = rcore^4

    u = 0.0; v = 0.0; w = 0.0
    if amag > 1e-20 && bmag > 1e-20 && cmagsq > 1e-30
        adb = ax*bx + ay*by + az*bz
        alsq = asq + bsq - 2.0*adb

        amag_reg = sqrt(sqrt(asq^2 + rcore4))
        bmag_reg = sqrt(sqrt(bsq^2 + rcore4))
        denom = sqrt(cmagsq^2 + alsq^2 * rcore4)

        if denom > 1e-30
            T = ((bsq - adb)/bmag_reg + (asq - adb)/amag_reg) / denom
            u = cx * T * inv4pi
            v = cy * T * inv4pi
            w = cz * T * inv4pi
        end
    end
    return (u, v, w)
end
