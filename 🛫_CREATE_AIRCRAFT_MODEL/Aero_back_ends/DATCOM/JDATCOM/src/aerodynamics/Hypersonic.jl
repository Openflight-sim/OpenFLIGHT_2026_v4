module Hypersonic

function _state_float(state::Dict{String, Any}, key::String, default::Float64)
    v = get(state, key, default)
    if v === nothing
        return default
    elseif v isa Number
        return float(v)
    elseif v isa AbstractVector
        isempty(v) && return default
        if v[1] isa Number
            return float(v[1])
        elseif v[1] isa AbstractString
            try
                return parse(Float64, v[1])
            catch
                return default
            end
        end
        return default
    end
    return default
end

function calculate_hypersonic_coefficients(state::Dict{String, Any}, alpha_deg::Real, mach::Real)
    alpha_rad = deg2rad(alpha_deg)
    cp_max = if mach >= 5.0
        min(1.84 + 0.16 * (mach - 5.0) / 5.0, 2.0)
    else
        1.5 + 0.34 * (mach - 3.0) / 2.0
    end

    cn = cp_max * sin(alpha_rad)^2
    ca_base = 0.2

    cl = cn * cos(alpha_rad) - ca_base * sin(alpha_rad)
    cd = ca_base * cos(alpha_rad) + cn * sin(alpha_rad)

    xcp = 0.5
    xcg = _state_float(state, "synths_xcg", 0.0)
    cbar = _state_float(state, "options_cbarr", 1.0)
    cm = cbar > 0 ? -cn * (xcp - xcg) / cbar : 0.0

    return Dict(
        "cl" => cl,
        "cd" => cd,
        "cm" => cm,
        "cn" => cn,
        "ca" => ca_base,
        "cp_max" => cp_max,
        "xcp" => xcp,
        "regime" => "hypersonic",
        "mach" => float(mach),
        "alpha" => float(alpha_deg),
    )
end

export calculate_hypersonic_coefficients

end
