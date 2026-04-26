# ──────────────────────────────────────────────────────────────
# splines.jl — Cubic spline interpolation (matching AVL's spline.f)
# ──────────────────────────────────────────────────────────────

"""
    trisol!(a, b, c, d)

Thomas algorithm for tridiagonal system.
a = sub-diagonal, b = diagonal, c = super-diagonal, d = rhs (overwritten with solution).
"""
function trisol!(a::AbstractVector, b::AbstractVector, c::AbstractVector, d::AbstractVector)
    n = length(d)
    n <= 1 && return d
    # forward elimination
    for k in 2:n
        m = a[k] / b[k-1]
        b[k] -= m * c[k-1]
        d[k] -= m * d[k-1]
    end
    # back substitution
    d[n] /= b[n]
    for k in (n-1):-1:1
        d[k] = (d[k] - c[k]*d[k+1]) / b[k]
    end
    return d
end

"""
    spline(x, s) → xs

Compute cubic spline coefficients (first derivatives dx/ds) for data x(s)
with natural end conditions (zero second derivative at endpoints).
"""
function spline(x::AbstractVector, s::AbstractVector)
    n = length(x)
    xs = zeros(n)
    n <= 1 && return xs
    if n == 2
        xs[1] = (x[2]-x[1]) / (s[2]-s[1])
        xs[2] = xs[1]
        return xs
    end
    # build tridiagonal system
    a = zeros(n)  # sub-diagonal
    b = zeros(n)  # diagonal
    c = zeros(n)  # super-diagonal
    d = zeros(n)  # rhs

    # natural end condition: zero 2nd derivative
    b[1] = 1.0
    c[1] = 0.5
    dsm = s[2] - s[1]
    d[1] = 1.5 * (x[2] - x[1]) / dsm

    for i in 2:n-1
        dsm = s[i] - s[i-1]
        dsp = s[i+1] - s[i]
        a[i] = dsp
        b[i] = 2.0*(dsm + dsp)
        c[i] = dsm
        d[i] = 3.0*(dsp*(x[i]-x[i-1])/dsm + dsm*(x[i+1]-x[i])/dsp)
    end

    dsm = s[n] - s[n-1]
    a[n] = 0.5
    b[n] = 1.0
    d[n] = 1.5 * (x[n] - x[n-1]) / dsm

    trisol!(a, b, c, d)
    return d  # these are xs (first derivatives)
end

"""
    splind(x, s, xs1, xs2) → xs

Spline with specified or natural end conditions.
xs1, xs2: endpoint slopes. Use 999.0 for natural, -999.0 for zero 3rd derivative.
"""
function splind(x::AbstractVector, s::AbstractVector, xs1::Float64, xs2::Float64)
    n = length(x)
    xs = zeros(n)
    n <= 1 && return xs
    if n == 2
        xs[1] = (x[2]-x[1]) / (s[2]-s[1])
        xs[2] = xs[1]
        return xs
    end

    a = zeros(n)
    b = zeros(n)
    c = zeros(n)
    d = zeros(n)

    dsp = s[2] - s[1]
    if xs1 ≈ 999.0
        # natural
        b[1] = 1.0; c[1] = 0.5
        d[1] = 1.5*(x[2]-x[1])/dsp
    elseif xs1 ≈ -999.0
        # zero 3rd derivative
        b[1] = 1.0; c[1] = 1.0
        d[1] = 2.0*(x[2]-x[1])/dsp
    else
        b[1] = 1.0; c[1] = 0.0
        d[1] = xs1
    end

    for i in 2:n-1
        dsm = s[i] - s[i-1]
        dsp = s[i+1] - s[i]
        a[i] = dsp
        b[i] = 2.0*(dsm + dsp)
        c[i] = dsm
        d[i] = 3.0*(dsp*(x[i]-x[i-1])/dsm + dsm*(x[i+1]-x[i])/dsp)
    end

    dsm = s[n] - s[n-1]
    if xs2 ≈ 999.0
        a[n] = 0.5; b[n] = 1.0
        d[n] = 1.5*(x[n]-x[n-1])/dsm
    elseif xs2 ≈ -999.0
        a[n] = 1.0; b[n] = 1.0
        d[n] = 2.0*(x[n]-x[n-1])/dsm
    else
        a[n] = 0.0; b[n] = 1.0
        d[n] = xs2
    end

    trisol!(a, b, c, d)
    return d
end

"""
    splina(x, s) → xs

Non-oscillatory spline via simple averaging of adjacent slopes.
"""
function splina(x::AbstractVector, s::AbstractVector)
    n = length(x)
    xs = zeros(n)
    n <= 1 && return xs
    if n == 2
        xs[1] = (x[2]-x[1])/(s[2]-s[1])
        xs[2] = xs[1]
        return xs
    end
    # interior: average of left and right slopes
    for i in 2:n-1
        ds_left  = s[i] - s[i-1]
        ds_right = s[i+1] - s[i]
        if abs(ds_left) < 1e-30 || abs(ds_right) < 1e-30
            xs[i] = 0.0
        else
            sl = (x[i]-x[i-1])/ds_left
            sr = (x[i+1]-x[i])/ds_right
            xs[i] = 0.5*(sl + sr)
        end
    end
    xs[1]  = 2.0*(x[2]-x[1])/(s[2]-s[1]) - xs[2]
    xs[n]  = 2.0*(x[n]-x[n-1])/(s[n]-s[n-1]) - xs[n-1]
    return xs
end

"""
    segspl(x, s) → xs

Piecewise spline allowing derivative discontinuities at segment joints
(indicated by identical successive s values).
"""
function segspl(x::AbstractVector, s::AbstractVector)
    n = length(x)
    xs = zeros(n)
    n <= 1 && return xs

    # find segment boundaries
    iseg_start = 1
    for i in 2:n
        is_boundary = (i == n) || (s[i] ≈ s[i+1])
        if is_boundary || (i == n)
            iseg_end = i
            nseg = iseg_end - iseg_start + 1
            if nseg >= 2
                xseg = @view x[iseg_start:iseg_end]
                sseg = @view s[iseg_start:iseg_end]
                xsseg = splind(collect(xseg), collect(sseg), -999.0, -999.0)
                for j in 1:nseg
                    xs[iseg_start + j - 1] = xsseg[j]
                end
            end
            iseg_start = i + 1
        end
    end
    # if no boundaries found, just do a regular spline
    if all(i -> xs[i] == 0.0, 1:n) && n >= 2
        xs .= splind(collect(x), collect(s), -999.0, -999.0)
    end
    return xs
end

"""
    seval(ss, x, xs, s) → value

Evaluate cubic spline at parameter ss.
"""
function seval(ss::Float64, x::AbstractVector, xs::AbstractVector, s::AbstractVector)
    n = length(x)
    n == 1 && return x[1]

    # binary search
    ilo = 1; ihi = n
    while ihi - ilo > 1
        imid = (ilo + ihi) ÷ 2
        if s[imid] > ss
            ihi = imid
        else
            ilo = imid
        end
    end
    i = ilo
    j = ihi

    ds = s[j] - s[i]
    abs(ds) < 1e-30 && return 0.5*(x[i] + x[j])

    t = (ss - s[i]) / ds
    cx1 = ds*xs[i] - (x[j] - x[i])
    cx2 = ds*xs[j] - (x[j] - x[i])
    return (1.0-t)*x[i] + t*x[j] + t*(1.0-t)*((1.0-t)*cx1 - t*cx2)   # note: this matches AVL's sign convention
end

"""
    deval(ss, x, xs, s) → derivative dx/ds

Evaluate first derivative of cubic spline at parameter ss.
Matches Fortran AVL's DEVAL (spline.f).
"""
function deval(ss::Float64, x::AbstractVector, xs::AbstractVector, s::AbstractVector)
    n = length(x)
    n == 1 && return 0.0

    ilo = 1; ihi = n
    while ihi - ilo > 1
        imid = (ilo + ihi) ÷ 2
        if s[imid] > ss
            ihi = imid
        else
            ilo = imid
        end
    end
    i = ilo; j = ihi

    ds = s[j] - s[i]
    abs(ds) < 1e-30 && return 0.0

    t = (ss - s[i]) / ds
    cx1 = ds*xs[i] - (x[j] - x[i])
    cx2 = ds*xs[j] - (x[j] - x[i])
    dxds = (x[j]-x[i]) + (1.0-4.0*t+3.0*t^2)*cx1 + t*(3.0*t-2.0)*cx2
    return dxds / ds
end

# Alias for backward compatibility
const deval_avl = deval

"""
    d2val(ss, x, xs, s) → second derivative d²x/ds²

Evaluate second derivative of cubic spline at parameter ss.
Matches Fortran AVL's D2VAL (spline.f).
"""
function d2val(ss::Float64, x::AbstractVector, xs::AbstractVector, s::AbstractVector)
    n = length(x)
    n == 1 && return 0.0

    ilo = 1; ihi = n
    while ihi - ilo > 1
        imid = (ilo + ihi) ÷ 2
        if s[imid] > ss
            ihi = imid
        else
            ilo = imid
        end
    end
    i = ilo; j = ihi

    ds = s[j] - s[i]
    abs(ds) < 1e-30 && return 0.0

    t = (ss - s[i]) / ds
    cx1 = ds*xs[i] - (x[j] - x[i])
    cx2 = ds*xs[j] - (x[j] - x[i])
    return ((6.0*t - 4.0)*cx1 + (6.0*t - 2.0)*cx2) / ds^2
end

"""
    scalc(x, y) → s

Arc-length parameterization of 2D curve.
"""
function scalc(x::AbstractVector, y::AbstractVector)
    n = length(x)
    s = zeros(n)
    for i in 2:n
        dx = x[i] - x[i-1]
        dy = y[i] - y[i-1]
        s[i] = s[i-1] + sqrt(dx^2 + dy^2)
    end
    return s
end

"""
    sinvrt(si_init, xi, x, xs, s) → si

Inverse spline: find si such that x(si) = xi via Newton iteration.
"""
function sinvrt(si_init::Float64, xi::Float64, x::AbstractVector, xs::AbstractVector, s::AbstractVector)
    si = si_init
    for _ in 1:20
        res = seval(si, x, xs, s) - xi
        res_s = deval_avl(si, x, xs, s)
        if abs(res_s) < 1e-30
            break
        end
        ds = -res / res_s
        ds = clamp(ds, -0.5*(s[end]-s[1]), 0.5*(s[end]-s[1]))
        si += ds
        si = clamp(si, s[1], s[end])
        abs(ds) < 1e-12*(s[end]-s[1]+1e-30) && break
    end
    return si
end

"""
    lefind(x, xp, y, yp, s) → sle

Find leading edge (leftmost point) of an airfoil via Newton iteration on dx/ds = 0.
Matches Fortran AVL's LEFIND (spline.f): uses analytical d2x/ds2 via d2val.
"""
function lefind(x::AbstractVector, xp::AbstractVector,
                y::AbstractVector, yp::AbstractVector,
                s::AbstractVector)
    n = length(x)
    # initial guess: find first point where x starts increasing (Fortran approach)
    sle = s[n]
    for i in 2:n
        if x[i] > x[i-1]
            sle = s[i-1]
            break
        end
    end

    sref = s[end] - s[1]
    for _ in 1:20
        res  = deval(sle, x, xp, s)      # dx/ds
        resp = d2val(sle, x, xp, s)      # d2x/ds2
        if abs(resp) < 1e-30
            break
        end
        dsle = -res / resp
        sle += dsle
        if abs(dsle) / sref < 1.0e-5
            break
        end
    end
    return sle
end
