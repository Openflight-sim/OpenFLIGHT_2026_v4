# ──────────────────────────────────────────────────────────────
# trefftz.jl — Trefftz plane induced drag calculation
#               (matching AVL's atpforc.f)
# ──────────────────────────────────────────────────────────────

"""
    trefftz_drag!(sol, vl, config)

Compute far-field forces via the Trefftz plane kinetic energy integral.
Updates sol.clff, sol.cdff, sol.cyff, sol.spanef and strip downwash.

Uses the segment-based velocity model matching AVL's atpforc.f:
  VY = Γ/(2π) * (dz1/rsq1 - dz2/rsq2)
  VZ = Γ/(2π) * (-dy1/rsq1 + dy2/rsq2)
where rsq = √((dy²+dz²)² + rcore⁴)  (Scully regularization)
"""
function trefftz_drag!(sol::AVLSolution, vl::VortexLattice, config::AVLConfig)
    nstrip = vl.nstrip
    nv = vl.nvor
    sref = config.sref
    bref = config.bref

    iysym = config.iysym
    izsym = config.izsym
    ysym = config.ysym
    zsym = config.zsym

    # 1. Accumulate strip circulations (sum of all chordwise GAM in each strip)
    gams = zeros(nstrip)
    for js in 1:nstrip
        strip = vl.strips[js]
        for k in 1:strip.nelem
            ie = strip.ifirst + k - 1
            ie > nv && continue
            gams[js] += sol.gam[ie]
        end
    end

    # 2. Get trailing-vortex endpoints and control point in the Trefftz plane (Y-Z projection)
    #    RT1/RT2 are the bound vortex endpoints of the last chordwise element
    #    RTC is the control point of the last element (matching Fortran atpforc.f)
    yt1 = zeros(nstrip); zt1 = zeros(nstrip)
    yt2 = zeros(nstrip); zt2 = zeros(nstrip)
    ytc = zeros(nstrip); ztc = zeros(nstrip)

    for js in 1:nstrip
        strip = vl.strips[js]
        strip.nelem < 1 && continue
        ie_last = min(strip.ifirst + strip.nelem - 1, nv)
        elem = vl.elements[ie_last]
        yt1[js] = elem.rv1[2]; zt1[js] = elem.rv1[3]
        yt2[js] = elem.rv2[2]; zt2[js] = elem.rv2[3]
        ytc[js] = elem.rc[2];  ztc[js] = elem.rc[3]
    end

    # 3. Compute crossflow velocities at strip control points using segment model
    #    Fortran uses RTC (control point of trailing element) as the evaluation point
    vy = zeros(nstrip)
    vz = zeros(nstrip)
    hpi = 1.0 / (2.0 * π)

    for jc in 1:nstrip  # receiving strip
        yc = ytc[jc]
        zc = ztc[jc]

        for jv in 1:nstrip  # sending strip
            abs(gams[jv]) < 1e-30 && continue

            # determine core radius (matching AVL's atpforc.f)
            ic_recv = vl.strips[jc].nelem > 0 ? vl.elements[vl.strips[jc].ifirst].icomp : 0
            ic_send = vl.strips[jv].nelem > 0 ? vl.elements[vl.strips[jv].ifirst].icomp : 0
            # DSYZ: spanwise size of sending strip's trailing vortex
            dsyz = sqrt((yt2[jv]-yt1[jv])^2 + (zt2[jv]-zt1[jv])^2)
            if ic_recv == ic_send
                rcore = 0.0  # same component: no core (matching AVL)
            else
                rcore = max(config.vrcorec * vl.strips[jv].chord,
                            config.vrcorew * dsyz)
            end

            # ── Real vortex segment ──
            # Segment velocity formula (matching atpforc.f):
            #   VY += HPI * GAMS * ( DZ1/RSQ1 - DZ2/RSQ2)
            #   VZ += HPI * GAMS * (-DY1/RSQ1 + DY2/RSQ2)
            dy1 = yc - yt1[jv]
            dz1 = zc - zt1[jv]
            dy2 = yc - yt2[jv]
            dz2 = zc - zt2[jv]

            rsq1 = _trefftz_rsq(dy1, dz1, rcore)
            rsq2 = _trefftz_rsq(dy2, dz2, rcore)

            g = gams[jv]
            if rsq1 > 1e-30
                vy[jc] += hpi * g *  dz1 / rsq1
                vz[jc] += hpi * g * (-dy1) / rsq1
            end
            if rsq2 > 1e-30
                vy[jc] -= hpi * g *  dz2 / rsq2
                vz[jc] -= hpi * g * (-dy2) / rsq2
            end

            # ── Z-symmetry image (subtract with IZSYM) ──
            if izsym != 0
                fz = Float64(izsym)
                dz1i = zc - (2*zsym - zt1[jv])
                dz2i = zc - (2*zsym - zt2[jv])
                # image uses no core (rcore=0 → simple r²)
                rsq1i = dy1^2 + dz1i^2
                rsq2i = dy2^2 + dz2i^2
                if rsq1i > 1e-30
                    vy[jc] -= hpi * g * fz *  dz1i / rsq1i
                    vz[jc] -= hpi * g * fz * (-dy1) / rsq1i
                end
                if rsq2i > 1e-30
                    vy[jc] += hpi * g * fz *  dz2i / rsq2i
                    vz[jc] += hpi * g * fz * (-dy2) / rsq2i
                end
            end

            # ── Y-symmetry image (subtract with IYSYM) ──
            if iysym != 0
                fy = Float64(iysym)
                dy1i = yc - (2*ysym - yt1[jv])
                dy2i = yc - (2*ysym - yt2[jv])
                rsq1i = dy1i^2 + dz1^2
                rsq2i = dy2i^2 + dz2^2
                if rsq1i > 1e-30
                    vy[jc] -= hpi * g * fy *  dz1 / rsq1i
                    vz[jc] -= hpi * g * fy * (-dy1i) / rsq1i
                end
                if rsq2i > 1e-30
                    vy[jc] += hpi * g * fy *  dz2 / rsq2i
                    vz[jc] += hpi * g * fy * (-dy2i) / rsq2i
                end
            end

            # ── Combined YZ image (add with IYSYM*IZSYM) ──
            if iysym != 0 && izsym != 0
                fyz = Float64(iysym * izsym)
                dy1i = yc - (2*ysym - yt1[jv])
                dy2i = yc - (2*ysym - yt2[jv])
                dz1i = zc - (2*zsym - zt1[jv])
                dz2i = zc - (2*zsym - zt2[jv])
                rsq1i = dy1i^2 + dz1i^2
                rsq2i = dy2i^2 + dz2i^2
                if rsq1i > 1e-30
                    vy[jc] += hpi * g * fyz *  dz1i / rsq1i
                    vz[jc] += hpi * g * fyz * (-dy1i) / rsq1i
                end
                if rsq2i > 1e-30
                    vy[jc] -= hpi * g * fyz *  dz2i / rsq2i
                    vz[jc] -= hpi * g * fyz * (-dy2i) / rsq2i
                end
            end
        end
    end

    # 4. Compute far-field forces (matching atpforc.f lines 290-300)
    clff = 0.0
    cdff = 0.0
    cyff = 0.0
    dwwake = zeros(nstrip)

    for jc in 1:nstrip
        strip = vl.strips[jc]
        !strip.contributes_load && continue
        abs(gams[jc]) < 1e-30 && continue

        dyt = yt2[jc] - yt1[jc]
        dzt = zt2[jc] - zt1[jc]

        # far-field lift
        clff += 2.0 * gams[jc] * dyt / sref

        # far-field side force (NOTE: negative sign, matching AVL)
        cyff -= 2.0 * gams[jc] * dzt / sref

        # strip normal in Trefftz plane
        dst = sqrt(dyt^2 + dzt^2)
        if dst > 1e-20
            ny = -dzt / dst
            nz =  dyt / dst
        else
            ny = 0.0; nz = 1.0
        end

        # wake downwash at this strip
        dwwake[jc] = -(ny*vy[jc] + nz*vz[jc])

        # induced drag: CDff = Σ GAMS * (DZT*VY - DYT*VZ) / SREF
        cdff += gams[jc] * (dzt*vy[jc] - dyt*vz[jc]) / sref
    end

    # 5. Apply symmetry doubling for forces
    if iysym != 0
        if iysym == 1
            clff *= 2.0
            cdff *= 2.0
            cyff = 0.0  # antisymmetric → zero
        elseif iysym == -1
            clff = 0.0   # antisymmetric → zero
            cdff *= 2.0
            cyff *= 2.0
        end
    end

    # NOTE: No force doubling for IZSYM. The z-image velocity contributions
    # are already included in the velocity integral above (lines 99-115).
    # Fortran AVL (atpforc.f) also does NOT double for IZSYM.

    # span efficiency
    ar = bref^2 / sref
    if abs(cdff) > 1e-20
        spanef = (clff^2 + cyff^2) / (π * ar * cdff)
    else
        spanef = 0.0
    end

    sol.clff = clff
    sol.cdff = cdff
    sol.cyff = cyff
    sol.spanef = spanef
    sol.strip_dwwake = dwwake
end

"""Compute regularized distance for Trefftz plane (Scully core model)."""
@inline function _trefftz_rsq(dy::Float64, dz::Float64, rcore::Float64)
    rsq = dy^2 + dz^2
    if rcore > 0.0
        return sqrt(rsq^2 + rcore^4)
    else
        return rsq
    end
end
