module Airfoil

using Logging

mutable struct AirfoilCoordinates
    x::Vector{Float64}
    xu::Vector{Float64}
    yu::Vector{Float64}
    xl::Vector{Float64}
    yl::Vector{Float64}
    camber::Vector{Float64}
    thickness::Vector{Float64}
end

AirfoilCoordinates() = AirfoilCoordinates(Float64[], Float64[], Float64[], Float64[], Float64[], Float64[], Float64[])

function to_dict(coords::AirfoilCoordinates)
    return Dict(
        "x" => coords.x,
        "xu" => coords.xu,
        "yu" => coords.yu,
        "xl" => coords.xl,
        "yl" => coords.yl,
        "camber" => coords.camber,
        "thickness" => coords.thickness,
    )
end

mutable struct NACAGenerator
    num_points::Int
    x_stations::Vector{Float64}
end

function NACAGenerator(; num_points::Int = 60)
    beta = range(0.0, π, length = num_points)
    x_stations = [0.5 * (1.0 - cos(b)) for b in beta]
    return NACAGenerator(num_points, x_stations)
end

function _identify_series(designation::String)
    d = uppercase(replace(designation, "NACA" => ""))
    d = strip(d)

    if occursin('-', d)
        first_char = d[1]
        if first_char in ['1', '6', '7']
            return parse(Int, string(first_char))
        end
    end

    digits = filter(isdigit, d)
    if length(digits) == 4
        return 4
    elseif length(digits) == 5
        return 5
    end
    throw(ArgumentError("Cannot identify NACA series for $designation"))
end

function generate(generator::NACAGenerator, designation::String)
    series = _identify_series(designation)
    if series == 4
        return naca_4_digit(generator, designation)
    elseif series == 5
        return naca_5_digit(generator, designation)
    elseif series == 1
        return naca_1_series(generator, designation)
    elseif series == 6 || series == 7
        return naca_6_series(generator, designation)
    end
    throw(ArgumentError("Unknown NACA designation: $designation"))
end

function _thickness_distribution(x::Vector{Float64}, t::Float64)
    return 5.0 .* t .* (
        0.2969 .* sqrt.(x) .-
        0.1260 .* x .-
        0.3516 .* (x .^ 2) .+
        0.2843 .* (x .^ 3) .-
        0.1015 .* (x .^ 4)
    )
end

function naca_4_digit(generator::NACAGenerator, designation::String)
    digits = join(filter(isdigit, designation))
    length(digits) == 4 || throw(ArgumentError("Invalid 4-digit designation: $designation"))

    m = parse(Int, digits[1]) * 0.01
    p = parse(Int, digits[2]) * 0.1
    t = parse(Int, digits[3:4]) * 0.01

    coords = AirfoilCoordinates()
    coords.x = copy(generator.x_stations)
    x = coords.x

    yt = _thickness_distribution(x, t)
    yc = zeros(length(x))
    alpha = zeros(length(x))

    if !(m == 0.0 || p == 0.0)
        for i in eachindex(x)
            xi = x[i]
            if xi <= p && p > 0
                yc[i] = (2.0 * p * xi - xi^2) * m / p^2
                alpha[i] = atan((2.0 * m / p^2) * (p - xi))
            elseif xi > p && p < 1.0
                yc[i] = (m / (1.0 - p)^2) * (1.0 - 2.0 * p + 2.0 * p * xi - xi^2)
                alpha[i] = atan((2.0 * m / (1.0 - p)^2) * (p - xi))
            end
        end
    end

    coords.xu = x .- yt .* sin.(alpha)
    coords.yu = yc .+ yt .* cos.(alpha)
    coords.xl = x .+ yt .* sin.(alpha)
    coords.yl = yc .- yt .* cos.(alpha)
    coords.camber = yc
    coords.thickness = yt

    coords.thickness[1] = 0.0
    coords.thickness[end] = 0.0
    coords.camber[1] = 0.0
    coords.camber[end] = 0.0
    coords.xu[end] = 1.0
    coords.yu[end] = 0.0
    coords.xl[end] = 1.0
    coords.yl[end] = 0.0
    coords.xu[1] = 0.0
    coords.yl[1] = 0.0

    for i in eachindex(coords.camber)
        if abs(coords.camber[i]) < 1e-5
            coords.camber[i] = 0.0
        end
    end

    return coords
end

function naca_5_digit(generator::NACAGenerator, designation::String)
    digits = join(filter(isdigit, designation))
    length(digits) == 5 || throw(ArgumentError("Invalid 5-digit designation: $designation"))

    p_digit = parse(Int, digits[2])
    q = parse(Int, digits[3])
    t = parse(Int, digits[4:5]) * 0.01

    camber_params = Dict(
        0 => (0.05, 0.0580, 361.4),
        1 => (0.10, 0.1260, 51.64),
        2 => (0.15, 0.2025, 15.957),
        3 => (0.20, 0.2900, 6.643),
        4 => (0.25, 0.3910, 3.230),
    )
    haskey(camber_params, p_digit) || throw(ArgumentError("Invalid P digit $p_digit"))
    p, m, k1 = camber_params[p_digit]

    coords = AirfoilCoordinates()
    coords.x = copy(generator.x_stations)
    x = coords.x

    yt = _thickness_distribution(x, t)
    yc = zeros(length(x))
    alpha = zeros(length(x))

    if q == 0
        for i in eachindex(x)
            xi = x[i]
            if xi <= p && p > 0
                yc[i] = (k1 / 6.0) * (xi^3 - 3.0 * p * xi^2 + p^2 * (3.0 - p) * xi)
                alpha[i] = atan((k1 / 6.0) * (3.0 * xi^2 - 6.0 * p * xi + p^2 * (3.0 - p)))
            elseif xi > p && p < 1.0
                yc[i] = (k1 * p^3 / 6.0) * (1.0 - xi)
                alpha[i] = atan(-(k1 * p^3 / 6.0))
            end
        end
    else
        @warn "Reflex 5-digit camber uses simplified approximation"
        yc = m .* x .* (1.0 .- x)
        alpha = atan.(m .* (1.0 .- 2.0 .* x))
    end

    coords.xu = x .- yt .* sin.(alpha)
    coords.yu = yc .+ yt .* cos.(alpha)
    coords.xl = x .+ yt .* sin.(alpha)
    coords.yl = yc .- yt .* cos.(alpha)
    coords.camber = yc
    coords.thickness = yt

    coords.thickness[1] = 0.0
    coords.thickness[end] = 0.0
    coords.camber[1] = 0.0
    coords.camber[end] = 0.0
    coords.xu[end] = 1.0
    coords.yu[end] = 0.0
    coords.xl[end] = 1.0
    coords.yl[end] = 0.0
    coords.xu[1] = 0.0
    coords.yl[1] = 0.0

    for i in eachindex(coords.camber)
        if abs(coords.camber[i]) < 1e-5
            coords.camber[i] = 0.0
        end
    end

    return coords
end

function naca_4_digit_modified(generator::NACAGenerator, designation::String)
    parts = split(strip(replace(designation, "NACA" => "")), '-')
    base_code = parts[1]
    @warn "Using standard 4-digit thickness distribution for modified airfoil"
    return naca_4_digit(generator, base_code)
end

function naca_5_digit_modified(generator::NACAGenerator, designation::String)
    parts = split(strip(replace(designation, "NACA" => "")), '-')
    base_code = parts[1]
    @warn "Using standard 5-digit distribution for modified airfoil"
    return naca_5_digit(generator, base_code)
end

function naca_1_series(generator::NACAGenerator, designation::String)
    @warn "NACA 1-series uses simplified approximation"
    return naca_4_digit(generator, "0012")
end

function naca_6_series(generator::NACAGenerator, designation::String)
    d = strip(replace(designation, "NACA" => ""))
    parts = split(d, '-')
    if length(parts) < 2
        @warn "Invalid 6-series designation $designation, using NACA0012"
        return naca_4_digit(generator, "0012")
    end
    thick_camber = parts[2]
    if length(thick_camber) == 3
        approx = string("2", thick_camber[2:end])
        @warn "NACA 6-series uses 4-digit approximation ($approx)"
        return naca_4_digit(generator, approx)
    end
    @warn "NACA 6-series uses NACA0012 approximation"
    return naca_4_digit(generator, "0012")
end

function supersonic_airfoil(generator::NACAGenerator; thickness_ratio::Float64 = 0.05)
    coords = AirfoilCoordinates()
    coords.x = copy(generator.x_stations)
    x = coords.x

    yt = [xi <= 0.5 ? 2.0 * thickness_ratio * xi : 2.0 * thickness_ratio * (1.0 - xi) for xi in x]
    yc = zeros(length(x))
    alpha = zeros(length(x))

    coords.xu = x .- yt .* sin.(alpha)
    coords.yu = yc .+ yt .* cos.(alpha)
    coords.xl = x .+ yt .* sin.(alpha)
    coords.yl = yc .- yt .* cos.(alpha)
    coords.camber = yc
    coords.thickness = yt

    coords.thickness[1] = 0.0
    coords.thickness[end] = 0.0
    coords.xu[1] = 0.0
    coords.yl[1] = 0.0
    coords.xu[end] = 1.0
    coords.yu[end] = 0.0
    coords.xl[end] = 1.0
    coords.yl[end] = 0.0

    return coords
end

function generate_naca_airfoil(designation::String; num_points::Int = 60)
    generator = NACAGenerator(; num_points = num_points)
    return to_dict(generate(generator, designation))
end

export AirfoilCoordinates
export NACAGenerator
export to_dict
export generate
export naca_4_digit
export naca_5_digit
export naca_4_digit_modified
export naca_5_digit_modified
export naca_1_series
export naca_6_series
export supersonic_airfoil
export generate_naca_airfoil

end
