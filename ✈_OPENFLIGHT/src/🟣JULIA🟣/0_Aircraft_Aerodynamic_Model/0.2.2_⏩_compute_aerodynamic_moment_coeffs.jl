function _moment_lookup_context(alpha_RAD, beta_RAD, Mach, control_demand_vector_attained)
    alpha_deg = rad2deg(alpha_RAD)
    beta_deg = rad2deg(beta_RAD)
    configuration = _configuration_from_control(control_demand_vector_attained, (default_configuration="clean",))
    return (
        alpha=alpha_deg,
        alpha_deg=alpha_deg,
        beta=beta_deg,
        beta_deg=beta_deg,
        mach=Float64(Mach),
        Mach=Float64(Mach),
        configuration=configuration,
        config=configuration
    )
end

# ── Schema v3.0: assemble static moments if the split tables are loaded ──
# Returns NamedTuple (Cl, Cm, Cn) or `nothing` when v3 is not active.
function _v3_static_moments(alpha_RAD, beta_RAD, Mach, aircraft_data, control_demand_vector_attained)
    get(aircraft_data, :use_component_assembly, false) || return nothing
    cfg = control_demand_vector_attained === nothing ? "clean" :
          string(get(control_demand_vector_attained, :configuration, "clean"))
    cg_xyz_m = [Float64(aircraft_data.x_CoG), Float64(aircraft_data.y_CoG), Float64(aircraft_data.z_CoG)]
    assembled = assemble_total_force_and_moment_coefficients(
        rad2deg(alpha_RAD), rad2deg(beta_RAD), Float64(Mach), cfg,
        aircraft_aero_and_propulsive_database,
        get(aircraft_data, :tail_surfaces, NamedTuple[]),
        aircraft_data.wing_mean_aerodynamic_chord,
        aircraft_data.reference_span,
        cg_xyz_m
    )
    return (Cl=assembled.Cl, Cm=assembled.Cm, Cn=assembled.Cn)
end

function _fetch_moment_coefficient_or_default(coeff_name::String, default_value::Float64; kwargs...)
    return _fetch_coefficient_with_default(coeff_name, default_value; kwargs...)
end

function _aircraft_data_scalar_with_alias(aircraft_data, primary::Symbol, fallback::Symbol, default_value::Float64)
    if hasproperty(aircraft_data, primary)
        return Float64(getproperty(aircraft_data, primary))
    end
    if hasproperty(aircraft_data, fallback)
        return Float64(getproperty(aircraft_data, fallback))
    end
    return default_value
end

# NOTE on units: aerodynamic YAMLs ship control-surface effectiveness in
# two possible forms:
#
#   (a) a TABLE keyed `Cl_da_per_deg` / `Cm_de_per_deg` / `Cn_dr_per_deg` /
#       `Cn_da_per_deg`, whose entries are **per degree** of deflection;
#   (b) a SCALAR stability derivative, keyed `Cl_delta_a` / `Cm_delta_e` /
#       `Cn_delta_r` / `Cn_delta_a` (aliased from `Cl_da` etc. at load
#       time), whose value is **per radian** of deflection.
#
# Each function below tries the per-degree table first (preferred when
# available — it can be non-linear in α/β/Mach/config) and multiplies by
# deflection in DEGREES. If the table is absent it falls back to the
# per-radian scalar and multiplies by deflection in RADIANS. Either way,
# the returned quantity is a non-dimensional moment coefficient in the
# standard aero convention that the sim expects.
#
# This matches the backup's table path on the `deg2rad` side AND keeps the
# per-degree table support that the baseline introduced for databases
# exported directly from DATCOM / VortexLattice.

function 🟢_rolling_moment_coefficient_due_to_control_attained(
    alpha_RAD,
    beta_RAD,
    Mach,
    aircraft_data,
    aircraft_state,
    control_demand_vector_attained
)
    lookup = _moment_lookup_context(alpha_RAD, beta_RAD, Mach, control_demand_vector_attained)
    cl_da_per_deg = _fetch_moment_coefficient_or_default("Cl_da_per_deg", 0.0; pairs(lookup)...)
    if cl_da_per_deg != 0.0
        return cl_da_per_deg *
               control_demand_vector_attained.roll_demand_attained *
               aircraft_data.max_aileron_deflection_deg
    end
    cl_da_per_rad = _aircraft_data_scalar_with_alias(aircraft_data, :Cl_delta_a, :Cl_da, 0.0)
    return cl_da_per_rad *
           control_demand_vector_attained.roll_demand_attained *
           deg2rad(aircraft_data.max_aileron_deflection_deg)
end

function 🟢_yawing_moment_coefficient_due_to_yaw_control_attained(
    alpha_RAD,
    beta_RAD,
    Mach,
    aircraft_data,
    aircraft_state,
    control_demand_vector_attained
)
    lookup = _moment_lookup_context(alpha_RAD, beta_RAD, Mach, control_demand_vector_attained)
    cn_dr_per_deg = _fetch_moment_coefficient_or_default("Cn_dr_per_deg", 0.0; pairs(lookup)...)
    if cn_dr_per_deg != 0.0
        return cn_dr_per_deg *
               control_demand_vector_attained.yaw_demand_attained *
               aircraft_data.max_rudder_deflection_deg
    end
    cn_dr_per_rad = _aircraft_data_scalar_with_alias(aircraft_data, :Cn_delta_r, :Cn_dr, 0.0)
    return cn_dr_per_rad *
           control_demand_vector_attained.yaw_demand_attained *
           deg2rad(aircraft_data.max_rudder_deflection_deg)
end

function 🟢_yawing_moment_coefficient_due_to_roll_control_attained(
    alpha_RAD,
    beta_RAD,
    Mach,
    aircraft_data,
    aircraft_state,
    control_demand_vector_attained
)
    lookup = _moment_lookup_context(alpha_RAD, beta_RAD, Mach, control_demand_vector_attained)
    cn_da_per_deg = _fetch_moment_coefficient_or_default("Cn_da_per_deg", 0.0; pairs(lookup)...)
    if cn_da_per_deg != 0.0
        return cn_da_per_deg *
               control_demand_vector_attained.roll_demand_attained *
               aircraft_data.max_aileron_deflection_deg
    end
    cn_da_per_rad = _aircraft_data_scalar_with_alias(aircraft_data, :Cn_delta_a, :Cn_da, 0.0)
    return cn_da_per_rad *
           control_demand_vector_attained.roll_demand_attained *
           deg2rad(aircraft_data.max_aileron_deflection_deg)
end

function 🟢_rolling_moment_coefficient_due_to_yaw_control_attained(
    alpha_RAD,
    beta_RAD,
    Mach,
    aircraft_data,
    aircraft_state,
    control_demand_vector_attained
)
    lookup = _moment_lookup_context(alpha_RAD, beta_RAD, Mach, control_demand_vector_attained)
    cl_dr_per_deg = _fetch_moment_coefficient_or_default("Cl_dr_per_deg", 0.0; pairs(lookup)...)
    if cl_dr_per_deg != 0.0
        return cl_dr_per_deg *
               control_demand_vector_attained.yaw_demand_attained *
               aircraft_data.max_rudder_deflection_deg
    end
    cl_dr_per_rad = _aircraft_data_scalar_with_alias(aircraft_data, :Cl_delta_r, :Cl_dr, 0.0)
    return cl_dr_per_rad *
           control_demand_vector_attained.yaw_demand_attained *
           deg2rad(aircraft_data.max_rudder_deflection_deg)
end

function 🟢_pitching_moment_coefficient_due_to_control_attained(
    alpha_RAD,
    beta_RAD,
    Mach,
    aircraft_data,
    aircraft_state,
    control_demand_vector_attained
)
    lookup = _moment_lookup_context(alpha_RAD, beta_RAD, Mach, control_demand_vector_attained)
    # With v3 split tables active, the stiffness branch already returns the
    # full static Cm(α,β) from the wing_body/tail assembler — that table has
    # Cm0 and Cm_trim baked in. Suppress them here to avoid double-counting.
    v3_active = get(aircraft_data, :use_component_assembly, false)
    cm0     = v3_active ? 0.0 : _fetch_moment_coefficient_or_default("Cm0",     aircraft_data.Cm0;     pairs(lookup)...)
    cm_trim = v3_active ? 0.0 : _fetch_moment_coefficient_or_default("Cm_trim", aircraft_data.Cm_trim; pairs(lookup)...)

    cm_de_per_deg = _fetch_moment_coefficient_or_default("Cm_de_per_deg", 0.0; pairs(lookup)...)
    if cm_de_per_deg != 0.0
        # Stick back (pitch_demand = +1) → TE-UP elevator → negative δe.
        # cm_de_per_deg is negative (standard), so cm_de × (-δe_deg) > 0,
        # which gives a positive (nose-up) pitching-moment contribution.
        elevator_deflection_deg = -control_demand_vector_attained.pitch_demand_attained * aircraft_data.max_elevator_deflection_deg
        return cm_de_per_deg * elevator_deflection_deg + cm0 + cm_trim
    end
    cm_de_per_rad = _aircraft_data_scalar_with_alias(aircraft_data, :Cm_delta_e, :Cm_de, -1.50)
    elevator_deflection_rad = -control_demand_vector_attained.pitch_demand_attained * deg2rad(aircraft_data.max_elevator_deflection_deg)
    return cm_de_per_rad * elevator_deflection_rad + cm0 + cm_trim
end

function 🟢_yawing_moment_coefficient_due_to_aerodynamic_stiffness(
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    control_demand_vector_attained
)
    v3 = _v3_static_moments(alpha_RAD, beta_RAD, Mach_number, aircraft_data, control_demand_vector_attained)
    if v3 !== nothing
        return v3.Cn
    end
    lookup = _moment_lookup_context(alpha_RAD, beta_RAD, Mach_number, control_demand_vector_attained)
    cn_beta = _fetch_moment_coefficient_or_default("Cn_beta", aircraft_data.Cn_beta; pairs(lookup)...)
    return cn_beta * beta_RAD
end

function 🟢_rolling_moment_coefficient_due_to_sideslip(
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    control_demand_vector_attained
)
    v3 = _v3_static_moments(alpha_RAD, beta_RAD, Mach_number, aircraft_data, control_demand_vector_attained)
    if v3 !== nothing
        # v3 already has dihedral-effect sign embedded via the tail r×F
        # transfer and the wb table from full_envelope (which itself
        # applied the empirical sign). No extra flip needed.
        return v3.Cl
    end
    lookup = _moment_lookup_context(alpha_RAD, beta_RAD, Mach_number, control_demand_vector_attained)
    cl_beta = _fetch_moment_coefficient_or_default("Cl_beta", aircraft_data.Cl_beta; pairs(lookup)...)
    # Empirical -1 patch (matches backup 0.2.2:103 and the linear model in
    # 0.3_🧮_linear_aerodynamic_model.jl): the simulator frame convention
    # requires an extra sign flip on the rolling moment from sideslip for
    # the dihedral effect to actually restore. Do NOT remove without
    # empirically re-verifying that positive β still produces a restoring
    # roll in both the table and linear paths.
    return -1.0 * cl_beta * beta_RAD
end

function 🟢_pitching_moment_coefficient_due_to_aerodynamic_stiffness(
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    control_demand_vector_attained
)
    v3 = _v3_static_moments(alpha_RAD, beta_RAD, Mach_number, aircraft_data, control_demand_vector_attained)
    if v3 !== nothing
        return v3.Cm
    end
    lookup = _moment_lookup_context(alpha_RAD, beta_RAD, Mach_number, control_demand_vector_attained)
    cm_alpha = _fetch_moment_coefficient_or_default("Cm_alpha", aircraft_data.Cm_alpha; pairs(lookup)...)
    return cm_alpha * alpha_RAD
end

function 🟢_rolling_moment_coefficient_due_to_aerodynamic_damping(
    p_roll_rate,
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    v_body_magnitude,
    configuration
)
    cl_p = _fetch_moment_coefficient_or_default("Cl_p", aircraft_data.Cl_p,
        mach=Mach_number, alpha=rad2deg(alpha_RAD), beta=rad2deg(beta_RAD),
        config=configuration, configuration=configuration)
    return cl_p * p_roll_rate * aircraft_data.reference_span / (v_body_magnitude * 2.0 + 0.001)
end

function 🟢_yawing_moment_coefficient_due_to_aerodynamic_damping(
    r_yaw_rate,
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    v_body_magnitude,
    configuration
)
    cn_r = _fetch_moment_coefficient_or_default("Cn_r", aircraft_data.Cn_r,
        mach=Mach_number, alpha=rad2deg(alpha_RAD), beta=rad2deg(beta_RAD),
        config=configuration, configuration=configuration)
    return cn_r * r_yaw_rate * aircraft_data.reference_span / (v_body_magnitude * 2.0 + 0.001)
end

function 🟢_pitching_moment_coefficient_due_to_aerodynamic_damping(
    q_pitch_rate,
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    v_body_magnitude,
    configuration
)
    cm_q = _fetch_moment_coefficient_or_default("Cm_q", aircraft_data.Cm_q,
        mach=Mach_number, alpha=rad2deg(alpha_RAD), beta=rad2deg(beta_RAD),
        config=configuration, configuration=configuration)
    return cm_q * q_pitch_rate * aircraft_data.wing_mean_aerodynamic_chord / (v_body_magnitude * 2.0 + 0.001)
end

"""
    🟢_pitching_moment_coefficient_due_to_alpha_dot(q, α, β, M, aircraft_data, V, cfg)

Downwash-lag pitch damping:  ΔCm = Cm_α̇ · α̇ · c/(2V).
Uses α̇ ≈ q (pitch rate), the standard quasi-static flight-dynamics
approximation. When Cm_α̇ is absent from the database this returns 0,
so aircraft without the term continue to fly as before.
"""
function 🟢_pitching_moment_coefficient_due_to_alpha_dot(
    q_pitch_rate,
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    v_body_magnitude,
    configuration
)
    cm_alpha_dot = _fetch_moment_coefficient_or_default("Cm_alpha_dot", 0.0,
        mach=Mach_number, alpha=rad2deg(alpha_RAD), beta=rad2deg(beta_RAD),
        config=configuration, configuration=configuration)
    alpha_dot_approx = q_pitch_rate      # quasi-static: α̇ ≈ q
    return cm_alpha_dot * alpha_dot_approx *
           aircraft_data.wing_mean_aerodynamic_chord /
           (v_body_magnitude * 2.0 + 0.001)
end

"""
    🟢_yawing_moment_coefficient_due_to_beta_dot(r, α, β, M, aircraft_data, V, cfg)

Sidewash-lag yaw damping:  ΔCn = Cn_β̇ · β̇ · b/(2V).
Uses β̇ ≈ −r (yaw rate), the quasi-static approximation (nose-right
yaw → negative sideslip rate in stability axes).
"""
function 🟢_yawing_moment_coefficient_due_to_beta_dot(
    r_yaw_rate,
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    v_body_magnitude,
    configuration
)
    cn_beta_dot = _fetch_moment_coefficient_or_default("Cn_beta_dot", 0.0,
        mach=Mach_number, alpha=rad2deg(alpha_RAD), beta=rad2deg(beta_RAD),
        config=configuration, configuration=configuration)
    beta_dot_approx = -r_yaw_rate        # quasi-static: β̇ ≈ −r
    return cn_beta_dot * beta_dot_approx *
           aircraft_data.reference_span /
           (v_body_magnitude * 2.0 + 0.001)
end

# ---- Cross-damping derivatives ----
# These capture lateral-directional coupling that drives the Dutch roll mode:
#   Cn_p: yaw moment from roll rate (induced drag asymmetry)
#   Cl_r: roll moment from yaw rate (velocity differential across span)

function 🟢_yawing_moment_coefficient_due_to_roll_rate(
    p_roll_rate,
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    v_body_magnitude,
    configuration
)
    cn_p = _fetch_moment_coefficient_or_default("Cn_p", aircraft_data.Cn_p,
        mach=Mach_number, alpha=rad2deg(alpha_RAD), beta=rad2deg(beta_RAD),
        config=configuration, configuration=configuration)
    return cn_p * p_roll_rate * aircraft_data.reference_span / (v_body_magnitude * 2.0 + 0.001)
end

function 🟢_rolling_moment_coefficient_due_to_yaw_rate(
    r_yaw_rate,
    alpha_RAD,
    beta_RAD,
    Mach_number,
    aircraft_data,
    v_body_magnitude,
    configuration
)
    cl_r = _fetch_moment_coefficient_or_default("Cl_r", aircraft_data.Cl_r,
        mach=Mach_number, alpha=rad2deg(alpha_RAD), beta=rad2deg(beta_RAD),
        config=configuration, configuration=configuration)
    return cl_r * r_yaw_rate * aircraft_data.reference_span / (v_body_magnitude * 2.0 + 0.001)
end
