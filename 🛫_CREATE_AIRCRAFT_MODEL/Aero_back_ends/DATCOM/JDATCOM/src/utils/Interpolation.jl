module Interpolation

using ..MathUtils: linear_interp

function asmint(x_data::AbstractVector, y_data::AbstractVector, x_vals::AbstractVector)
    return [linear_interp(x, x_data, y_data) for x in x_vals]
end

function asmint(x_data::AbstractVector, y_data::AbstractVector, x_val::Real)
    return linear_interp(x_val, x_data, y_data)
end

function bilinear_interp(
    x::Real,
    y::Real,
    x_data::AbstractVector,
    y_data::AbstractVector,
    z_table::AbstractMatrix,
)
    nx = length(x_data)
    ny = length(y_data)
    if nx < 2 || ny < 2
        return z_table[1, 1]
    end

    x_clamped = clamp(x, x_data[1], x_data[end])
    y_clamped = clamp(y, y_data[1], y_data[end])

    ix = clamp(searchsortedlast(x_data, x_clamped), 1, nx - 1)
    iy = clamp(searchsortedlast(y_data, y_clamped), 1, ny - 1)

    x1 = x_data[ix]
    x2 = x_data[ix + 1]
    y1 = y_data[iy]
    y2 = y_data[iy + 1]

    q11 = z_table[iy, ix]
    q12 = z_table[iy + 1, ix]
    q21 = z_table[iy, ix + 1]
    q22 = z_table[iy + 1, ix + 1]

    tx = x2 == x1 ? 0.0 : (x_clamped - x1) / (x2 - x1)
    ty = y2 == y1 ? 0.0 : (y_clamped - y1) / (y2 - y1)

    z1 = q11 + tx * (q21 - q11)
    z2 = q12 + tx * (q22 - q12)
    return z1 + ty * (z2 - z1)
end

struct TableInterpolator
    x_data::Vector{Float64}
    y_data::Vector{Float64}
    z_table::Matrix{Float64}
end

function lookup(interp::TableInterpolator, x::Real, y::Real)
    return bilinear_interp(x, y, interp.x_data, interp.y_data, interp.z_table)
end

export asmint
export bilinear_interp
export TableInterpolator
export lookup

end
