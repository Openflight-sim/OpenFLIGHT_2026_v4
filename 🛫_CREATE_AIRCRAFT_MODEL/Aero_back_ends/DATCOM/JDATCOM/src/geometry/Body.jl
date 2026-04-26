module Body

using ...Utils: trapz_integrate

function _to_float(x, default = 0.0)
    if x === nothing
        return default
    elseif x isa Bool
        return x ? 1.0 : 0.0
    elseif x isa Number
        return float(x)
    elseif x isa AbstractString
        try
            return parse(Float64, x)
        catch
            return default
        end
    end
    return default
end

function _to_int(x, default = 0)
    if x === nothing
        return default
    elseif x isa Integer
        return Int(x)
    elseif x isa Number
        return Int(round(x))
    elseif x isa AbstractString
        try
            return Int(parse(Float64, x))
        catch
            return default
        end
    end
    return default
end

function _to_float_vector(v)
    if v === nothing
        return Float64[]
    elseif v isa AbstractVector
        out = Float64[]
        for item in v
            if item === nothing
                push!(out, NaN)
            else
                push!(out, _to_float(item, NaN))
            end
        end
        return out
    end
    return Float64[]
end

mutable struct BodyGeometry
    state::Dict{String, Any}
    nx::Int
    x::Vector{Float64}
    s::Vector{Float64}
    p::Vector{Float64}
    r::Vector{Float64}
    zu::Vector{Float64}
    zl::Vector{Float64}
    bnose::Float64
    btail::Float64
    bln::Union{Nothing, Float64}
    bla::Union{Nothing, Float64}
    ds::Float64
    itype::Int
    method::Int
end

function BodyGeometry(state::Dict{String, Any})
    nx = _to_int(get(state, "body_nx", 0), 0)
    bln = get(state, "body_bln", nothing)
    bla = get(state, "body_bla", nothing)

    return BodyGeometry(
        state,
        nx,
        _to_float_vector(get(state, "body_x", Float64[])),
        _to_float_vector(get(state, "body_s", Float64[])),
        _to_float_vector(get(state, "body_p", Float64[])),
        _to_float_vector(get(state, "body_r", Float64[])),
        _to_float_vector(get(state, "body_zu", Float64[])),
        _to_float_vector(get(state, "body_zl", Float64[])),
        _to_float(get(state, "body_bnose", 1.0), 1.0),
        _to_float(get(state, "body_btail", 1.0), 1.0),
        bln === nothing ? nothing : _to_float(bln, 0.0),
        bla === nothing ? nothing : _to_float(bla, 0.0),
        _to_float(get(state, "body_ds", 0.0), 0.0),
        _to_int(get(state, "body_itype", 2), 2),
        _to_int(get(state, "body_method", 1), 1),
    )
end

function _safe_argmax(v::Vector{Float64})
    if isempty(v)
        return 1
    end
    vv = [isnan(x) ? -Inf : x for x in v]
    return argmax(vv)
end

function calculate_properties(body::BodyGeometry)
    if body.nx < 2 || length(body.x) < 2 || length(body.s) < 2
        return Dict{String, Float64}()
    end

    length_body = body.x[end] - body.x[1]
    max_idx = _safe_argmax(body.s)
    max_area = body.s[max_idx]
    max_area_location = body.x[min(max_idx, length(body.x))]
    req_max = max_area > 0 ? sqrt(max_area / π) : 0.0
    fineness_ratio = req_max > 0 ? length_body / (2.0 * req_max) : 0.0

    volume = trapz_integrate(body.x, body.s)
    centroid = 0.0
    if volume > 1e-10
        x_s = [body.x[i] * body.s[i] for i in 1:min(length(body.x), length(body.s))]
        centroid = trapz_integrate(body.x[1:length(x_s)], x_s) / volume
    end

    return Dict(
        "length" => length_body,
        "volume" => volume,
        "centroid" => centroid,
        "max_area" => max_area,
        "max_area_location" => max_area_location,
        "fineness_ratio" => fineness_ratio,
    )
end

function calculate_equivalent_body(body::BodyGeometry)
    if body.nx < 2 || isempty(body.s) || isempty(body.x)
        return Dict{String, Any}()
    end

    n = min(length(body.s), length(body.x))
    req = [sqrt(max(body.s[i], 0.0) / π) for i in 1:n]
    rx = [req[i] * body.x[i] for i in 1:n]

    sp = 2.0 * trapz_integrate(body.x[1:n], req)
    vb = trapz_integrate(body.x[1:n], req)
    xc = sp > 0 ? 2.0 * trapz_integrate(body.x[1:n], rx) / sp : 0.0

    return Dict(
        "equivalent_radius" => req,
        "rx" => rx,
        "planform_area" => sp,
        "volume_integration" => vb,
        "centroid" => xc,
    )
end

function is_asymmetric(body::BodyGeometry)
    return !isempty(body.zu) || !isempty(body.zl)
end

function calculate_cross_sectional_properties(body::BodyGeometry, station_idx::Int)
    if station_idx < 1 || station_idx > body.nx
        throw(ArgumentError("Station index $station_idx out of range [1, $(body.nx)]"))
    end

    props = Dict{String, Float64}()
    props["x"] = station_idx <= length(body.x) ? body.x[station_idx] : 0.0
    props["area"] = station_idx <= length(body.s) ? body.s[station_idx] : 0.0
    props["perimeter"] = station_idx <= length(body.p) ? body.p[station_idx] : 0.0
    props["half_width"] = station_idx <= length(body.r) ? body.r[station_idx] : 0.0
    props["equivalent_radius"] = props["area"] > 0 ? sqrt(props["area"] / π) : 0.0

    if station_idx <= length(body.zu)
        props["z_upper"] = body.zu[station_idx]
    end
    if station_idx <= length(body.zl)
        props["z_lower"] = body.zl[station_idx]
    end
    if haskey(props, "z_upper") && haskey(props, "z_lower")
        props["z_centroid"] = (props["z_upper"] + props["z_lower"]) / 2.0
    end
    return props
end

function calculate_nose_properties(body::BodyGeometry)
    if body.bln === nothing || body.bln <= 0
        return Dict("type" => "none")
    end

    base_props = calculate_properties(body)
    max_area = get(base_props, "max_area", 0.0)
    base_idx = 1
    for i in 1:min(body.nx, length(body.s))
        if body.s[i] > 0.01 * max_area
            base_idx = i
            break
        end
    end

    base_area = base_idx <= length(body.s) ? body.s[base_idx] : 0.0
    base_radius = base_area > 0 ? sqrt(base_area / π) : 0.0
    nose_fineness = base_radius > 0 ? body.bln / (2.0 * base_radius) : 0.0

    return Dict(
        "type" => (body.bnose == 1.0 ? "conical" : "ogive"),
        "length" => body.bln,
        "bluntness_diameter" => body.ds,
        "base_radius" => base_radius,
        "base_area" => base_area,
        "fineness_ratio" => nose_fineness,
    )
end

function calculate_tail_properties(body::BodyGeometry)
    if body.bla === nothing || body.bla <= 0
        return Dict("type" => "none")
    end

    base_props = calculate_properties(body)
    base_area = get(base_props, "max_area", 0.0)
    base_radius = base_area > 0 ? sqrt(base_area / π) : 0.0
    tail_fineness = base_radius > 0 ? body.bla / (2.0 * base_radius) : 0.0

    return Dict(
        "type" => (body.btail == 1.0 ? "conical" : "ogive"),
        "length" => body.bla,
        "base_radius" => base_radius,
        "base_area" => base_area,
        "fineness_ratio" => tail_fineness,
    )
end

function to_state_dict(body::BodyGeometry)
    props = calculate_properties(body)
    return Dict{String, Any}(
        "body_length" => get(props, "length", 0.0),
        "body_volume" => get(props, "volume", 0.0),
        "body_centroid" => get(props, "centroid", 0.0),
        "body_max_area" => get(props, "max_area", 0.0),
        "body_max_area_x" => get(props, "max_area_location", 0.0),
        "body_fineness_ratio" => get(props, "fineness_ratio", 0.0),
    )
end

function calculate_body_geometry(state::Dict{String, Any})
    return calculate_properties(BodyGeometry(state))
end

function get_body_cross_section(state::Dict{String, Any}, x_location::Real)
    body = BodyGeometry(state)
    if body.nx < 2 || isempty(body.x)
        return Dict{String, Float64}()
    end

    if x_location <= body.x[1]
        return calculate_cross_sectional_properties(body, 1)
    elseif x_location >= body.x[end]
        return calculate_cross_sectional_properties(body, body.nx)
    end

    idx = searchsortedfirst(body.x, x_location)
    idx = clamp(idx, 1, body.nx)
    if idx > 1
        if abs(body.x[idx] - x_location) < abs(body.x[idx - 1] - x_location)
            return calculate_cross_sectional_properties(body, idx)
        else
            return calculate_cross_sectional_properties(body, idx - 1)
        end
    end
    return calculate_cross_sectional_properties(body, idx)
end

export BodyGeometry
export calculate_properties
export calculate_equivalent_body
export is_asymmetric
export calculate_cross_sectional_properties
export calculate_nose_properties
export calculate_tail_properties
export to_state_dict
export calculate_body_geometry
export get_body_cross_section

end
