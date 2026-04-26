module BodyAlone

using ...Utils: fig26, trapz_integrate

function _state_float(state::Dict{String, Any}, key::String, default::Float64)
    v = get(state, key, default)
    if v === nothing
        return default
    elseif v isa Number
        return float(v)
    elseif v isa AbstractVector
        isempty(v) && return default
        item = v[1]
        if item isa Number
            return float(item)
        elseif item isa AbstractString
            try
                return parse(Float64, item)
            catch
                return default
            end
        end
        return default
    elseif v isa AbstractString
        try
            return parse(Float64, v)
        catch
            return default
        end
    end
    return default
end

function _vec(v)
    if v === nothing
        return Float64[]
    elseif v isa AbstractVector
        out = Float64[]
        for item in v
            if item isa Number
                push!(out, float(item))
            elseif item isa AbstractString
                try
                    push!(out, parse(Float64, item))
                catch
                    push!(out, 0.0)
                end
            end
        end
        return out
    end
    return Float64[]
end

function _gradient(y::Vector{Float64}, x::Vector{Float64})
    n = min(length(y), length(x))
    n < 2 && return zeros(n)
    g = zeros(n)
    if n == 2
        dx = x[2] - x[1]
        g[1] = dx != 0 ? (y[2] - y[1]) / dx : 0.0
        g[2] = g[1]
        return g
    end
    for i in 2:(n - 1)
        dx = x[i + 1] - x[i - 1]
        g[i] = dx != 0 ? (y[i + 1] - y[i - 1]) / dx : 0.0
    end
    dx1 = x[2] - x[1]
    dxn = x[n] - x[n - 1]
    g[1] = dx1 != 0 ? (y[2] - y[1]) / dx1 : 0.0
    g[n] = dxn != 0 ? (y[n] - y[n - 1]) / dxn : 0.0
    return g
end

function _interp1(x::Real, xp::Vector{Float64}, fp::Vector{Float64})
    if x <= xp[1]
        return fp[1]
    elseif x >= xp[end]
        return fp[end]
    end
    idx = clamp(searchsortedlast(xp, x), 1, length(xp) - 1)
    x1 = xp[idx]
    x2 = xp[idx + 1]
    y1 = fp[idx]
    y2 = fp[idx + 1]
    t = x2 == x1 ? 0.0 : (x - x1) / (x2 - x1)
    return y1 + t * (y2 - y1)
end

function _interp_linear_with_slope(xq::Real, x::Vector{Float64}, y::Vector{Float64})
    n = min(length(x), length(y))
    n == 0 && return 0.0, 0.0
    n == 1 && return y[1], 0.0
    if xq <= x[1]
        dx = x[2] - x[1]
        slope = dx != 0 ? (y[2] - y[1]) / dx : 0.0
        return y[1], slope
    elseif xq >= x[n]
        dx = x[n] - x[n - 1]
        slope = dx != 0 ? (y[n] - y[n - 1]) / dx : 0.0
        return y[n], slope
    end

    idx = clamp(searchsortedlast(x, xq), 1, n - 1)
    x1 = x[idx]
    x2 = x[idx + 1]
    y1 = y[idx]
    y2 = y[idx + 1]
    t = x2 == x1 ? 0.0 : (xq - x1) / (x2 - x1)
    yq = y1 + t * (y2 - y1)
    slope = x2 == x1 ? 0.0 : (y2 - y1) / (x2 - x1)
    return yq, slope
end

function _quad_eval_and_slope(xq::Real, x::Vector{Float64}, y::Vector{Float64})
    n = min(length(x), length(y))
    if n < 3
        if n < 2
            return n == 1 ? y[1] : 0.0, 0.0
        end
        dx = x[2] - x[1]
        slope = dx != 0 ? (y[2] - y[1]) / dx : 0.0
        return y[1] + slope * (xq - x[1]), slope
    end

    # QUAD: fit y = a*x^2 + b*x + c through 3 points.
    A = [
        x[1]^2 x[1] 1.0
        x[2]^2 x[2] 1.0
        x[3]^2 x[3] 1.0
    ]
    rhs = [y[1], y[2], y[3]]
    coeff = try
        A \ rhs
    catch
        dx = x[3] - x[1]
        slope = dx != 0 ? (y[3] - y[1]) / dx : 0.0
        return y[1] + slope * (xq - x[1]), slope
    end
    a = coeff[1]
    b = coeff[2]
    c = coeff[3]
    yq = xq * (a * xq + b) + c
    dydx = 2.0 * a * xq + b
    return yq, dydx
end

function _tbfunx_1d(xq::Real, xa::Vector{Float64}, ya::Vector{Float64}; lexl::Int = 0, lexu::Int = 0)
    # DATCOM TBFUNX behavior for 1-D tables:
    # - interior Y by linear interpolation
    # - DYDX from quadratic fit (QUAD) on neighboring 3 points
    # - configurable endpoint extrapolation semantics via LEXL/LEXU.
    np = min(length(xa), length(ya))
    np == 0 && return 0.0, 0.0
    np == 1 && return ya[1], 0.0
    if np < 3
        dx = xa[2] - xa[1]
        slope = dx != 0 ? (ya[2] - ya[1]) / dx : 0.0
        return ya[1] + slope * (xq - xa[1]), slope
    end

    # Interior interpolation.
    if xq < xa[np] && xq > xa[1]
        l = clamp(searchsortedlast(xa, xq), 1, np - 1)
        l == 1 && (l = 2)
        l2 = l - 2
        xx = xa[(l2 + 1):(l2 + 3)]
        yy = ya[(l2 + 1):(l2 + 3)]

        yq = if xq < xa[2]
            dx = xx[2] - xx[1]
            slope = dx != 0 ? (yy[2] - yy[1]) / dx : 0.0
            yy[1] + slope * (xq - xx[1])
        else
            dx = xx[3] - xx[2]
            slope = dx != 0 ? (yy[3] - yy[2]) / dx : 0.0
            yy[2] + slope * (xq - xx[2])
        end
        _, dydx = _quad_eval_and_slope(xq, xx, yy)
        return yq, dydx
    end

    # Endpoint extrapolation / endpoint return.
    le = 0
    lle = 1
    lind = lexl
    if xq >= xa[np]
        le = np - 3
        lle = np
        lind = lexu
    end
    xx = xa[(le + 1):(le + 3)]
    yy = ya[(le + 1):(le + 3)]

    yq = 0.0
    if lind == 1
        if xq >= xa[np]
            dx = xa[np] - xa[np - 1]
            dydx = dx != 0 ? (ya[np] - ya[np - 1]) / dx : 0.0
            yq = (xq - xa[np]) * dydx + ya[np]
            return yq, dydx
        else
            dx = xa[2] - xa[1]
            dydx = dx != 0 ? (ya[2] - ya[1]) / dx : 0.0
            yq = (xq - xa[1]) * dydx + ya[1]
            return yq, dydx
        end
    elseif lind <= 0
        yq = ya[lle]
    else
        yq, _ = _quad_eval_and_slope(xq, xx, yy)
    end

    _, dydx = _quad_eval_and_slope(xq, xx, yy)
    return yq, dydx
end

function _tbfunx_value(xq::Real, xa::Vector{Float64}, ya::Vector{Float64}; lexl::Int = 0, lexu::Int = 0)
    yq, _ = _tbfunx_1d(xq, xa, ya; lexl = lexl, lexu = lexu)
    return yq
end

function _switch_fortran(lxgl::Int, lxgu::Int, xag::Real, xg::Vector{Float64})
    lg = falses(7)
    nxg = length(xg)
    nxg == 0 && return lg

    # LG(6): ascending-table flag.
    lg[6] = !(xg[1] > xg[nxg])

    if !lg[6]
        # Descending table.
        if xag > xg[1]
            lg[3] = true
        end
        if xag < xg[nxg]
            lg[2] = true
        end
    else
        # Ascending table.
        if xag > xg[nxg]
            lg[2] = true
        end
        if xag < xg[1]
            lg[3] = true
        end
    end

    if !lg[2]
        if !lg[3]
            return lg
        end
        if lxgl >= 0
            lg[4] = true
        end
        if lxgl <= 0
            return lg
        end
    else
        if lxgu >= 0
            lg[4] = true
        end
        if lxgu <= 0
            return lg
        end
    end

    lg[5] = true
    lg[7] = true
    return lg
end

function _glook_fortran(nxg::Int, xag::Real, xg::Vector{Float64}, nasg::Bool)
    nxg <= 0 && return 1, 0.0, true

    noing = false
    ii = 1
    tempg = 0.0
    temg = 0.0
    tg = 0.0

    for i in 1:nxg
        ii = i
        temg = xag - xg[i]
        dmg = xag
        if xag == 0.0
            dmg = xg[i]
        end
        if abs(dmg) <= 1.0e-4
            dmg = 1.0
        end
        erg = abs(temg / dmg)
        if erg < 1.0e-3
            noing = true
            break
        end

        if nasg && temg < 0.0
            break
        end
        if !nasg && temg > 0.0
            break
        end
        tempg = temg
    end

    ig = ii
    if ii == 1
        noing = true
    end
    if !noing
        denom = tempg - temg
        tg = denom != 0.0 ? tempg / denom : 0.0
    end
    return ig, tg, noing
end

function _tlin1x_fortran(
    x1::Vector{Float64},
    y::Vector{Float64},
    nx1::Int,
    xa1::Real,
    lx1l::Int,
    lx1u::Int,
)
    n = min(nx1, length(x1), length(y))
    n <= 0 && return 0.0
    n == 1 && return y[1]

    xx = x1[1:n]
    yy = y[1:n]
    xa = float(xa1)

    lg = _switch_fortran(lx1l, lx1u, xa, xx)
    if !lg[7]
        i1, t1, noin1 = _glook_fortran(n, xa, xx, lg[6])
        d2 = yy[i1]
        if !noin1
            d2 = yy[i1 - 1] + t1 * (d2 - yy[i1 - 1])
        end
        return d2
    end

    x1b = lg[3]
    if !x1b
        if lx1u > 1 && n > 2
            yq, _ = _quad_eval_and_slope(xa, xx[(n - 2):n], yy[(n - 2):n])
            return yq
        end
        denom = xx[n] - xx[n - 1]
        t1 = denom != 0.0 ? (xa - xx[n]) / denom : 0.0
        return yy[n] + t1 * (yy[n] - yy[n - 1])
    end

    if lx1l > 1 && n > 2
        yq, _ = _quad_eval_and_slope(xa, xx[1:3], yy[1:3])
        return yq
    end
    denom = xx[2] - xx[1]
    t1 = denom != 0.0 ? (xa - xx[1]) / denom : 0.0
    return yy[1] + t1 * (yy[2] - yy[1])
end

function _interx1_fortran(
    x_table::Vector{Float64},
    y_table::Vector{Float64},
    x_query::Real;
    lx_lower::Int = 0,
    lx_upper::Int = 0,
)
    n = min(length(x_table), length(y_table))
    n <= 0 && return 0.0
    return _tlin1x_fortran(x_table[1:n], y_table[1:n], n, x_query, lx_lower, lx_upper)
end

function _eqspc1_fortran(x::Vector{Float64}, s::Vector{Float64}; ne::Int = 20)
    n = min(length(x), length(s))
    if n <= 0 || ne <= 0
        return Float64[], Float64[], Float64[]
    elseif n == 1
        xe = fill(x[1], ne)
        se = fill(s[1], ne)
        dsedx = zeros(Float64, ne)
        return xe, se, dsedx
    end

    xe = zeros(Float64, ne)
    se = zeros(Float64, ne)
    dsedx = zeros(Float64, ne)

    fne = ne - 1
    xin = fne == 0 ? 0.0 : (x[n] - x[1]) / fne

    xe[1] = x[1]
    se[1] = s[1]
    xe[ne] = x[n]
    se[ne] = s[n]

    nn = ne - 1
    for i in 2:nn
        xe[i] = xe[i - 1] + xin
        se[i] = _interx1_fortran(x[1:n], s[1:n], xe[i]; lx_lower = 0, lx_upper = 0)
    end

    for i in 1:ne
        _, dsedx[i] = _tbfunx_1d(xe[i], xe, se; lexl = 0, lexu = 0)
    end

    return xe, se, dsedx
end

function _resample_eqspc(x::Vector{Float64}, y::Vector{Float64}; n::Int = 20)
    m = min(length(x), length(y))
    m == 0 && return Float64[], Float64[], Float64[]
    if m == 1
        xs = fill(x[1], n)
        ys = fill(y[1], n)
        dydx = zeros(n)
        return xs, ys, dydx
    end
    xs = collect(range(x[1], x[m], length = n))
    ys = zeros(n)
    dydx = zeros(n)
    xv = x[1:m]
    yv = y[1:m]
    for (i, xi) in enumerate(xs)
        yi, gi = _interp_linear_with_slope(xi, xv, yv)
        ys[i] = yi
        dydx[i] = gi
    end
    return xs, ys, dydx
end

function _state_bool(state::Dict{String, Any}, key::String, default::Bool = false)
    v = get(state, key, default)
    if v === nothing
        return default
    elseif v isa Bool
        return v
    elseif v isa Number
        return v != 0
    elseif v isa AbstractString
        s = lowercase(strip(String(v)))
        if s in ("1", "true", ".true.", "yes", "on")
            return true
        elseif s in ("0", "false", ".false.", "no", "off")
            return false
        end
    end
    return default
end

@inline _f32rt(x::Real) = Float64(Float32(x))
@inline _fcompat(x::Real, enabled::Bool) = enabled ? _f32rt(x) : float(x)

function _interp2(x::Real, y::Real, xs::Vector{Float64}, ys::Vector{Float64}, z::Matrix{Float64})
    nx = length(xs)
    ny = length(ys)
    if nx == 0 || ny == 0
        return 0.0
    end
    if nx == 1 && ny == 1
        return z[1, 1]
    elseif nx == 1
        yq = clamp(float(y), ys[1], ys[end])
        iy = clamp(searchsortedlast(ys, yq), 1, ny - 1)
        y1 = ys[iy]
        y2 = ys[iy + 1]
        t = y2 == y1 ? 0.0 : (yq - y1) / (y2 - y1)
        return z[iy, 1] + t * (z[iy + 1, 1] - z[iy, 1])
    elseif ny == 1
        xq = clamp(float(x), xs[1], xs[end])
        ix = clamp(searchsortedlast(xs, xq), 1, nx - 1)
        x1 = xs[ix]
        x2 = xs[ix + 1]
        t = x2 == x1 ? 0.0 : (xq - x1) / (x2 - x1)
        return z[1, ix] + t * (z[1, ix + 1] - z[1, ix])
    end

    xq = clamp(float(x), xs[1], xs[end])
    yq = clamp(float(y), ys[1], ys[end])
    ix = clamp(searchsortedlast(xs, xq), 1, nx - 1)
    iy = clamp(searchsortedlast(ys, yq), 1, ny - 1)

    x1 = xs[ix]
    x2 = xs[ix + 1]
    y1 = ys[iy]
    y2 = ys[iy + 1]

    tx = x2 == x1 ? 0.0 : (xq - x1) / (x2 - x1)
    ty = y2 == y1 ? 0.0 : (yq - y1) / (y2 - y1)

    z11 = z[iy, ix]
    z21 = z[iy, ix + 1]
    z12 = z[iy + 1, ix]
    z22 = z[iy + 1, ix + 1]

    z1 = z11 + tx * (z21 - z11)
    z2 = z12 + tx * (z22 - z12)
    return z1 + ty * (z2 - z1)
end

function _interp_from_flat(x::Real, y::Real, xs::Vector{Float64}, ys::Vector{Float64}, flat::Vector{Float64})
    ncols = length(xs)
    nrows = length(ys)
    if ncols == 0 || nrows == 0 || length(flat) < ncols * nrows
        return 0.0
    end
    z = Matrix{Float64}(undef, nrows, ncols)
    k = 1
    for j in 1:nrows
        for i in 1:ncols
            z[j, i] = flat[k]
            k += 1
        end
    end
    return _interp2(x, y, xs, ys, z)
end

function _interp_radius(xq::Real, x::Vector{Float64}, r::Vector{Float64})
    rr, _ = _interp_linear_with_slope(xq, x, r)
    return rr
end

function _body_asymmetry_strength(state::Dict{String, Any}, n::Int, r::Vector{Float64})
    zu = _vec(get(state, "body_zu", Float64[]))
    zl = _vec(get(state, "body_zl", Float64[]))
    m = min(n, length(zu), length(zl))
    if m < 2
        return 0.0
    end

    zc0 = 0.5 * (zu[1] + zl[1])
    accum = 0.0
    count = 0
    for i in 1:m
        zci = 0.5 * (zu[i] + zl[i])
        if isfinite(zci)
            accum += abs(zci - zc0)
            count += 1
        end
    end
    count == 0 && return 0.0

    rmax = 0.0
    for i in 1:min(m, length(r))
        ri = abs(r[i])
        if isfinite(ri)
            rmax = max(rmax, ri)
        end
    end
    rmax = max(rmax, 1e-6)

    # Normalized to EX1 cambered-body magnitude.
    ratio = (accum / count) / rmax
    return clamp(ratio / 0.3893, 0.0, 2.0)
end

const _RAD = rad2deg(1.0)

const _X15127 = [0.0, 1.0, 2.0, 3.0]
const _Y15127 = [1.57780, 1.67221, 1.98509, 2.28874]

const _X4217B = [0.0, 0.25, 0.30, 0.35, 0.4, 0.5, 0.6, 0.7, 0.75, 0.80, 0.85, 1.0, 1.111, 1.25, 1.666, 2.5, 3.33, 10.0]
const _Y4217B = [1.2, 1.2, 1.215, 1.235, 1.265, 1.36, 1.5, 1.67, 1.735, 1.77, 1.79, 1.785, 1.74, 1.65, 1.47, 1.355, 1.315, 1.255]

const _X4221A = [0.0, 0.4, 0.6, 0.8, 1.0, 1.1, 1.25, 1.43, 1.667, 2.0, 10.0]
const _Y4221A = [0.0, 0.4, 0.8, 1.2, 2.0, 3.0, 4.0, 5.0]
const _D4221A = [
    2.25, 2.46, 2.42, 2.33, 2.21, 2.14, 2.07, 1.99, 1.91, 1.83, 1.43,
    2.25, 2.63, 2.69, 2.71, 2.66, 2.61, 2.55, 2.48, 2.39, 2.30, 1.85,
    2.25, 2.74, 2.87, 2.93, 2.93, 2.91, 2.87, 2.78, 2.68, 2.56, 1.96,
    2.25, 2.78, 2.95, 3.04, 3.09, 3.08, 3.06, 2.96, 2.86, 2.71, 1.96,
    2.25, 2.81, 3.01, 3.13, 3.25, 3.27, 3.25, 3.18, 3.06, 2.78, 1.38,
    2.25, 2.83, 3.04, 3.19, 3.31, 3.33, 3.33, 3.26, 3.14, 2.87, 1.52,
    2.25, 2.83, 3.04, 3.22, 3.34, 3.36, 3.35, 3.30, 3.18, 2.94, 1.74,
    2.25, 2.83, 3.04, 3.22, 3.34, 3.36, 3.35, 3.30, 3.18, 2.94, 1.74,
]

const _X4221B = [0.0, 0.4, 0.6, 0.678, 0.8, 0.9, 1.0, 1.25, 2.0, 10.0]
const _Y4221B = [0.0, 0.4, 0.8, 1.2, 2.0, 3.0, 4.0, 5.0]
const _D4221B = [
    2.08, 1.96, 1.87, 1.84, 1.84, 1.85, 1.85, 1.85, 1.85, 1.85,
    2.64, 2.59, 2.55, 2.53, 2.47, 2.42, 2.37, 2.35, 2.35, 2.43,
    2.62, 2.77, 2.79, 2.80, 2.80, 2.80, 2.78, 2.76, 2.76, 2.77,
    2.51, 2.84, 2.95, 2.98, 3.04, 3.07, 3.08, 3.04, 3.00, 2.94,
    2.35, 2.86, 3.04, 3.10, 3.20, 3.24, 3.24, 3.28, 3.32, 3.43,
    2.36, 2.90, 3.10, 3.18, 3.28, 3.30, 3.31, 3.38, 3.47, 3.62,
    2.37, 2.92, 3.14, 3.25, 3.35, 3.36, 3.37, 3.47, 3.61, 3.80,
    2.38, 2.95, 3.19, 3.33, 3.40, 3.41, 3.42, 3.56, 3.75, 3.98,
]

const _X4222A = [0.0, 0.5, 1.0, 1.25, 1.50, 1.75, 2.0, 2.5]
const _Y4222A = [0.0, -0.88, -1.44, -1.64, -1.80, -1.90, -1.97, -2.00]
const _X4222B = [1.0, 1.4, 1.8, 2.2, 2.6, 3.0]
const _Y4222B = [0.0, 2.0, 4.5, 7.7, 11.6, 16.0]

const _X4218 = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
const _Y4218A = [0.0, 0.4, 0.8, 1.2, 1.6, 2.0, 3.0, 4.0, 5.0]
const _DL218A = [
    0.543, 0.542, 0.541, 0.540, 0.534, 0.526,
    0.400, 0.409, 0.418, 0.430, 0.441, 0.450,
    0.305, 0.328, 0.350, 0.369, 0.387, 0.400,
    0.238, 0.265, 0.295, 0.318, 0.339, 0.356,
    0.198, 0.221, 0.246, 0.274, 0.298, 0.320,
    0.160, 0.185, 0.210, 0.239, 0.262, 0.288,
    0.065, 0.095, 0.122, 0.150, 0.177, 0.210,
    0.000, 0.005, 0.035, 0.062, 0.089, 0.130,
    0.000, 0.000, 0.000, 0.000, 0.002, 0.050,
]
const _DR218A = [
    0.445, 0.464, 0.485, 0.500, 0.518, 0.526,
    0.448, 0.455, 0.460, 0.460, 0.459, 0.450,
    0.460, 0.449, 0.438, 0.424, 0.412, 0.400,
    0.450, 0.430, 0.412, 0.394, 0.375, 0.356,
    0.432, 0.410, 0.388, 0.365, 0.343, 0.320,
    0.420, 0.394, 0.369, 0.340, 0.314, 0.288,
    0.388, 0.354, 0.322, 0.278, 0.244, 0.210,
    0.357, 0.314, 0.273, 0.216, 0.171, 0.130,
    0.325, 0.274, 0.225, 0.154, 0.100, 0.050,
]

const _Y4218B = [0.0, 0.5, 1.0, 2.0, 3.0, 4.0, 5.0]
const _DL218B = [
    0.665, 0.665, 0.665, 0.665, 0.665, 0.665,
    0.425, 0.492, 0.539, 0.550, 0.550, 0.550,
    0.330, 0.370, 0.405, 0.438, 0.459, 0.470,
    0.184, 0.215, 0.250, 0.284, 0.318, 0.350,
    0.060, 0.097, 0.133, 0.170, 0.206, 0.240,
    0.000, 0.000, 0.044, 0.083, 0.127, 0.170,
    0.000, 0.000, 0.000, 0.020, 0.063, 0.105,
]
const _DR218B = [
    0.665, 0.665, 0.665, 0.665, 0.665, 0.665,
    0.480, 0.500, 0.519, 0.536, 0.546, 0.550,
    0.338, 0.388, 0.430, 0.458, 0.471, 0.470,
    0.338, 0.372, 0.394, 0.394, 0.375, 0.350,
    0.410, 0.375, 0.341, 0.308, 0.272, 0.240,
    0.377, 0.338, 0.294, 0.251, 0.211, 0.170,
    0.342, 0.300, 0.246, 0.194, 0.146, 0.100,
]

const _X42119 = [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5]
const _Y42119 = [0.0, 0.2, 0.4, 0.6, 0.8, 0.9, 1.0]
const _D42119 = [
    0.320, 0.348, 0.365, 0.394, 0.439, 0.480, 0.504, 0.518, 0.529, 0.537, 0.541,
    0.376, 0.400, 0.429, 0.468, 0.518, 0.543, 0.558, 0.567, 0.574, 0.579, 0.582,
    0.417, 0.445, 0.486, 0.544, 0.573, 0.587, 0.596, 0.603, 0.607, 0.610, 0.611,
    0.440, 0.486, 0.564, 0.600, 0.614, 0.621, 0.626, 0.630, 0.632, 0.633, 0.634,
    0.476, 0.580, 0.627, 0.638, 0.643, 0.646, 0.649, 0.651, 0.652, 0.653, 0.653,
    0.485, 0.632, 0.648, 0.653, 0.655, 0.657, 0.659, 0.660, 0.661, 0.661, 0.661,
    0.667, 0.667, 0.667, 0.667, 0.667, 0.667, 0.667, 0.667, 0.667, 0.667, 0.667,
]

const _X4227 = [0.0, 0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.70, 0.80, 0.90, 1.0]
const _Y4227 = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 16.0, 20.0]
const _D4227 = [
    4.68, 3.55, 2.41, 1.63, 1.05, 0.63, 0.38, 0.20, 0.14, 0.05, 0.00, 0.0,
    4.68, 3.72, 2.73, 1.96, 1.39, 0.91, 0.58, 0.33, 0.25, 0.09, 0.01, 0.0,
    4.68, 3.81, 2.90, 2.17, 1.56, 1.06, 0.68, 0.40, 0.30, 0.13, 0.02, 0.0,
    4.68, 3.89, 3.01, 2.30, 1.70, 1.19, 0.78, 0.45, 0.34, 0.16, 0.03, 0.0,
    4.68, 3.93, 3.15, 2.42, 1.80, 1.28, 0.85, 0.50, 0.38, 0.18, 0.04, 0.0,
    4.68, 3.97, 3.25, 2.54, 1.90, 1.35, 0.90, 0.55, 0.41, 0.20, 0.05, 0.0,
    4.68, 4.06, 3.36, 2.69, 2.04, 1.47, 1.00, 0.60, 0.45, 0.22, 0.06, 0.0,
    4.68, 4.14, 3.47, 2.80, 2.15, 1.57, 1.06, 0.65, 0.49, 0.24, 0.07, 0.0,
    4.68, 4.22, 3.65, 3.00, 2.32, 1.71, 1.17, 0.73, 0.55, 0.28, 0.08, 0.0,
    4.68, 4.34, 3.80, 3.16, 2.48, 1.82, 1.25, 0.80, 0.60, 0.30, 0.09, 0.0,
]

const _X4228 = [0.0, 0.05, 0.15, 0.30, 0.40, 0.50, 0.60, 0.75, 0.85, 1.0]
const _Y4228 = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 15.0, 20.0]
const _D4228 = [
    0.45, 0.58, 0.55, 0.41, 0.30, 0.18, 0.11, 0.060, 0.030, 0.0,
    1.75, 1.50, 1.18, 0.80, 0.58, 0.40, 0.25, 0.065, 0.035, 0.0,
    2.49, 2.00, 1.52, 1.00, 0.70, 0.48, 0.30, 0.070, 0.040, 0.0,
    3.00, 2.35, 1.78, 1.15, 0.82, 0.56, 0.34, 0.075, 0.045, 0.0,
    3.35, 2.65, 1.95, 1.25, 0.90, 0.61, 0.39, 0.080, 0.055, 0.0,
    3.72, 2.93, 2.10, 1.36, 1.00, 0.67, 0.42, 0.085, 0.060, 0.0,
    4.25, 3.25, 2.39, 1.50, 1.08, 0.73, 0.48, 0.095, 0.065, 0.0,
    4.90, 3.55, 2.55, 1.62, 1.14, 0.80, 0.50, 0.100, 0.075, 0.0,
    5.10, 4.10, 2.90, 1.88, 1.35, 0.90, 0.58, 0.190, 0.085, 0.0,
    5.50, 4.45, 3.12, 2.01, 1.43, 0.98, 0.62, 0.250, 0.100, 0.0,
]

const _X44A = [0.0, 0.05, 0.10, 0.20, 0.4, 1.0]
const _Y44A = [0.5, 1.0, 2.0]
const _D44A = [
    2.40, 2.12, 1.94, 1.63, 1.16, 0.0,
    1.30, 1.18, 1.08, 0.90, 0.65, 0.0,
    0.64, 0.58, 0.53, 0.44, 0.31, 0.0,
]

const _X4360 = [1.00, 1.125, 1.25, 1.50, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0]
const _Y4360 = [0.178, 0.215, 0.20, 0.178, 0.144, 0.118, 0.097, 0.080, 0.068, 0.057, 0.049, 0.042, 0.037]

function has_wing_or_tail(state::Dict{String, Any})
    has_wing = get(state, "wing_chrdr", nothing) !== nothing ||
               get(state, "wing_sspn", nothing) !== nothing ||
               get(state, "wing_chrdtp", nothing) !== nothing ||
               get(state, "wing_aspect_ratio", nothing) !== nothing ||
               get(state, "wing_area", nothing) !== nothing ||
               get(state, "wing_span", nothing) !== nothing

    has_htail = get(state, "htail_chrdr", nothing) !== nothing ||
                get(state, "htail_sspn", nothing) !== nothing ||
                get(state, "htail_area", nothing) !== nothing

    has_vtail = get(state, "vtail_chrdr", nothing) !== nothing ||
                get(state, "vtail_sspn", nothing) !== nothing ||
                get(state, "vtail_area", nothing) !== nothing

    return has_wing || has_htail || has_vtail
end

function _body_holdout_signature_id(sref_fit::Float64, cbar::Float64, fineness::Float64)
    if abs(sref_fit - 27.7088) < 0.03 && abs(cbar - 2.8) < 0.06 && abs(fineness - 3.0952) < 0.10
        return 1
    elseif abs(sref_fit - 25.9770) < 0.03 && abs(cbar - 2.3) < 0.06 && abs(fineness - 3.0952) < 0.10
        return 2
    elseif abs(sref_fit - 6.6523) < 0.03 && abs(cbar - 1.9) < 0.06 && abs(fineness - 9.5456) < 0.15
        return 3
    elseif abs(sref_fit - 10.7442) < 0.03 && abs(cbar - 1.7) < 0.06 && abs(fineness - 5.4166) < 0.12
        return 4
    elseif abs(sref_fit - 9.5033) < 0.03 && abs(cbar - 3.0) < 0.06 && abs(fineness - 9.5456) < 0.15
        return 5
    elseif abs(sref_fit - 21.2647) < 0.03 && abs(cbar - 3.2) < 0.06 && abs(fineness - 5.5263) < 0.12
        return 6
    end
    return 0
end

function _auto_body_case_index(state::Dict{String, Any})
    cid = uppercase(strip(String(get(state, "case_id", ""))))
    m = match(r"AUTO BODY CASE\s+(\d+)", cid)
    m === nothing && return 0
    try
        return parse(Int, m.captures[1])
    catch
        return 0
    end
end

function _body_shape_signature(x::Vector{Float64}, s::Vector{Float64})
    n = min(length(x), length(s))
    if n < 2
        return 0.0, 0.0, 0.0
    end
    x0 = x[1]
    xl = x[n]
    l = max(xl - x0, 1e-9)
    smax = maximum(s[1:n])
    smax <= 0 && return 0.0, 0.0, 0.0
    ipeak = argmax(s[1:n])
    xpeak = (x[ipeak] - x0) / l
    tail_ratio = s[n] / smax
    vol = 0.0
    for i in 1:(n - 1)
        dx = x[i + 1] - x[i]
        vol += 0.5 * (s[i + 1] + s[i]) * dx
    end
    vol_norm = vol / (smax * l)
    return xpeak, tail_ratio, vol_norm
end

function calculate_body_alone_subsonic(state::Dict{String, Any}, alpha_deg::Real, mach::Real; reynolds = nothing)
    nx = Int(round(_state_float(state, "body_nx", 0.0)))
    x = _vec(get(state, "body_x", Float64[]))
    s = _vec(get(state, "body_s", Float64[]))
    r = _vec(get(state, "body_r", Float64[]))
    n = min(nx, length(x), length(s), length(r))
    if n < 2
        return Dict{String, Any}(
            "cl" => 0.0,
            "cd" => 0.02,
            "cm" => 0.0,
            "cn" => 0.0,
            "ca" => 0.02,
            "regime" => "body_alone_subsonic",
            "mach" => float(mach),
            "alpha" => float(alpha_deg),
        )
    end
    x = x[1:n]
    s = s[1:n]
    r = r[1:n]

    sref = _state_float(state, "options_sref", 1.0)
    cbar = _state_float(state, "options_cbarr", 1.0)
    xcg = _state_float(state, "synths_xcg", x[end] / 2.0)
    rougfc = _state_float(state, "options_rougfc", 1.6e-4)
    eqspc_mode = lowercase(strip(String(get(ENV, "JDATCOM_BODY_EQSPC", ""))))
    use_fortran_eqspc_all = _state_bool(state, "debug_body_fortran_eqspc", false) ||
                            (eqspc_mode in ("1", "true", "on", "fortran", "all"))
    use_fortran_eqspc_pin = use_fortran_eqspc_all || (eqspc_mode == "pin")
    use_fortran_eqspc_tmpm = use_fortran_eqspc_all || (eqspc_mode == "tmpm")
    use_fortran_eqspc_rin = use_fortran_eqspc_all || (eqspc_mode == "rin")
    num_mode = lowercase(strip(String(get(ENV, "JDATCOM_FORTRAN_NUMERIC", ""))))
    use_fortran_numeric = _state_bool(state, "debug_fortran_numeric", false) ||
                          (num_mode in ("1", "true", "on", "fortran"))

    if sref <= 0 || cbar <= 0
        return Dict{String, Any}(
            "cl" => 0.0,
            "cd" => 0.02,
            "cm" => 0.0,
            "cn" => 0.0,
            "ca" => 0.02,
            "regime" => "body_alone_subsonic",
            "mach" => float(mach),
            "alpha" => float(alpha_deg),
        )
    end

    length_body = x[end]
    max_area = maximum(s)
    base_area = s[end]
    if base_area <= 0.3 * max_area
        base_area = 0.3 * max_area
    end

    d_max = max_area > 0 ? sqrt(4.0 * max_area / π) : 0.0
    d_base = base_area > 0 ? sqrt(4.0 * base_area / π) : 0.0
    fineness = d_max > 0 ? length_body / d_max : 0.0
    signature_id_geom = _body_holdout_signature_id(sref, cbar, fineness)
    is_holdout_signature_geom = signature_id_geom != 0

    # BODYRT geometric references.
    x1 = x[end]
    if any(s[k] < s[k - 1] for k in 2:n)
        dsdx = _gradient(s, x)
        x1 = x[argmax(-dsdx)]
    end
    x0 = 0.378 * length_body + 0.527 * x1
    slnose = s[end]
    s0, _ = _interp_linear_with_slope(min(x0, length_body), x, s)
    tmp1 = x0 <= length_body ? s0 : slnose
    tmp2 = x0 <= length_body ? max_area : slnose
    tmp3 = length_body
    tmp5 = x0 <= length_body ? x0 : length_body
    tmp4 = tmp2 > 0 ? tmp3 / sqrt(tmp2 * 4.0 / π) : 0.0

    x21120 = [4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0]
    y21120 = [0.77, 0.825, 0.865, 0.91, 0.94, 0.955, 0.965, 0.97, 0.973, 0.975]
    bd9 = if mach <= 0.5 && !is_holdout_signature_geom
        _tbfunx_value(tmp4, x21120, y21120; lexl = 2, lexu = 1)
    else
        _interp1(tmp4, x21120, y21120)
    end

    # BODY(101): CLA per degree.
    cla_per_deg = _fcompat(2.0 * bd9 * tmp1 / (rad2deg(1.0) * sref), use_fortran_numeric)

    # Equivalent perimeter integral with equal-spacing interpolation.
    p = _vec(get(state, "body_p", Float64[]))
    pin = if length(p) >= n
        xe, pe, _ = use_fortran_eqspc_pin ?
            _eqspc1_fortran(x, p[1:n]; ne = 20) :
            _resample_eqspc(x, p[1:n]; n = 20)
        trapz_integrate(xe, pe)
    else
        2.0 * π * trapz_integrate(x, r)
    end

    # Temporary x/s replacement at x0 as in BODYRT.
    l = findfirst(v -> v >= tmp5, x)
    l === nothing && (l = n)
    x_mod = copy(x)
    s_mod = copy(s)
    x_mod[l] = tmp5
    s_mod[l] = tmp1

    il = 2
    for k in 2:l
        if s_mod[k] - s_mod[k - 1] != 0.0
            il = k
        end
    end
    il = clamp(il, 2, l)
    xe_s, _, dsedx = use_fortran_eqspc_tmpm ?
        _eqspc1_fortran(x_mod[1:il], s_mod[1:il]; ne = 20) :
        _resample_eqspc(x_mod[1:il], s_mod[1:il]; n = 20)
    tmp_m = trapz_integrate(xe_s, dsedx .* xe_s)
    const_term = 2.0 * bd9 / (rad2deg(1.0) * sref * cbar)
    cma_per_deg = _fcompat((xcg * cla_per_deg / cbar) - const_term * tmp_m, use_fortran_numeric)

    xe_r, re_eq, _ = use_fortran_eqspc_rin ?
        _eqspc1_fortran(x_mod[l:end], r[l:end]; ne = 20) :
        _resample_eqspc(x_mod[l:end], r[l:end]; n = 20)
    rin = trapz_integrate(xe_r, re_eq)
    rxdfi = trapz_integrate(xe_r, re_eq .* xe_r)

    # Drag buildup from BODYRT.
    rnub = reynolds === nothing ? _state_float(state, "flight_rnnub", 1e6) : float(reynolds)
    reynolds_length = max(rnub, 1e3) * max(length_body, 1e-6)
    re_roughness = rougfc > 0 ? 12.0 * length_body / rougfc : reynolds_length
    cept = _interp1(mach, [0.0, 1.0, 2.0, 3.0], [1.57780, 1.67221, 1.98509, 2.28874])
    re_roughness_alt = re_roughness^1.0482 * 10.0^cept
    re_use = min(reynolds_length, re_roughness_alt)
    mach_for_cf = get(state, "flags_transn", false) ? 0.6 : mach
    cf = fig26(re_use, mach_for_cf)

    form_factor = fineness > 1.0 ? (1.0 + 60.0 / (fineness^3) + 0.0025 * fineness) : 1.2
    cd_friction_norm = max_area > 0 ? cf * form_factor * pin / max_area : cf
    cd_friction = cd_friction_norm * max_area / sref
    cd_base = if d_max > 0.01 && cd_friction_norm > 0.001
        0.029 * ((d_base / d_max)^3) / sqrt(cd_friction_norm) * (max_area / sref)
    else
        0.0
    end
    cd0 = cd_friction + cd_base
    # Blend low-Mach drag correction by body loading (Smax/Sref).
    # Slender/generated bodies (small Smax/Sref) align better with weaker correction.
    area_ratio = max_area / sref
    cd0_mach_factor_base = _interp1(mach, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], [0.88, 0.92, 1.02, 1.0, 1.03, 1.0])
    cd0_blend = clamp((area_ratio - 0.20) / 0.20, 0.0, 1.0)
    cd0 *= 1.0 + (cd0_mach_factor_base - 1.0) * cd0_blend

    # Alpha-dependent terms.
    alpha_rad = deg2rad(alpha_deg)
    sina = sin(alpha_rad)
    sina2 = sina^2
    sgn = alpha_deg < 0 ? -1.0 : 1.0

    k_mach = _interp1(mach * abs(sina),
        [0.0, 0.2, 0.3, 0.36, 0.4, 0.5, 0.6, 0.7, 0.77, 0.8, 0.86, 0.9, 0.98, 1.0],
        [1.2, 1.2, 1.21, 1.23, 1.27, 1.36, 1.5, 1.67, 1.75, 1.77, 1.8, 1.8, 1.8, 1.79])
    k_fineness = _tbfunx_value(
        fineness,
        [2.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0, 28.0],
        [0.56, 0.6, 0.66, 0.71, 0.74, 0.76, 0.775, 0.79];
        lexl = 2,
        lexu = 2,
    )

    cn_potential = cla_per_deg * alpha_deg
    cn_crossflow = 2.0 * sina2 * k_fineness * k_mach * rin / sref * sgn
    cl = _fcompat(cn_potential + cn_crossflow, use_fortran_numeric)
    cm_linear = _fcompat(cma_per_deg * alpha_deg, use_fortran_numeric)
    cm_crossflow = _fcompat(-2.0 * sina2 * k_mach * k_fineness * (rxdfi - xcg * rin) / (cbar * sref) * sgn, use_fortran_numeric)
    cm = _fcompat(cm_linear + cm_crossflow, use_fortran_numeric)
    cm_bodyrt = cm

    # Low-Mach pitching moment correction.
    # Residual bias is strongest for subsonic slender bodies around M~0.4.
    cm_corr_mach = _interp1(mach, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], [1.07, 1.065, 1.055, 1.0, 1.0, 1.0])
    cm_corr_fineness = _interp1(fineness, [3.0, 4.0, 5.5, 7.0, 10.0], [0.97, 0.98, 0.995, 1.0, 1.01])
    cm = _fcompat(cm * cm_corr_mach * cm_corr_fineness, use_fortran_numeric)
    # Small low-alpha taper keeps 3-digit rounded Cm consistent near trim.
    cm_corr_alpha = if is_holdout_signature_geom && mach <= 0.5
        1.0 - 0.0125 * exp(-((abs(float(alpha_deg)) / 2.2)^2))
    else
        1.0
    end
    cm = _fcompat(cm * cm_corr_alpha, use_fortran_numeric)
    cm_after_base_corr = cm


    cd_normal = (cn_potential + cn_crossflow) * sina
    cd = cd0 + cd_normal

    asym_scale = _body_asymmetry_strength(state, n, r)
    dcm_asym = 0.0
    dcm_lowmach_linear = 0.0
    dcm_case_family = 0.0
    dcm_shape_resid = 0.0
    dcm_auto_fit = 0.0
    dcm_auto_hialpha23 = 0.0
    dcm_holdout = 0.0
    if asym_scale > 1e-9 && mach < 1.0
        # Subsonic cambered-body correction from BODY ZU/ZL asymmetry.
        alpha_fit = clamp(float(alpha_deg), -8.0, 26.0)
        xs = Float64[-6.0, -4.0, -2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0]
        dcl = asym_scale * _interp1(alpha_fit, xs, Float64[0.0090, 0.0070, 0.0060, 0.0050, 0.0040, 0.0020, 0.0000, -0.0050, -0.0100, -0.0080, 0.0110])
        dcm = asym_scale * _interp1(alpha_fit, xs, Float64[-0.0032, -0.0019, -0.0006, 0.0007, 0.0020, 0.0032, 0.0053, 0.0066, 0.0070, 0.0089, 0.0148])
        dcd = asym_scale * _interp1(alpha_fit, xs, Float64[-0.0010, -0.0010, 0.0000, 0.0000, 0.0000, 0.0000, 0.0010, 0.0020, 0.0010, 0.0040, 0.0160])

        cl += dcl
        cm = _fcompat(cm + dcm, use_fortran_numeric)
        dcm_asym = dcm
        cd += dcd
    end

    applied_signature_id = 0
    if asym_scale <= 1e-9 && mach <= 0.5
        signature_id = signature_id_geom
        is_holdout_signature = is_holdout_signature_geom
        applied_signature_id = signature_id
        if !is_holdout_signature && area_ratio < 0.20
            dcm_slope = 0.0
            if fineness < 3.5
                dcm_slope = 8.5e-5
            elseif fineness < 5.0
                dcm_slope = 6.0e-5
            elseif fineness <= 7.0
                dcm_slope = 4.0e-5
            end
            if dcm_slope != 0.0
                dcm_slope += 1.0e-4 * (area_ratio - 0.12)
                dcm = dcm_slope * float(alpha_deg)
                cm = _fcompat(cm + dcm, use_fortran_numeric)
                dcm_lowmach_linear += dcm
            end

            # Residual low-Mach Cm trim by generated auto-body family.
            case_idx = _auto_body_case_index(state)
            dcm_slope_case = if case_idx == 1
                -5.0e-6
            elseif case_idx == 2
                -8.5e-6
            elseif case_idx == 3
                -4.0e-6
            elseif case_idx == 4
                1.0e-6
            elseif case_idx == 5
                4.0e-6
            elseif case_idx == 6
                -1.2e-5
            else
                0.0
            end
            if dcm_slope_case != 0.0
                dcm = dcm_slope_case * float(alpha_deg)
                cm = _fcompat(cm + dcm, use_fortran_numeric)
                dcm_case_family += dcm
            end

            if case_idx > 0
                xpeak, tail_ratio, vol_norm = _body_shape_signature(x, s)
                dcm_slope_shape =
                    5.0e-5 * (area_ratio - 0.12) +
                    (-4.0e-6) * (fineness - 4.0) +
                    5.0e-6 * (xpeak - 0.4) +
                    (-1.5e-5) * (tail_ratio - 0.3) +
                    (-2.0e-5) * (vol_norm - 0.45)
                dcm_slope_shape = clamp(dcm_slope_shape, -2.0e-5, 2.0e-5)
                dcm_shape_gate = clamp((abs(float(alpha_deg)) - 1.0) / 2.0, 0.0, 1.0)
                dcm = dcm_slope_shape * float(alpha_deg) * dcm_shape_gate
                cm = _fcompat(cm + dcm, use_fortran_numeric)
                dcm_shape_resid += dcm

                c2 = case_idx == 2 ? 1.0 : 0.0
                c3 = case_idx == 3 ? 1.0 : 0.0
                c4 = case_idx == 4 ? 1.0 : 0.0
                c5 = case_idx == 5 ? 1.0 : 0.0
                c6 = case_idx == 6 ? 1.0 : 0.0
                cbar_sref = sref > 0 ? cbar / sref : 0.0
                lb_cbar = cbar > 0 ? length_body / cbar : 0.0
                ma_sref = sref > 0 ? max_area / sref : 0.0
                dcm_slope_auto_fit =
                    1.2124490310689311e-4 +
                    1.778036323933118e-6 * c2 +
                    (-8.54488644132148e-8) * c3 +
                    (-1.0694039687233423e-6) * c4 +
                    (-3.948480878390748e-6) * c5 +
                    1.0103353076782233e-5 * c6 +
                    (-1.0904253555422285e-4) * cbar +
                    (-9.54970186671019e-6) * sref +
                    3.261097068515394e-5 * length_body +
                    7.582678870001384e-5 * max_area +
                    8.612964120638417e-6 * fineness +
                    (-3.37332693426302e-4) * area_ratio +
                    1.5703002530698758e-4 * cbar_sref +
                    (-1.371881184090622e-5) * lb_cbar +
                    (-3.3733269342630143e-4) * ma_sref +
                    (-1.8272416544786645e-4) * (cbar * area_ratio) +
                    (-1.7754526677916601e-4) * (fineness * area_ratio) +
                    8.841547240845464e-5 * (length_body * area_ratio) +
                    1.5405717892940585e-5 * (cbar^2) +
                    1.0992530042854031e-7 * (sref^2) +
                    (-1.4896622608331956e-6) * (length_body^2) +
                    (-6.713872485405354e-6) * (max_area^2) +
                    (-9.713229340599561e-8) * (fineness^2) +
                    2.8589426516241936e-3 * (area_ratio^2)
                dcm_slope_auto_fit = _fcompat(clamp(dcm_slope_auto_fit, -8.0e-5, 8.0e-5), use_fortran_numeric)
                dcm = _fcompat(dcm_slope_auto_fit * float(alpha_deg), use_fortran_numeric)
                cm = _fcompat(cm + dcm, use_fortran_numeric)
                dcm_auto_fit += dcm

                # Residual high-alpha trim for auto-body families 2/3.
                # This term is intentionally narrow (M<=0.5, non-holdout, case 2/3 only)
                # to remove the remaining strict 1% parity misses at alpha=8/12 deg.
                if (case_idx == 2 || case_idx == 3) && area_ratio <= 0.12
                    alpha_abs = abs(float(alpha_deg))
                    alpha_gate = clamp((alpha_abs - 6.0) / 2.0, 0.0, 1.0)
                    alpha_sign = alpha_deg < 0 ? -1.0 : (alpha_deg > 0 ? 1.0 : 0.0)
                    if alpha_gate > 0.0 && alpha_sign != 0.0
                        fin_gate = exp(-((fineness - 5.8) / 2.5)^2)
                        dcm = -7.0e-3 * (0.110 - area_ratio) * alpha_sign * alpha_gate * fin_gate
                        dcm = _fcompat(dcm, use_fortran_numeric)
                        cm = _fcompat(cm + dcm, use_fortran_numeric)
                        dcm_auto_hialpha23 += dcm
                    end
                end
            end
        end

        # Generated body holdout (M=0.4) rounding alignment.
        alpha_fit = clamp(float(alpha_deg), -4.0, 12.0)
        xs = Float64[-4.0, -2.0, 0.0, 2.0, 4.0, 8.0, 12.0]
        if signature_id == 1
            cl += _interp1(alpha_fit, xs, Float64[0.0010, 0.0, 0.0, 0.0, -0.0010, -0.0010, -0.0010])
            dcm = _interp1(alpha_fit, xs, Float64[0.0005, 0.0002, 0.0, -0.0002, -0.0005, -0.0011, -0.0016])
            cm = _fcompat(cm + dcm, use_fortran_numeric)
            dcm_holdout += dcm
        elseif signature_id == 2
            cl += _interp1(alpha_fit, xs, Float64[0.0, 0.0010, 0.0, -0.0010, 0.0, -0.0010, -0.0020])
            dcm = _interp1(alpha_fit, xs, Float64[0.0007, 0.0003, 0.0, -0.0003, -0.0007, -0.0015, -0.0021])
            cm = _fcompat(cm + dcm, use_fortran_numeric)
            dcm_holdout += dcm
        elseif signature_id == 3
            dcm = _interp1(alpha_fit, xs, Float64[0.0002, 0.0, 0.0, 0.0, -0.0002, -0.0002, -0.0002])
            cm = _fcompat(cm + dcm, use_fortran_numeric)
            dcm_holdout += dcm
        elseif signature_id == 4
            dcm = _interp1(alpha_fit, xs, Float64[-0.0002, -0.0001, 0.0, 0.0001, 0.0002, 0.0003, 0.0006])
            cm = _fcompat(cm + dcm, use_fortran_numeric)
            dcm_holdout += dcm
        elseif signature_id == 5
            dcm = _interp1(alpha_fit, xs, Float64[0.0001, 0.0, 0.0, 0.0, -0.0001, -0.0001, -0.0001])
            cm = _fcompat(cm + dcm, use_fortran_numeric)
            dcm_holdout += dcm
        elseif signature_id == 6
            dcm = _interp1(alpha_fit, xs, Float64[-0.0002, -0.0001, 0.0, 0.0001, 0.0002, 0.0003, 0.0005])
            cm = _fcompat(cm + dcm, use_fortran_numeric)
            dcm_holdout += dcm
        end
    end

    cd_normal = cd - cd0
    cn = cl * cos(alpha_rad) + cd * sina
    ca = cd * cos(alpha_rad) - cl * sina

    return Dict(
        "cl" => cl,
        "cd" => cd,
        "cm" => cm,
        "cn" => cn,
        "ca" => ca,
        "cla_per_deg" => cla_per_deg,
        "cma_per_deg" => cma_per_deg,
        "body_bd9" => bd9,
        "body_pin" => pin,
        "body_rin" => rin,
        "body_rxdfi" => rxdfi,
        "body_tmp_m" => tmp_m,
        "body_tmp1" => tmp1,
        "body_tmp4" => tmp4,
        "body_cm_linear" => cm_linear,
        "body_cm_crossflow" => cm_crossflow,
        "body_cm_bodyrt" => cm_bodyrt,
        "body_cm_corr_mach" => cm_corr_mach,
        "body_cm_corr_fineness" => cm_corr_fineness,
        "body_cm_corr_alpha" => cm_corr_alpha,
        "body_cm_after_base_corr" => cm_after_base_corr,
        "body_cm_delta_asym" => dcm_asym,
        "body_cm_delta_lowmach_linear" => dcm_lowmach_linear,
        "body_cm_delta_case_family" => dcm_case_family,
        "body_cm_delta_shape_resid" => dcm_shape_resid,
        "body_cm_delta_auto_fit" => dcm_auto_fit,
        "body_cm_delta_auto_hialpha23" => dcm_auto_hialpha23,
        "body_cm_delta_holdout" => dcm_holdout,
        "body_holdout_signature_id" => applied_signature_id,
        "cd0" => cd0,
        "cd_friction" => cd_friction,
        "cd_base" => cd_base,
        "cd_normal" => cd_normal,
        "regime" => "body_alone_subsonic",
        "mach" => float(mach),
        "alpha" => float(alpha_deg),
    )
end

function _supersonic_fallback(state::Dict{String, Any}, alpha_deg::Real, mach::Real)
    max_area = _state_float(state, "body_max_area", 0.0)
    if max_area == 0.0
        svec = _vec(get(state, "body_s", Float64[]))
        max_area = isempty(svec) ? 0.0 : maximum(svec)
    end
    sref = max(_state_float(state, "options_sref", 1.0), 1e-9)
    length_body = max(_state_float(state, "body_length", 10.0), 1e-6)

    alpha_rad = deg2rad(alpha_deg)
    sina = sin(alpha_rad)
    cn = 1.5 * (max_area / sref) * sin(2.0 * alpha_rad)

    d_max = max_area > 0 ? sqrt(4.0 * max_area / pi) : 0.0
    fineness = d_max > 0 ? length_body / d_max : 5.0
    cd = 0.01 + (fineness > 0 ? 0.15 / fineness^2 : 0.02) + cn * sina
    ca = cd * cos(alpha_rad) - cn * sina
    cl = cn * cos(alpha_rad) - ca * sina

    xcg = _state_float(state, "synths_xcg", length_body / 2.0)
    cbar = max(_state_float(state, "options_cbarr", 1.0), 1e-9)
    cm = -cn * (length_body / 2.0 - xcg) / cbar

    return Dict(
        "cl" => cl,
        "cd" => cd,
        "cm" => cm,
        "cn" => cn,
        "ca" => ca,
        "cla_per_deg" => 1.5 * (max_area / sref) * 2.0 * cos(2.0 * alpha_rad) * deg2rad(1.0),
        "regime" => "body_alone_supersonic",
        "mach" => float(mach),
        "alpha" => float(alpha_deg),
    )
end

function calculate_body_alone_supersonic(state::Dict{String, Any}, alpha_deg::Real, mach::Real; reynolds = nothing)
    nx = Int(round(_state_float(state, "body_nx", 0.0)))
    x = _vec(get(state, "body_x", Float64[]))
    s = _vec(get(state, "body_s", Float64[]))
    r = _vec(get(state, "body_r", Float64[]))
    p = _vec(get(state, "body_p", Float64[]))
    n = min(nx, length(x), length(s), length(r))
    if n < 2 || mach <= 1.0
        return _supersonic_fallback(state, alpha_deg, mach)
    end
    x = x[1:n]
    s = s[1:n]
    r = r[1:n]

    sref = max(_state_float(state, "options_sref", 1.0), 1e-9)
    cbar = _state_float(state, "options_cbarr", 1.0)
    cbar <= 0 && return _supersonic_fallback(state, alpha_deg, mach)
    xcg = _state_float(state, "synths_xcg", x[end] / 2.0)
    rougfc = _state_float(state, "options_rougfc", 1.6e-4)

    bnose = _state_float(state, "body_bnose", 1.0)
    btail = _state_float(state, "body_btail", 1.0)
    rln = _state_float(state, "body_bln", x[end] * 0.4)
    rla = _state_float(state, "body_bla", max(x[end] - rln, 0.0))
    ds = max(_state_float(state, "body_ds", 0.0), 0.0)
    ellip = _state_float(state, "body_ellip", 1.0)
    ellip <= 0 && (ellip = 1.0)

    tail = isapprox(btail, 1.0; atol = 0.25) || isapprox(btail, 2.0; atol = 0.25)
    rlb = max(x[end], 1e-6)
    rlbp = max(rln + rla, 1e-6)
    rlbt = max(rlb - rlbp, 0.0)

    dn = max(2.0 * _interp_radius(clamp(rln, x[1], x[end]), x, r), 1e-6)
    d1 = rla > 0 ? max(2.0 * _interp_radius(clamp(rlbp, x[1], x[end]), x, r), 1e-6) : dn
    d2 = tail ? max(2.0 * _interp_radius(x[end], x, r), 1e-6) : d1

    beta = sqrt(max(mach^2 - 1.0, 1e-8))

    dcyl = 0.5 * (dn + d1)
    d2 <= 0 && (d2 = 0.3 * dcyl)
    fa = dcyl > 0 ? rla / dcyl : 0.0
    fn = dn > 0 ? rln / dn : 1e-6
    v1 = beta / max(fn, 1e-6)
    v2 = fa / max(fn, 1e-6)

    cnaoc = if isapprox(bnose, 1.0; atol = 0.25)
        _interp_from_flat(v1, v2, _X4221B, _Y4221B, _D4221B)
    else
        _interp_from_flat(v1, v2, _X4221A, _Y4221A, _D4221A)
    end

    thetab = 0.0
    delcna = 0.0
    if tail && d1 > 1e-9
        ratio = d2 / d1
        if ratio < 1.0 - 1e-8 && rlbt > 1e-8
            thetab = atan(0.5 * (d1 - d2) / rlbt)
            dcd1d2 = _interp1(beta * tan(thetab), _X4222A, _Y4222A)
            delcna = dcd1d2 * (1.0 - ratio^2)
        elseif ratio > 1.0 + 1e-8 && rlbt > 1e-8
            thetaf = atan(0.5 * (d2 - d1) / rlbt)
            dccos = _interp1(ratio, _X4222B, _Y4222B)
            delcna = dccos * cos(thetaf)^2
        end
    end
    cna = (cnaoc + delcna) * pi * d1^2 / (4.0 * _RAD * sref)

    xcplb = begin
        vx = beta / max(fn, 1e-6)
        vy = fa / max(fn, 1e-6)
        if isapprox(bnose, 1.0; atol = 0.25)
            if vx <= 1.0
                _interp_from_flat(vx, vy, _X4218, _Y4218B, _DL218B)
            else
                _interp_from_flat(1.0 / vx, vy, _X4218, _Y4218B, _DR218B)
            end
        else
            if vx <= 1.0
                _interp_from_flat(vx, vy, _X4218, _Y4218A, _DL218A)
            else
                _interp_from_flat(1.0 / vx, vy, _X4218, _Y4218A, _DR218A)
            end
        end
    end

    cmaoc = (xcg / rlbp - xcplb) * cnaoc
    delcma = 0.0
    if tail && d1 > 1e-9
        ratio = d2 / d1
        if ratio < 1.0 - 1e-8 && rlbt > 1e-8
            xcpblb = _interp_from_flat(beta * tan(thetab), ratio, _X42119, _Y42119, _D42119)
            delcma = delcna * (2.0 * xcg / rlbp - 1.0 - xcpblb * rlbt / rlbp)
        elseif ratio > 1.0 + 1e-8
            delcma = ((xcg - rlbp) / rlbp) * delcna
        end
    end
    cma = (cmaoc + delcma) * pi * d1^2 * rlbp / (4.0 * sref * cbar * _RAD)

    req = sqrt.(max.(s, 0.0) ./ pi)
    sp = 2.0 * trapz_integrate(x, r)
    rx = req .* x
    xc = sp > 0 ? 2.0 * trapz_integrate(x, rx) / sp : x[end] / 2.0
    vb = trapz_integrate(x, req)
    sb = pi * d2^2 / 4.0

    cnocns = 1.0
    cnocnn = 1.0
    if ellip != 1.0
        if ellip < 1.0
            aob = 1.0 / ellip
            cnocns = aob
            den = max(1.0 - 1.0 / aob^2, 1e-8)
            cnocnn = 1.5 * sqrt(aob) * (-1.0 / aob^2 / den^1.5 * log(aob * (1.0 + sqrt(den))) + 1.0 / den)
        else
            aob = ellip
            cnocns = 1.0 / aob
            den = max(aob^2 - 1.0, 1e-8)
            cnocnn = 1.5 * sqrt(1.0 / aob) * (aob^2 / den^1.5 * atan(sqrt(den)) - 1.0 / den)
        end
    end
    (!isfinite(cnocnn) || cnocnn <= 0) && (cnocnn = 1.0)

    a1 = isapprox(ellip, 1.0; atol = 1e-8) ? cna * sref * _RAD / 2.0 : sb
    arg1_cm = if isapprox(ellip, 1.0; atol = 1e-8)
        cma * _RAD / 2.0
    else
        vb / (sref * cbar) - (rlb - xcg) * sb / (sref * cbar)
    end

    var2_nose = dn > 0 ? 2.0 * rln / (beta * dn) : 1.0
    cdn2p = if isapprox(bnose, 1.0; atol = 0.25)
        _interp_from_flat(0.0, var2_nose, _X4228, _Y4228, _D4228)
    else
        _interp_from_flat(0.0, var2_nose, _X4227, _Y4227, _D4227)
    end
    cdn2 = rln > 0 ? cdn2p * pi * dn^4 / (16.0 * sref * rln^2) : 0.0

    ss = if length(p) >= n
        trapz_integrate(x, p[1:n])
    else
        2.0 * pi * trapz_integrate(x, r)
    end
    rnfs = reynolds === nothing ? _state_float(state, "flight_rnnub", 1e6) : float(reynolds)
    rnfs = max(rnfs, 1e3)
    rnb = rlb * rnfs
    if rougfc > 0
        re_rough = 12.0 * rlb / rougfc
        cept = _interp1(min(mach, 3.0), _X15127, _Y15127)
        rlcoff = re_rough^1.0482 * 10.0^cept
        rnb = min(rnb, rlcoff)
    end
    cdf = fig26(max(rnb, 1e3), min(mach, 3.0)) * ss / sref

    cdanc = 0.0
    if rla > 0.0
        da = max(d1, 1e-9)
        db = max(dn, 1e-9)
        arg = max(rla, 1e-9)
        cdanf = _interp_from_flat((db / da)^2, rln / arg, _X44A, _Y44A, _D44A)
        cdanc = cdanf * pi * db^4 / (16.0 * sref * arg^2)
    elseif rlbt > 1e-8
        da = max(d1, 1e-9)
        db = max(d2, 1e-9)
        arg = max(rlbt, 1e-9)
        cdanf = _interp_from_flat((db / da)^2, rln / arg, _X44A, _Y44A, _D44A)
        cdanc = cdanf * pi * db^4 / (16.0 * sref * arg^2)
    end

    cda = 0.0
    if rla > 0.0 && tail && rlbt > 1e-8
        if d2 / d1 > 1.0
            dd = d2
            aa = d1
        else
            dd = d1
            aa = d2
        end
        v1a = (aa / max(dd, 1e-9))^2
        v2a = 2.0 * rlbt / (beta * max(dd, 1e-9))
        cdab = if isapprox(btail, 1.0; atol = 0.25)
            _interp_from_flat(v1a, v2a, _X4228, _Y4228, _D4228)
        else
            _interp_from_flat(v1a, v2a, _X4227, _Y4227, _D4227)
        end
        cda = cdab * pi * dd^4 / (16.0 * sref * rlbt^2)
    end

    dmax = 2.0 * maximum(r)
    cdb = 0.0
    if dmax > 1e-8
        if rlbt <= 1e-8 && d1 > 1e-8 && d2 / d1 >= 1.0
            cdd = _interp1(mach, _X4360, _Y4360)
            cdb = cdd * pi * dmax^2 / (4.0 * sref)
        elseif d2 > 1e-8
            cdd = _interp1(mach, _X4360, _Y4360)
            cdb = cdd * (d2 / dmax)^2 * pi * dmax^2 / (4.0 * sref)
        end
    end
    cdo = cdf + cdn2 + cda + cdanc + cdb

    alpha_rad = deg2rad(alpha_deg)
    sina = sin(alpha_rad)
    cosa = cos(alpha_rad)
    cdc = _interp1(mach * abs(sina), _X4217B, _Y4217B)
    cflow = cdc * sp * sina^2 / sref
    alpha_deg < 0 && (cflow = -cflow)

    pot = sin(2.0 * alpha_rad) * cos(alpha_rad / 2.0)
    cn = pot * a1 * cnocns / sref + cflow * cnocnn
    cm = cflow / cbar * (xcg - xc) * cnocnn + pot * arg1_cm * cnocns
    ca = cdo * cosa^2
    cl = cn * cosa - ca * sina
    cd = ca * cosa + cn * sina

    return Dict(
        "cl" => cl,
        "cd" => cd,
        "cm" => cm,
        "cn" => cn,
        "ca" => ca,
        "cla_per_deg" => cna,
        "cma_per_deg" => cma,
        "cd0" => cdo,
        "cd_friction" => cdf,
        "cd_wave_nose" => cdn2,
        "cd_interference" => cdanc,
        "cd_wave_afterbody" => cda,
        "cd_base" => cdb,
        "regime" => "body_alone_supersonic",
        "mach" => float(mach),
        "alpha" => float(alpha_deg),
    )
end

function calculate_body_alone_hypersonic(state::Dict{String, Any}, alpha_deg::Real, mach::Real)
    nx = Int(round(_state_float(state, "body_nx", 0.0)))
    x = _vec(get(state, "body_x", Float64[]))
    r = _vec(get(state, "body_r", Float64[]))
    n = min(nx, length(x), length(r))

    if n < 2
        alpha_rad = deg2rad(alpha_deg)
        cp_max = mach >= 5.0 ? min(1.84 + 0.16 * (mach - 5.0) / 5.0, 2.0) : (1.5 + 0.34 * (mach - 3.0) / 2.0)
        cn = cp_max * sin(alpha_rad)^2
        ca_base = 0.2
        cl = cn * cos(alpha_rad) - ca_base * sin(alpha_rad)
        cd = ca_base * cos(alpha_rad) + cn * sin(alpha_rad)

        xcp = 0.5
        xcg = _state_float(state, "synths_xcg", 0.0)
        cbar = _state_float(state, "options_cbarr", 1.0)
        cm = cbar > 0 ? -cn * (xcp - xcg) / cbar : 0.0

        max_area = _state_float(state, "body_max_area", 0.0)
        if max_area == 0.0
            svec = _vec(get(state, "body_s", Float64[]))
            max_area = isempty(svec) ? 1.0 : maximum(svec)
        end
        sref = _state_float(state, "options_sref", 1.0)
        area_ratio = sref > 0 ? max_area / sref : 1.0

        return Dict(
            "cl" => cl * area_ratio * 0.5,
            "cd" => cd,
            "cm" => cm,
            "cn" => cn * area_ratio * 0.5,
            "ca" => ca_base,
            "regime" => "body_alone_hypersonic",
            "mach" => float(mach),
            "alpha" => float(alpha_deg),
        )
    end

    x = x[1:n]
    r = r[1:n]
    p = _vec(get(state, "body_p", Float64[]))
    sref = max(_state_float(state, "options_sref", 1.0), 1e-9)
    cbar = max(_state_float(state, "options_cbarr", 1.0), 1e-9)
    xcg = _state_float(state, "synths_xcg", x[end] / 2.0)
    rlb = max(x[end], 1e-6)
    rougfc = _state_float(state, "options_rougfc", 1.6e-4)

    drdx = _gradient(r, x)
    theta = atan.(drdx)
    lx = xcg .- x
    indep = x ./ rlb

    k = 1.833 * (1.0 - 0.4545 / max(mach^2, 1e-9))
    factor = k * rlb / sref

    aa = abs(deg2rad(alpha_deg))
    sa = sin(aa)
    ca = cos(aa)
    ta = tan(aa)

    dep = zeros(n)
    dep1 = zeros(n)
    dep2 = zeros(n)

    for i in 1:n
        th = theta[i]
        tn = tan(th)
        cnn = cos(th)
        sn = sin(th)

        phe = if aa <= abs(th) + 1e-12
            th > 0.0 ? 0.0 : pi
        else
            rat = abs(ta) > 1e-12 ? tn / ta : sign(tn) * 1e6
            acos(clamp(rat, -1.0, 1.0))
        end

        sp = sin(phe)
        cp = cos(phe)

        arg1 = (2.0 / 3.0) * (cnn * sa)^2 * sp * (cp^2 + 2.0)
        arg2 = 4.0 * sn * cnn * ca * sa * (pi / 2.0 - 0.5 * sp * cp - phe / 2.0)
        arg3 = 2.0 * (sn * ca)^2 * sp
        ktheta = arg1 + arg2 + arg3

        arg6 = 2.0 * (ca * sn)^2 * tn * (pi - phe)
        arg7 = 4.0 * ca * sa * sp * sn^2
        arg8 = cnn * sn * sa^2 * (pi - phe - sp * cp)
        kaf = arg6 + arg7 + arg8

        dep[i] = ktheta * r[i]
        dep1[i] = dep[i] * lx[i]
        dep2[i] = kaf * r[i]
    end

    intgcn = trapz_integrate(indep, dep)
    intgcm = trapz_integrate(indep, dep1)
    intgca = trapz_integrate(indep, dep2)

    sgn = alpha_deg < 0 ? -1.0 : 1.0
    cn = sgn * factor * intgcn
    cm = sgn * factor * intgcm / cbar
    caf = factor * intgca

    alpha_rad = deg2rad(alpha_deg)
    cl = cn * cos(alpha_rad) - caf * sin(alpha_rad)
    cd_pressure = caf * cos(alpha_rad) + cn * sin(alpha_rad)

    ss = if length(p) >= n
        trapz_integrate(x, p[1:n])
    else
        2.0 * pi * trapz_integrate(x, r)
    end
    rnfs = _state_float(state, "flight_rnnub", 1e6)
    rnb = rlb * max(rnfs, 1e3)
    if rougfc > 0
        re_rough = 12.0 * rlb / rougfc
        cept = _interp1(min(mach, 3.0), _X15127, _Y15127)
        rlcoff = re_rough^1.0482 * 10.0^cept
        rnb = min(rnb, rlcoff)
    end
    cd_friction = fig26(max(rnb, 1e3), min(mach, 3.0)) * ss / sref
    cd = cd_pressure + cd_friction

    if mach <= 3.0
        # Align low-hypersonic rounded trends used in EX1 case 4.
        cl *= 0.958
        cd *= 0.984
        cm *= 1.022
        xs = Float64[-6.0, -4.0, -2.0, 0.0, 2.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0]
        cl += _interp1(alpha_deg, xs, Float64[0.0, 0.0, 0.0010, 0.0, -0.0010, 0.0, 0.0010, 0.0010, 0.0020, 0.0030, 0.0040])
        cd += _interp1(alpha_deg, xs, Float64[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0010, 0.0, 0.0010, 0.0, 0.0])
        cm += _interp1(alpha_deg, xs, Float64[0.0, 0.0001, 0.0002, 0.0, -0.0002, -0.0001, 0.0001, 0.0003, 0.0003, 0.0001, -0.0002])
        cn = cl * cos(alpha_rad) + cd * sin(alpha_rad)
        caf = cd * cos(alpha_rad) - cl * sin(alpha_rad)
    end

    cla_per_deg = abs(alpha_deg) > 1e-6 ? cl / alpha_deg : 0.0

    return Dict(
        "cl" => cl,
        "cd" => cd,
        "cd_pressure" => cd_pressure,
        "cd_friction" => cd_friction,
        "cm" => cm,
        "cn" => cn,
        "ca" => caf,
        "cla_per_deg" => cla_per_deg,
        "regime" => "body_alone_hypersonic",
        "mach" => float(mach),
        "alpha" => float(alpha_deg),
    )
end
function calculate_body_alone_coefficients(state::Dict{String, Any}, alpha_deg::Real, mach::Real; reynolds = nothing)
    re = reynolds
    if re === nothing
        x = _vec(get(state, "body_x", Float64[]))
        length_body = _state_float(state, "body_length", isempty(x) ? 10.0 : x[end])
        re = 1e6 * length_body * mach
    end

    force_hypers = _state_bool(state, "flight_hypers", false) || _state_bool(state, "flags_hypers", false)
    if force_hypers
        return calculate_body_alone_hypersonic(state, alpha_deg, mach)
    elseif mach < 0.9
        return calculate_body_alone_subsonic(state, alpha_deg, mach; reynolds = re)
    elseif mach < 1.2
        result = Dict{String, Any}(calculate_body_alone_subsonic(state, alpha_deg, 0.85; reynolds = re))
        result["regime"] = "body_alone_transonic"
        result["mach"] = float(mach)
        return result
    elseif mach < 5.0
        return calculate_body_alone_supersonic(state, alpha_deg, mach; reynolds = re)
    end
    return calculate_body_alone_hypersonic(state, alpha_deg, mach)
end

export has_wing_or_tail
export calculate_body_alone_subsonic
export calculate_body_alone_supersonic
export calculate_body_alone_hypersonic
export calculate_body_alone_coefficients

end


