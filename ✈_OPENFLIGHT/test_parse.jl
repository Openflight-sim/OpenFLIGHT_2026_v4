using YAML
include("src/🟣JULIA🟣/1_Maths_and_Auxiliary_Functions/1.0_📚_Check_packages_and_websockets_port/🎁_load_required_packages.jl")
MISSION_DATA = Dict("aircraft_name" => "PC21_new.yaml")
include("src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.2.4_📈_get_constants_and_interpolate_coefficients.jl")
include("src/🟣JULIA🟣/0_Aircraft_Aerodynamic_Model/0.1_📊_aircraft_aerodynamic_and_propulsive_data.jl")
println("SUCCESS")
