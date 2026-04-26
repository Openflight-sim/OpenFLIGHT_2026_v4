# ──────────────────────────────────────────────────────────────
# spacing.jl — Panel spacing distributions (matching AVL's sgutil.f)
# ──────────────────────────────────────────────────────────────

"""
    spacer(n, pspace) → x[1:n+1]

Generate normalized spacing distribution from 0 to 1 with n intervals.
pspace controls the clustering:
  0.0 or 3.0: equal spacing
  1.0: cosine (bunched at both ends)
  2.0: sine (bunched at start)
 -2.0: sine (bunched at end)
Intermediate values blend between modes.
"""
function spacer(n::Int, pspace::Float64)
    n <= 0 && return [0.0, 1.0]
    x = zeros(n + 1)

    for i in 1:n+1
        frac = (i - 1) / n

        if pspace ≈ 0.0
            x[i] = frac
        else
            # cosine spacing
            xcos = 0.5*(1.0 - cos(π * frac))
            # sine spacing (bunched at start)
            xsin = 1.0 - cos(0.5π * frac)
            # negative sine (bunched at end)
            xnsin = sin(0.5π * frac)

            absp = abs(pspace)
            if absp <= 1.0
                # blend equal → cosine
                x[i] = frac * (1.0 - absp) + xcos * absp
            elseif absp <= 2.0
                # blend cosine → sine
                w = absp - 1.0
                if pspace > 0
                    x[i] = xcos * (1.0 - w) + xsin * w
                else
                    x[i] = xcos * (1.0 - w) + xnsin * w
                end
            else
                # blend sine → equal
                w = absp - 2.0
                if pspace > 0
                    x[i] = xsin * (1.0 - w) + frac * w
                else
                    x[i] = xnsin * (1.0 - w) + frac * w
                end
            end
        end
    end

    x[1] = 0.0
    x[end] = 1.0
    return x
end

"""
    cspacer(nvc, cspace, claf) → (xpt, xvr, xsr, xcp)

Chordwise panel spacing for vortex lattice (matching AVL's CSPACER in sgutil.f).
Uses a 4-point-per-panel cosine distribution where XPT, XVR, XSR, XCP each
sit at specific cosine-distributed positions within each panel.
Returns arrays of length nvc+1 (xpt) or nvc (xvr, xsr, xcp).
"""
function cspacer(nvc::Int, cspace::Float64, claf::Float64)
    xpt = zeros(nvc + 1)
    xvr = zeros(nvc)
    xsr = zeros(nvc)
    xcp = zeros(nvc)

    # blending weights (matching AVL's CSPACER)
    acsp = abs(cspace)
    ncsp = floor(Int, acsp)
    if ncsp == 0
        f0 = 1.0 - acsp; f1 = acsp; f2 = 0.0
    elseif ncsp == 1
        f0 = 0.0; f1 = 2.0 - acsp; f2 = acsp - 1.0
    else
        f0 = acsp - 2.0; f1 = 0.0; f2 = 3.0 - acsp
    end

    # spacing increments for the 4-point-per-panel scheme
    dth1 =     π / (4*nvc + 2)   # cosine
    dth2 = 0.5π / (4*nvc + 1)   # sine
    dxc0 = 1.0  / (4*nvc)       # uniform

    for ivc in 1:nvc
        # uniform positions
        xc0 = (4*ivc - 4) * dxc0
        xpt0 = xc0
        xvr0 = xc0 +     dxc0
        xsr0 = xc0 + 2.0*dxc0
        xcp0 = xc0 +     dxc0 + 2.0*dxc0*claf

        # cosine positions
        th1 = (4*ivc - 3) * dth1
        xpt1 = 0.5*(1.0 - cos(th1))
        xvr1 = 0.5*(1.0 - cos(th1 +     dth1))
        xsr1 = 0.5*(1.0 - cos(th1 + 2.0*dth1))
        xcp1 = 0.5*(1.0 - cos(th1 +     dth1 + 2.0*dth1*claf))

        # sine positions
        if cspace > 0.0
            th2 = (4*ivc - 3) * dth2
            xpt2 = 1.0 - cos(th2)
            xvr2 = 1.0 - cos(th2 +     dth2)
            xsr2 = 1.0 - cos(th2 + 2.0*dth2)
            xcp2 = 1.0 - cos(th2 +     dth2 + 2.0*dth2*claf)
        else
            th2 = (4*ivc - 4) * dth2
            xpt2 = sin(th2)
            xvr2 = sin(th2 +     dth2)
            xsr2 = sin(th2 + 2.0*dth2)
            xcp2 = sin(th2 +     dth2 + 2.0*dth2*claf)
        end

        # blend
        xpt[ivc] = f0*xpt0 + f1*xpt1 + f2*xpt2
        xvr[ivc] = f0*xvr0 + f1*xvr1 + f2*xvr2
        xsr[ivc] = f0*xsr0 + f1*xsr1 + f2*xsr2
        xcp[ivc] = f0*xcp0 + f1*xcp1 + f2*xcp2
    end

    # enforce boundary conditions
    xpt[1] = 0.0
    xpt[nvc+1] = 1.0

    return (xpt, xvr, xsr, xcp)
end
