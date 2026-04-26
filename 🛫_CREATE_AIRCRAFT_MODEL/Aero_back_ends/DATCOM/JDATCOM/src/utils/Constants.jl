module Constants

const PI = π
const DEG = rad2deg(1.0)
const RAD = deg2rad(1.0)

const UNUSED = -999.0
const KAND = 0

function get_constants_dict()
    return Dict{String, Any}(
        "constants_pi" => PI,
        "constants_deg" => DEG,
        "constants_rad" => RAD,
        "constants_unused" => UNUSED,
        "constants_kand" => KAND,
    )
end

export PI
export DEG
export RAD
export UNUSED
export KAND
export get_constants_dict

end
