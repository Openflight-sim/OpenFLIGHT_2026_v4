module MathUtils

using LinearAlgebra

function arcsin(a::Real)
    if abs(a) == 1.0
        return (π / 2) * sign(a)
    end
    if abs(a) > 1.0
        throw(DomainError(a, "arcsin argument is out of range [-1, 1]"))
    end
    return atan(a / sqrt(1.0 - a^2))
end

function arccos(a::Real)
    if a == 0.0
        return π / 2
    end
    if abs(a) > 1.0
        return log(abs(a + sqrt(a^2 - 1.0)))
    end
    x = atan(sqrt(1.0 - a^2) / a)
    return x < 0.0 ? π + x : x
end

function _triangle_area(x1, y1, x2, y2, x3, y3)
    a = hypot(x2 - x1, y2 - y1)
    b = hypot(x3 - x2, y3 - y2)
    c = hypot(x1 - x3, y1 - y3)
    s = (a + b + c) / 2.0
    return sqrt(max(0.0, s * (s - a) * (s - b) * (s - c)))
end

function area1(x::AbstractVector, y::AbstractVector, nsum::Integer)
    area = _triangle_area(x[1], y[1], x[2], y[2], x[3], y[3])
    if nsum == 4 || nsum == 6
        area += _triangle_area(x[1], y[1], x[4], y[4], x[3], y[3])
    end
    return area
end

function area2(x::AbstractVector, y::AbstractVector, inum::Integer)
    area = 0.0
    ax = 0.0
    ay = 0.0

    for i in 1:(inum - 1)
        da = (y[i] + y[i + 1]) * (x[i + 1] - x[i]) / 2.0
        area += da

        dx = x[i + 1] - x[i]
        dy = y[i + 1] - y[i]

        dax = (x[i] + dx / 3.0) * (y[i] * dx + dy * dx / 2.0)
        day = (y[i] / 2.0 + dy / 3.0) * (y[i] * dx + dy * dx / 2.0)
        ax += dax
        ay += day
    end

    if abs(area) > 1e-10
        ax /= area
        ay /= area
    end

    return area, ax, ay
end

function det4(a::AbstractVector)
    return det(reshape(collect(a), 4, 4))
end

function det4(a::AbstractMatrix)
    return det(a)
end

function solve_linear(a::AbstractMatrix, b::AbstractVector)
    return a \ b
end

function trapz_integrate(x::AbstractVector, y::AbstractVector)
    n = min(length(x), length(y))
    n < 2 && return 0.0
    acc = 0.0
    for i in 1:(n - 1)
        acc += (y[i] + y[i + 1]) * (x[i + 1] - x[i]) / 2.0
    end
    return acc
end

function linear_interp(x::Real, x_data::AbstractVector, y_data::AbstractVector)
    n = min(length(x_data), length(y_data))
    n == 0 && return 0.0
    n == 1 && return y_data[1]

    if x <= x_data[1]
        return y_data[1]
    elseif x >= x_data[n]
        return y_data[n]
    end

    idx = searchsortedlast(x_data, x)
    idx = clamp(idx, 1, n - 1)

    x1 = x_data[idx]
    x2 = x_data[idx + 1]
    y1 = y_data[idx]
    y2 = y_data[idx + 1]

    if x2 == x1
        return y1
    end

    frac = (x - x1) / (x2 - x1)
    return y1 + frac * (y2 - y1)
end

function sign(a::Real, b::Real)
    return abs(a) * (b == 0 ? 1.0 : Base.sign(b))
end

export arcsin
export arccos
export area1
export area2
export det4
export solve_linear
export trapz_integrate
export linear_interp
export sign

end
