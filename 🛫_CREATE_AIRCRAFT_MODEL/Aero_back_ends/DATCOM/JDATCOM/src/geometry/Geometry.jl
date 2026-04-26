module Geometry

include("Airfoil.jl")
include("Body.jl")
include("Wing.jl")
include("Tail.jl")

using .Airfoil
using .Body
using .Wing
using .Tail

export AirfoilCoordinates
export NACAGenerator
export generate
export generate_naca_airfoil
export naca_4_digit
export naca_5_digit
export naca_4_digit_modified
export naca_5_digit_modified
export naca_1_series
export naca_6_series
export supersonic_airfoil

export BodyGeometry
export calculate_properties
export calculate_equivalent_body
export is_asymmetric
export calculate_cross_sectional_properties
export calculate_nose_properties
export calculate_tail_properties
export calculate_body_geometry
export get_body_cross_section

export WingGeometry
export calculate_planform_properties
export calculate_sweep_at_station
export calculate_panel_areas
export calculate_wing_geometry

export TailGeometry
export calculate_tail_geometry
export calculate_horizontal_tail
export calculate_vertical_tail

const AirfoilCoordinates = Airfoil.AirfoilCoordinates
const NACAGenerator = Airfoil.NACAGenerator
const generate = Airfoil.generate
const generate_naca_airfoil = Airfoil.generate_naca_airfoil
const naca_4_digit = Airfoil.naca_4_digit
const naca_5_digit = Airfoil.naca_5_digit
const naca_4_digit_modified = Airfoil.naca_4_digit_modified
const naca_5_digit_modified = Airfoil.naca_5_digit_modified
const naca_1_series = Airfoil.naca_1_series
const naca_6_series = Airfoil.naca_6_series
const supersonic_airfoil = Airfoil.supersonic_airfoil

const BodyGeometry = Body.BodyGeometry
const calculate_properties = Body.calculate_properties
const calculate_equivalent_body = Body.calculate_equivalent_body
const is_asymmetric = Body.is_asymmetric
const calculate_cross_sectional_properties = Body.calculate_cross_sectional_properties
const calculate_nose_properties = Body.calculate_nose_properties
const calculate_tail_properties = Body.calculate_tail_properties
const calculate_body_geometry = Body.calculate_body_geometry
const get_body_cross_section = Body.get_body_cross_section

const WingGeometry = Wing.WingGeometry
const calculate_planform_properties = Wing.calculate_planform_properties
const calculate_sweep_at_station = Wing.calculate_sweep_at_station
const calculate_panel_areas = Wing.calculate_panel_areas
const calculate_wing_geometry = Wing.calculate_wing_geometry

const TailGeometry = Tail.TailGeometry
const calculate_tail_geometry = Tail.calculate_tail_geometry
const calculate_horizontal_tail = Tail.calculate_horizontal_tail
const calculate_vertical_tail = Tail.calculate_vertical_tail

end
