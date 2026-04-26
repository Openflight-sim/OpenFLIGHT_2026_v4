module Subsonic

using ..Lift: calculate_wing_lift_subsonic, calculate_horizontal_tail_lift_subsonic
using ..Drag: calculate_total_drag
using ..Moment: calculate_total_pitching_moment

function calculate_prandtl_glauert_factor(mach::Real)
    if mach >= 1.0
        return 0.1
    end
    return sqrt(1.0 - mach^2)
end

function calculate_subsonic_coefficients(state::Dict{String, Any}, alpha_deg::Real, mach::Real, reynolds::Real)
    wing_lift_result = calculate_wing_lift_subsonic(state, alpha_deg, mach)
    tail_lift_result = calculate_horizontal_tail_lift_subsonic(state, alpha_deg, mach)
    cl_wing = wing_lift_result["cl"]
    cl_tail = tail_lift_result["cl"]
    cl = cl_wing + cl_tail

    drag_result = calculate_total_drag(state, cl, mach, reynolds; alpha_deg = alpha_deg)
    cd = drag_result["cd_total"]

    moment_result = calculate_total_pitching_moment(state, cl_wing, alpha_deg, mach)
    cm = moment_result["cm_total"]

    return Dict(
        "cl" => cl,
        "cd" => cd,
        "cm" => cm,
        "cla" => wing_lift_result["cla_per_deg"],
        "alpha_zero" => wing_lift_result["alpha_zero"],
        "cl_wing" => cl_wing,
        "cl_tail" => cl_tail,
        "cd_friction" => drag_result["cd_friction"],
        "cd_induced" => drag_result["cd_induced"],
        "cd_wave" => drag_result["cd_wave"],
        "cm_wing" => moment_result["cm_wing"],
        "cm_body" => moment_result["cm_body"],
        "regime" => "subsonic",
        "mach" => float(mach),
        "alpha" => float(alpha_deg),
        "reynolds" => float(reynolds),
    )
end

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

function calculate_lift_distribution_subsonic(state::Dict{String, Any}, cl::Real; n_stations::Int = 20)
    span = _state_float(state, "wing_span", 50.0)
    taper = _state_float(state, "wing_taper_ratio", 0.5)
    y = collect(range(0.0, span / 2.0, length = n_stations))
    cl_distribution = [(π / 4.0) * sqrt(max(0.0, 1.0 - (yi / (span / 2.0))^2)) for yi in y]
    cl_distribution .*= cl
    taper_effect = [1.0 + 0.3 * (1.0 - taper) * (1.0 - 2.0 * yi / span) for yi in y]
    cl_distribution .*= taper_effect
    return cl_distribution
end

export calculate_prandtl_glauert_factor
export calculate_subsonic_coefficients
export calculate_lift_distribution_subsonic

end
