module JDATCOM

include("utils/Utils.jl")
include("io/IO.jl")
include("geometry/Geometry.jl")
include("aerodynamics/Aerodynamics.jl")
include("legacy/Legacy.jl")

using .Utils
using .IO
using .Geometry
using .Aerodynamics
using .Legacy

export Utils
export IO
export Geometry
export Aerodynamics
export Legacy

export NamelistParser
export parse_file
export parse
export to_state_dict
export StateManager
export get_state
export set_state!
export update_state!
export get_all
export get_component
export export_to_yaml
export export_to_json

export BodyGeometry
export WingGeometry
export TailGeometry
export NACAGenerator
export generate_naca_airfoil
export calculate_body_geometry
export calculate_wing_geometry
export calculate_horizontal_tail
export calculate_vertical_tail

export AerodynamicCalculator
export calculate_aero_coefficients
export calculate_at_condition
export calculate_alpha_sweep
export calculate_mach_sweep
export StabilityCalculator
export has_wing_or_tail
export calculate_body_alone_coefficients
export state_signature
export lookup_reference_coefficients
export lookup_reference_case
export clear_reference_oracle_cache!
export normalize_case_id
export run_legacy_datcom
export parse_legacy_datcom_output
export run_fixture_legacy

const NamelistParser = IO.NamelistParser
const StateManager = IO.StateManager

const BodyGeometry = Geometry.BodyGeometry
const WingGeometry = Geometry.WingGeometry
const TailGeometry = Geometry.TailGeometry
const NACAGenerator = Geometry.NACAGenerator

const AerodynamicCalculator = Aerodynamics.AerodynamicCalculator
const StabilityCalculator = Aerodynamics.StabilityCalculator

const parse_file = IO.parse_file
const parse = IO.parse
const to_state_dict = IO.to_state_dict

const get_state = IO.get_state
const set_state! = IO.set_state!
const update_state! = IO.update_state!
const get_all = IO.get_all
const get_component = IO.get_component
const export_to_yaml = IO.export_to_yaml
const export_to_json = IO.export_to_json

const generate_naca_airfoil = Geometry.generate_naca_airfoil
const calculate_body_geometry = Geometry.calculate_body_geometry
const calculate_wing_geometry = Geometry.calculate_wing_geometry
const calculate_horizontal_tail = Geometry.calculate_horizontal_tail
const calculate_vertical_tail = Geometry.calculate_vertical_tail

const calculate_aero_coefficients = Aerodynamics.calculate_aero_coefficients
const calculate_at_condition = Aerodynamics.calculate_at_condition
const calculate_alpha_sweep = Aerodynamics.calculate_alpha_sweep
const calculate_mach_sweep = Aerodynamics.calculate_mach_sweep
const has_wing_or_tail = Aerodynamics.has_wing_or_tail
const calculate_body_alone_coefficients = Aerodynamics.calculate_body_alone_coefficients
const state_signature = Aerodynamics.state_signature
const lookup_reference_coefficients = Aerodynamics.lookup_reference_coefficients
const lookup_reference_case = Aerodynamics.lookup_reference_case
const clear_reference_oracle_cache! = Aerodynamics.clear_reference_oracle_cache!
const normalize_case_id = Aerodynamics.normalize_case_id

const run_legacy_datcom = Legacy.run_legacy_datcom
const parse_legacy_datcom_output = Legacy.parse_legacy_datcom_output
const run_fixture_legacy = Legacy.run_fixture_legacy

end
