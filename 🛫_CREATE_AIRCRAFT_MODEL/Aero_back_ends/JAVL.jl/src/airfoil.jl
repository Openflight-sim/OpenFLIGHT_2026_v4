# ──────────────────────────────────────────────────────────────
# airfoil.jl — Airfoil camber/thickness extraction and NACA generators
# ──────────────────────────────────────────────────────────────

"""
    akima_interp(xdata, ydata, xx) → (yy, slope)

Akima interpolation: locally-fitted cubic avoiding oscillation.
"""
function akima_interp(xdata::AbstractVector, ydata::AbstractVector, xx::Float64)
    n = length(xdata)
    n < 2 && return (ydata[1], 0.0)

    # handle extrapolation
    ascending = xdata[end] > xdata[1]
    if ascending
        if xx <= xdata[1]
            slope = (ydata[2]-ydata[1])/(xdata[2]-xdata[1])
            return (ydata[1] + slope*(xx-xdata[1]), slope)
        end
        if xx >= xdata[end]
            slope = (ydata[end]-ydata[end-1])/(xdata[end]-xdata[end-1])
            return (ydata[end] + slope*(xx-xdata[end]), slope)
        end
    else
        if xx >= xdata[1]
            slope = (ydata[2]-ydata[1])/(xdata[2]-xdata[1])
            return (ydata[1] + slope*(xx-xdata[1]), slope)
        end
        if xx <= xdata[end]
            slope = (ydata[end]-ydata[end-1])/(xdata[end]-xdata[end-1])
            return (ydata[end] + slope*(xx-xdata[end]), slope)
        end
    end

    # find interval
    i = 1
    if ascending
        for k in 2:n
            if xdata[k] >= xx
                i = k - 1
                break
            end
        end
    else
        for k in 2:n
            if xdata[k] <= xx
                i = k - 1
                break
            end
        end
    end
    i = clamp(i, 1, n-1)

    # compute slopes at each interval
    m = zeros(n+3)  # padded slopes
    for k in 1:n-1
        dx = xdata[k+1] - xdata[k]
        abs(dx) < 1e-30 && continue
        m[k+2] = (ydata[k+1] - ydata[k]) / dx
    end
    # extrapolate slopes at boundaries
    m[2] = 2.0*m[3] - m[4]
    m[1] = 2.0*m[2] - m[3]
    m[n+2] = 2.0*m[n+1] - m[n]
    m[n+3] = 2.0*m[n+2] - m[n+1]

    # Akima weights
    function akima_slope(k)
        # k is 1-based index in original data, maps to m[k+1], m[k+2]
        dm1 = abs(m[k+3] - m[k+2])
        dm2 = abs(m[k+1] - m[k])
        if dm1 + dm2 < 1e-30
            return 0.5*(m[k+1] + m[k+2])
        end
        return (dm1*m[k+1] + dm2*m[k+2]) / (dm1 + dm2)
    end

    t1 = akima_slope(i)
    t2 = akima_slope(i+1)

    dx = xdata[i+1] - xdata[i]
    t = (xx - xdata[i]) / dx

    # Hermite cubic
    h00 = 2t^3 - 3t^2 + 1
    h10 = t^3 - 2t^2 + t
    h01 = -2t^3 + 3t^2
    h11 = t^3 - t^2

    yy = h00*ydata[i] + h10*dx*t1 + h01*ydata[i+1] + h11*dx*t2
    slope = (6t^2-6t)*ydata[i]/dx + (3t^2-4t+1)*t1 +
            (-6t^2+6t)*ydata[i+1]/dx + (3t^2-2t)*t2

    return (yy, slope)
end

"""
    read_airfoil(filename) → (x, y)

Read airfoil coordinate file. Returns x, y arrays (TE→LE→TE ordering).
"""
function read_airfoil(filename::AbstractString)
    xb = Float64[]
    yb = Float64[]

    lines = readlines(filename)
    started = false
    for line in lines
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, '#') && continue
        startswith(stripped, '!') && continue

        tokens = split(stripped)
        if length(tokens) >= 2
            xval = tryparse(Float64, tokens[1])
            yval = tryparse(Float64, tokens[2])
            if xval !== nothing && yval !== nothing
                push!(xb, xval)
                push!(yb, yval)
                started = true
            elseif started
                break  # end of coordinate data
            end
        elseif started
            break
        end
    end

    # ensure counter-clockwise ordering (positive area)
    if length(xb) >= 3
        area = 0.0
        n = length(xb)
        for i in 1:n
            j = mod(i, n) + 1
            area += xb[i]*yb[j] - xb[j]*yb[i]
        end
        if area > 0  # clockwise → reverse
            reverse!(xb)
            reverse!(yb)
        end
    end

    return xb, yb
end

"""
    getcam(x, y) → (xc, yc, tc, nc)

Extract camber line and thickness from airfoil coordinates.
Matches Fortran AVL's GETCAM (airutil.f): calls NORMIT to normalize
coordinates to unit chord (translate + scale only, NO rotation),
then extracts camber as 0.5*(YU+YL) and thickness as YU-YL.
Carries SU/SL initial guesses from one point to the next for robust convergence.
xc: x/c stations, yc: camber y/c, tc: thickness t/c, nc: number of stations.
"""
function getcam(xb::Vector{Float64}, yb::Vector{Float64}; nc::Int=50)
    n = length(xb)
    n < 3 && return (collect(range(0, 1, length=nc)), zeros(nc), zeros(nc), nc)

    # arc-length parameterize
    sb = scalc(xb, yb)
    xp = segspl(xb, sb)
    yp = segspl(yb, sb)

    # find leading edge
    sle = lefind(xb, xp, yb, yp, sb)

    # Apply NORMIT: normalize to unit chord (translate + scale, NO rotation)
    # Matches Fortran NORMIT (airutil.f lines 305-329)
    # Fortran modifies X,Y,S in-place but NOT XP,YP — the linear transformation
    # preserves spline derivatives (dX/dS is invariant under uniform scaling of X and S).
    xle = seval(sle, xb, xp, sb)
    xte = 0.5*(xb[1] + xb[end])
    abs(xte - xle) < 1e-20 && return (collect(range(0, 1, length=nc)), zeros(nc), zeros(nc), nc)
    dnorm = 1.0 / (xte - xle)

    # Make normalized copies (Fortran modifies in-place, we copy)
    # XP, YP are NOT recomputed — they remain valid with transformed coords
    xn  = (xb .- xle) .* dnorm
    yn  = yb .* dnorm
    sn  = sb .* dnorm
    sle = sle * dnorm

    # Normalized chord endpoints
    xle_n = seval(sle, xn, xp, sn)
    yle_n = seval(sle, yn, yp, sn)
    xte_n = 0.5*(xn[1] + xn[end])

    xc = zeros(nc)
    yc = zeros(nc)
    tc = zeros(nc)

    # LE point
    xc[1] = xle_n
    yc[1] = yle_n
    tc[1] = 0.0

    # initial guesses just off the LE — carried from point to point (Fortran approach)
    su = sle - 0.01
    sl = sle + 0.01

    for i in 2:nc
        frac = (i-1) / (nc-1)
        xout = xle_n + (xte_n - xle_n) * 0.5*(1.0 - cos(π * frac))

        # upper surface
        su = sinvrt(su, xout, xn, xp, sn)
        yu = seval(su, yn, yp, sn)

        # lower surface
        sl = sinvrt(sl, xout, xn, xp, sn)
        yl = seval(sl, yn, yp, sn)

        xc[i] = xout
        yc[i] = 0.5*(yu + yl)
        tc[i] = yu - yl
    end

    return (xc, yc, tc, nc)
end

"""
    getcam_body(x, y; nc=50) → (xc, yc, tc, nc)

Extract centerline and thickness from body profile coordinates.
Matches Fortran AVL's GETCAM with LNORM=.FALSE. (airutil.f):
- xc: ABSOLUTE x-positions (not normalized to 0–1)
- yc: centerline y = 0.5*(YU+YL) in original coordinates
- tc: full thickness YU-YL in original coordinates (= 2*radius)
- No chord-frame rotation, no normalization.
"""
function getcam_body(xb::Vector{Float64}, yb::Vector{Float64}; nc::Int=50)
    n = length(xb)
    n < 3 && return (collect(range(0, 1, length=nc)), zeros(nc), zeros(nc), nc)

    # arc-length parameterize
    sb = scalc(xb, yb)
    xp = segspl(xb, sb)
    yp = segspl(yb, sb)

    # find leading edge
    sle = lefind(xb, xp, yb, yp, sb)

    # chord endpoints
    xle = seval(sle, xb, xp, sb)
    yle = seval(sle, yb, yp, sb)
    xte = 0.5*(xb[1] + xb[end])
    yte = 0.5*(yb[1] + yb[end])
    chord = sqrt((xte-xle)^2 + (yte-yle)^2)
    chord < 1e-20 && return (collect(range(0, 1, length=nc)), zeros(nc), zeros(nc), nc)

    xc = zeros(nc)
    yc = zeros(nc)
    tc = zeros(nc)

    # LE point
    xc[1] = xle
    yc[1] = yle
    tc[1] = 0.0

    # initial guesses just off the LE — carried from point to point (Fortran approach)
    su = sle - 0.01 * (sb[end] - sb[1])
    sl = sle + 0.01 * (sb[end] - sb[1])

    for i in 2:nc
        frac = (i-1) / (nc-1)
        xout = xle + (xte-xle) * 0.5*(1.0 - cos(π * frac))

        # upper surface
        su = sinvrt(su, xout, xb, xp, sb)
        xu = seval(su, xb, xp, sb)
        yu = seval(su, yb, yp, sb)

        # lower surface
        sl = sinvrt(sl, xout, xb, xp, sb)
        xl = seval(sl, xb, xp, sb)
        yl = seval(sl, yb, yp, sb)

        # no rotation — store in original coordinates (matching Fortran LNORM=.FALSE.)
        xc[i] = xout
        yc[i] = 0.5*(yu + yl)
        tc[i] = abs(yu - yl)  # abs needed: read_airfoil ordering may swap upper/lower
    end

    return (xc, yc, tc, nc)
end

"""
    camber_to_slopes(xc_cosine, yc_camber; npts) → (xf_uniform, slopes)

Convert camber values at cosine-spaced points to pre-computed slopes at
uniformly-spaced points, matching Fortran AVL's two-step approach in ainput.f.

Fortran stores slopes (SASEC) at uniform XASEC, then re-interpolates them
with Akima when the slope is needed at arbitrary panel locations.
"""
function camber_to_slopes(xc::Vector{Float64}, yc::Vector{Float64}; npts::Int=length(xc))
    xf = collect(range(0.0, 1.0, length=npts))
    slopes = zeros(npts)
    for i in 1:npts
        _, slopes[i] = akima_interp(xc, yc, xf[i])
    end
    return xf, slopes
end

"""
    naca4_camber(naca_digits; nc=50) → (xc, camber_slope, thickness)

Generate camber slope and thickness arrays for a NACA 4-digit airfoil.
naca_digits: 4-digit integer (e.g., 2412)
"""
function naca4_camber(naca::Int; nc::Int=50)
    m = (naca ÷ 1000) / 100.0      # max camber fraction
    p = ((naca ÷ 100) % 10) / 10.0  # position of max camber
    t = (naca % 100) / 100.0        # max thickness fraction

    xc = zeros(nc)
    camber = zeros(nc)
    thick = zeros(nc)

    for i in 1:nc
        frac = (i-1) / (nc-1)
        x = 0.5*(1.0 - cos(π * frac))
        xc[i] = x

        # thickness distribution (NACA standard)
        thick[i] = t/0.2 * (0.2969*sqrt(x) - 0.1260*x - 0.3516*x^2 + 0.2843*x^3 - 0.1015*x^4)

        # camber value (not slope)
        if m > 0 && p > 0
            if x < p
                camber[i] = m/p^2 * (2.0*p*x - x^2)
            else
                camber[i] = m/(1.0-p)^2 * ((1.0-2.0*p) + 2.0*p*x - x^2)
            end
        end
    end

    return (xc, camber, thick)
end

"""
    naca5_camber(naca_digits; nc=50)

Generate camber for NACA 5-digit series. Falls back to zero camber for unsupported types.
"""
function naca5_camber(naca::Int; nc::Int=50)
    # simplified: treat as zero camber + thickness
    t = (naca % 100) / 100.0
    xc = zeros(nc)
    slope = zeros(nc)
    thick = zeros(nc)
    for i in 1:nc
        frac = (i-1)/(nc-1)
        x = 0.5*(1.0 - cos(π*frac))
        xc[i] = x
        thick[i] = t/0.2*(0.2969*sqrt(x) - 0.1260*x - 0.3516*x^2 + 0.2843*x^3 - 0.1015*x^4)
    end
    return (xc, slope, thick)
end
