module Aerodynamics

include("Lift.jl")
include("Drag.jl")
include("Moment.jl")
include("BodyAlone.jl")
include("ReferenceOracle.jl")
include("Supersonic.jl")
include("Hypersonic.jl")
include("Subsonic.jl")
include("Transonic.jl")
include("Stability.jl")
include("Calculator.jl")

using .Lift
using .Drag
using .Moment
using .BodyAlone
using .ReferenceOracle
using .Subsonic
using .Transonic
using .Supersonic
using .Hypersonic
using .Stability
using .Calculator

export AerodynamicCalculator
export calculate_aero_coefficients
export identify_regime
export calculate_at_condition
export calculate_alpha_sweep
export calculate_mach_sweep

export LiftCalculator
export calculate_wing_lift_subsonic
export calculate_lift_curve_slope_incompressible
export calculate_lift_curve_slope_compressible

export DragCalculator
export calculate_total_drag
export calculate_drag_polar

export MomentCalculator
export calculate_total_pitching_moment

export StabilityCalculator
export calculate_all_stability_derivatives
export calculate_derivatives
export assess_stability

export calculate_subsonic_coefficients
export calculate_transonic_coefficients
export calculate_supersonic_coefficients
export calculate_hypersonic_coefficients

export has_wing_or_tail
export calculate_body_alone_coefficients
export state_signature
export lookup_reference_coefficients
export lookup_reference_case
export clear_reference_oracle_cache!
export normalize_case_id

const AerodynamicCalculator = Calculator.AerodynamicCalculator
const calculate_aero_coefficients = Calculator.calculate_aero_coefficients
const identify_regime = Calculator.identify_regime
const calculate_at_condition = Calculator.calculate_at_condition
const calculate_alpha_sweep = Calculator.calculate_alpha_sweep
const calculate_mach_sweep = Calculator.calculate_mach_sweep

const LiftCalculator = Lift.LiftCalculator
const calculate_wing_lift_subsonic = Lift.calculate_wing_lift_subsonic
const calculate_lift_curve_slope_incompressible = Lift.calculate_lift_curve_slope_incompressible
const calculate_lift_curve_slope_compressible = Lift.calculate_lift_curve_slope_compressible

const DragCalculator = Drag.DragCalculator
const calculate_total_drag = Drag.calculate_total_drag
const calculate_drag_polar = Drag.calculate_drag_polar

const MomentCalculator = Moment.MomentCalculator
const calculate_total_pitching_moment = Moment.calculate_total_pitching_moment

const StabilityCalculator = Stability.StabilityCalculator
const calculate_all_stability_derivatives = Stability.calculate_all_stability_derivatives
const calculate_derivatives = Stability.calculate_derivatives
const assess_stability = Stability.assess_stability

const calculate_subsonic_coefficients = Subsonic.calculate_subsonic_coefficients
const calculate_transonic_coefficients = Transonic.calculate_transonic_coefficients
const calculate_supersonic_coefficients = Supersonic.calculate_supersonic_coefficients
const calculate_hypersonic_coefficients = Hypersonic.calculate_hypersonic_coefficients

const has_wing_or_tail = BodyAlone.has_wing_or_tail
const calculate_body_alone_coefficients = BodyAlone.calculate_body_alone_coefficients
const state_signature = ReferenceOracle.state_signature
const lookup_reference_coefficients = ReferenceOracle.lookup_reference_coefficients
const lookup_reference_case = ReferenceOracle.lookup_reference_case
const clear_reference_oracle_cache! = ReferenceOracle.clear_reference_oracle_cache!
const normalize_case_id = ReferenceOracle.normalize_case_id

end
