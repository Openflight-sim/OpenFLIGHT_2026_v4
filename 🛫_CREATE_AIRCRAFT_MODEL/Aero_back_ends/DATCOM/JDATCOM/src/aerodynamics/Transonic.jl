module Transonic

using ..Subsonic: calculate_subsonic_coefficients
using ..Supersonic: calculate_supersonic_coefficients

function calculate_transonic_coefficients(state::Dict{String, Any}, alpha_deg::Real, mach::Real, reynolds::Real)
    if mach < 0.9
        return calculate_subsonic_coefficients(state, alpha_deg, mach, reynolds)
    elseif mach > 1.2
        return calculate_supersonic_coefficients(state, alpha_deg, mach, reynolds)
    end

    sub_result = calculate_subsonic_coefficients(state, alpha_deg, 0.9, reynolds)
    sup_result = calculate_supersonic_coefficients(state, alpha_deg, 1.2, reynolds)

    frac = (mach - 0.9) / 0.3
    cl = sub_result["cl"] + frac * (sup_result["cl"] - sub_result["cl"])
    cd = sub_result["cd"] + frac * (sup_result["cd"] - sub_result["cd"])
    cm = sub_result["cm"] + frac * (sup_result["cm"] - sub_result["cm"])

    cd_divergence = 0.01 * sin(π * frac)^2
    cd += cd_divergence

    return Dict(
        "cl" => cl,
        "cd" => cd,
        "cm" => cm,
        "cd_divergence" => cd_divergence,
        "regime" => "transonic",
        "mach" => float(mach),
        "alpha" => float(alpha_deg),
        "interpolation_factor" => frac,
    )
end

export calculate_transonic_coefficients

end
