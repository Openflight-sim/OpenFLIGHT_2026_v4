module Wing

using Logging

function _fval(x, default = 0.0)
    if x === nothing
        return default
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

mutable struct WingGeometry
    state::Dict{String, Any}
    prefix::String
    chrdtp
    sspnop
    sspne
    sspn
    chrdbp
    chrdr
    savsi
    savso
    chstat
    twista
    dhdadi
    dhdado
    ptype
    tovc
    xovc
end

function WingGeometry(state::Dict{String, Any}; component::String = "wing")
    return WingGeometry(
        state,
        component,
        get(state, "$(component)_chrdtp", nothing),
        get(state, "$(component)_sspnop", nothing),
        get(state, "$(component)_sspne", nothing),
        get(state, "$(component)_sspn", nothing),
        get(state, "$(component)_chrdbp", nothing),
        get(state, "$(component)_chrdr", nothing),
        get(state, "$(component)_savsi", 0.0),
        get(state, "$(component)_savso", 0.0),
        get(state, "$(component)_chstat", 0.25),
        get(state, "$(component)_twista", 0.0),
        get(state, "$(component)_dhdadi", 0.0),
        get(state, "$(component)_dhdado", 0.0),
        get(state, "$(component)_type", 1.0),
        get(state, "$(component)_tovc", nothing),
        get(state, "$(component)_xovc", nothing),
    )
end

function calculate_planform_properties(wing::WingGeometry)
    sspn = wing.sspn === nothing ? nothing : _fval(wing.sspn, 0.0)
    sspne = wing.sspne === nothing ? nothing : _fval(wing.sspne, 0.0)
    chrdr = wing.chrdr === nothing ? nothing : _fval(wing.chrdr, 0.0)
    chrdtp = wing.chrdtp === nothing ? nothing : _fval(wing.chrdtp, 0.0)

    span = if sspn !== nothing
        2.0 * sspn
    elseif sspne !== nothing
        2.0 * sspne
    else
        0.0
    end

    area = 0.0
    taper_ratio = 0.0
    if chrdr !== nothing && sspn !== nothing
        if chrdtp !== nothing
            area = sspn * (chrdr + chrdtp)
            taper_ratio = chrdr > 0 ? chrdtp / chrdr : 0.0
        else
            @warn "Complex planform detected, using simplified area estimate"
            area = chrdr * sspn * 1.5
            taper_ratio = 0.5
        end
    end

    aspect_ratio = area > 0 ? span^2 / area : 0.0

    mac = 0.0
    mac_location = 0.0
    if chrdr !== nothing
        lambda_ratio = taper_ratio
        if (1.0 + lambda_ratio) != 0
            mac = (2.0 / 3.0) * chrdr * ((1.0 + lambda_ratio + lambda_ratio^2) / (1.0 + lambda_ratio))
        end
        if sspn !== nothing && sspn > 0 && (1.0 + lambda_ratio) != 0
            y_mac = (sspn / 3.0) * ((1.0 + 2.0 * lambda_ratio) / (1.0 + lambda_ratio))
            mac_location = 0.0 + 0.0 * y_mac
        end
    end

    return Dict(
        "area" => area,
        "span" => span,
        "aspect_ratio" => aspect_ratio,
        "taper_ratio" => taper_ratio,
        "mac" => mac,
        "mac_location" => mac_location,
    )
end

function calculate_sweep_at_station(wing::WingGeometry, x_c::Real)
    if wing.chstat === nothing
        return 0.0
    end
    sweep_ref = _fval(wing.savsi, 0.0) != 0.0 ? _fval(wing.savsi, 0.0) : _fval(wing.savso, 0.0)
    return sweep_ref + 0.0 * x_c
end

function calculate_panel_areas(wing::WingGeometry)
    props = calculate_planform_properties(wing)
    areas = Dict{String, Float64}()
    ptype = _fval(wing.ptype, 1.0)

    if ptype == 1.0
        areas["total"] = props["area"]
        areas["inboard"] = 0.0
        areas["outboard"] = props["area"]
    elseif ptype == 2.0
        chrdbp = _fval(wing.chrdbp, 0.0)
        sspnop = _fval(wing.sspnop, 0.0)
        chrdr = _fval(wing.chrdr, 0.0)
        chrdtp = _fval(wing.chrdtp, 0.0)
        sspn = _fval(wing.sspn, 0.0)
        if chrdbp > 0 && sspn > 0 && chrdr > 0
            inboard = sspnop * (chrdr + chrdbp) / 2.0
            span_out = sspn - sspnop
            outboard = span_out * (chrdbp + chrdtp) / 2.0
            areas["inboard"] = inboard
            areas["outboard"] = outboard
            areas["total"] = inboard + outboard
        else
            areas["total"] = 0.0
        end
    elseif ptype == 3.0
        @warn "Cranked wing area calculation is simplified"
        areas["total"] = props["area"]
    else
        areas["total"] = props["area"]
    end

    return areas
end

function to_state_dict(wing::WingGeometry)
    props = calculate_planform_properties(wing)
    p = wing.prefix
    return Dict{String, Any}(
        "$(p)_area" => props["area"],
        "$(p)_span" => props["span"],
        "$(p)_aspect_ratio" => props["aspect_ratio"],
        "$(p)_taper_ratio" => props["taper_ratio"],
        "$(p)_mac" => props["mac"],
        "$(p)_mac_location" => props["mac_location"],
    )
end

struct TailGeometry
    wing::WingGeometry
    tail_type::String
end

function TailGeometry(state::Dict{String, Any}; tail_type::String = "htail")
    return TailGeometry(WingGeometry(state; component = tail_type), tail_type)
end

calculate_planform_properties(t::TailGeometry) = calculate_planform_properties(t.wing)
calculate_panel_areas(t::TailGeometry) = calculate_panel_areas(t.wing)
to_state_dict(t::TailGeometry) = to_state_dict(t.wing)

function calculate_wing_geometry(state::Dict{String, Any})
    return calculate_planform_properties(WingGeometry(state; component = "wing"))
end

function calculate_tail_geometry(state::Dict{String, Any}; tail_type::String = "htail")
    return calculate_planform_properties(TailGeometry(state; tail_type = tail_type))
end

export WingGeometry
export TailGeometry
export calculate_planform_properties
export calculate_sweep_at_station
export calculate_panel_areas
export to_state_dict
export calculate_wing_geometry
export calculate_tail_geometry

end
