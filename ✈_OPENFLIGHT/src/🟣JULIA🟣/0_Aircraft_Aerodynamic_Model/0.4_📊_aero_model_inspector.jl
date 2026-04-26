###########################################
# Aerodynamic Model Inspector
#
# Builds a JSON-serialisable payload that summarises every aerodynamic
# coefficient currently in use by the simulator — for the active model mode
# (`linear` or `table`).  The payload is consumed by the browser-side
# `aero_model_viewer.html` page, which renders it as a grid of charts so
# the user can visually assess whether the coefficients make sense and
# are consistent with the aircraft's behaviour.
#
# The payload shape is intentionally flat and simple:
#
#   {
#     "mode":          "linear" | "table",
#     "aircraft_name": <string>,
#     "reference": { S, b, c, mass, AR, Oswald },
#     "constants_groups": [
#         { "title": <string>, "rows": [ [name, value, unit], ... ] },
#         ...
#     ],
#     "plots": [
#         {
#             "title":  <string>,
#             "xlabel": <string>,
#             "ylabel": <string>,
#             "traces": [
#                 { "name": <string>, "x": [...], "y": [...] },
#                 ...
#             ]
#         },
#         ...
#     ]
#   }
###########################################

using JSON

const _AERO_INSPECTOR_ALPHA_SWEEP_DEG      = collect(-40.0:1.0:40.0)
const _AERO_INSPECTOR_BETA_SWEEP_DEG       = collect(-35.0:1.0:35.0)
const _AERO_INSPECTOR_ALPHA_SWEEP_WIDE_DEG = collect(-180.0:2.0:180.0)
const _AERO_INSPECTOR_BETA_SWEEP_WIDE_DEG  = collect(-180.0:2.0:180.0)
const _AERO_INSPECTOR_CONTROL_SWEEP        = collect(-1.0:0.05:1.0)
const _AERO_INSPECTOR_RATE_SWEEP           = collect(-2.0:0.1:2.0)  # rad/s for damping plots

# ── Helpers ───────────────────────────────────────────────────────────

function _inspector_constant(aircraft_data, name::Symbol, default_value::Float64)
    if hasproperty(aircraft_data, name)
        value = getproperty(aircraft_data, name)
        if value isa Number && isfinite(value)
            return Float64(value)
        end
    end
    return default_value
end

_finite_or_zero(v::Float64) = isfinite(v) ? v : 0.0

function _make_reference(aircraft_data)
    return Dict(
        "S"         => _inspector_constant(aircraft_data, :reference_area, 16.0),
        "b"         => _inspector_constant(aircraft_data, :reference_span, 9.0),
        "c"         => _inspector_constant(aircraft_data, :wing_mean_aerodynamic_chord, 1.8),
        "mass"      => _inspector_constant(aircraft_data, :aircraft_mass, 1600.0),
        "AR"        => _inspector_constant(aircraft_data, :AR, 5.0),
        "Oswald"    => _inspector_constant(aircraft_data, :Oswald_factor, 0.8),
        "S_tail"    => _inspector_constant(aircraft_data, :tail_reference_area, 3.0),
        "x_CoG"     => _inspector_constant(aircraft_data, :x_CoG, 0.0),
    )
end

function _scalar_row(name::String, value::Float64, unit::String="-")
    return [name, isfinite(value) ? value : 0.0, unit]
end

# ── Linear-mode payload ───────────────────────────────────────────────

function _linear_mode_payload(aircraft_data; range::String="normal")
    α_deg = range == "wide" ? _AERO_INSPECTOR_ALPHA_SWEEP_WIDE_DEG : _AERO_INSPECTOR_ALPHA_SWEEP_DEG
    β_deg = range == "wide" ? _AERO_INSPECTOR_BETA_SWEEP_WIDE_DEG  : _AERO_INSPECTOR_BETA_SWEEP_DEG
    ctrl  = _AERO_INSPECTOR_CONTROL_SWEEP
    rate  = _AERO_INSPECTOR_RATE_SWEEP

    CL_0        = _inspector_constant(aircraft_data, :CL_0,        0.20)
    CL_alpha    = _inspector_constant(aircraft_data, :CL_alpha,    5.50)
    CL_q_hat    = _inspector_constant(aircraft_data, :CL_q_hat,    4.00)
    CL_delta_e  = _inspector_constant(aircraft_data, :CL_delta_e,  0.40)
    CD_0        = _inspector_constant(aircraft_data, :CD0,         0.025)
    Oswald      = _inspector_constant(aircraft_data, :Oswald_factor, 0.80)
    AR          = _inspector_constant(aircraft_data, :AR, 5.0)
    Cm_0        = _inspector_constant(aircraft_data, :Cm0,         0.0)
    Cm_alpha    = _inspector_constant(aircraft_data, :Cm_alpha,   -1.50)
    Cm_q        = _inspector_constant(aircraft_data, :Cm_q,      -18.0)
    Cm_delta_e  = _inspector_constant(aircraft_data, :Cm_delta_e, -1.50)
    CY_beta     = _inspector_constant(aircraft_data, :CY_beta,    -0.50)
    CY_delta_r  = _inspector_constant(aircraft_data, :CY_delta_r,  0.15)
    Cl_beta     = _inspector_constant(aircraft_data, :Cl_beta,    -0.10)
    Cl_p        = _inspector_constant(aircraft_data, :Cl_p,       -0.50)
    Cl_r        = _inspector_constant(aircraft_data, :Cl_r,        0.10)
    Cl_delta_a  = _inspector_constant(aircraft_data, :Cl_delta_a,  0.20)
    Cl_delta_r  = _inspector_constant(aircraft_data, :Cl_delta_r,  0.0)
    Cn_beta     = _inspector_constant(aircraft_data, :Cn_beta,     0.12)
    Cn_p        = _inspector_constant(aircraft_data, :Cn_p,       -0.05)
    Cn_r        = _inspector_constant(aircraft_data, :Cn_r,       -0.20)
    Cn_delta_a  = _inspector_constant(aircraft_data, :Cn_delta_a,  0.0)
    Cn_delta_r  = _inspector_constant(aircraft_data, :Cn_delta_r,  0.10)

    alpha_stall_pos = _inspector_constant(aircraft_data, :alpha_stall_positive,  15.0)
    alpha_stall_neg = _inspector_constant(aircraft_data, :alpha_stall_negative, -15.0)
    beta_stall_deg  = _inspector_constant(aircraft_data, :beta_stall, 20.0)
    alpha_knee_deg  = _inspector_constant(aircraft_data, :alpha_stall_knee_deg, 3.0)
    beta_knee_deg   = _inspector_constant(aircraft_data, :beta_stall_knee_deg,  5.0)

    induced_drag_factor = max(pi * AR * Oswald, 1.0e-6)

    # Soft-saturated α and β, matching the runtime formula exactly so the
    # plots show the curves the simulator actually consumes.
    α_deg_sat = [
        rad2deg(_soft_saturate(
            deg2rad(a),
            deg2rad(alpha_stall_neg),
            deg2rad(alpha_stall_pos),
            deg2rad(alpha_knee_deg),
        )) for a in α_deg
    ]
    β_deg_sat = [
        rad2deg(_soft_saturate(
            deg2rad(b),
            -deg2rad(abs(beta_stall_deg)),
             deg2rad(abs(beta_stall_deg)),
            deg2rad(beta_knee_deg),
        )) for b in β_deg
    ]

    # --- Pre-stall (linear, saturated) traces ---
    # Use α_sat so the plot shows the actual capped curve the simulator feeds
    # into its force/moment accumulator.
    CL_linear = [CL_0 + CL_alpha * deg2rad(α_deg_sat[i])                           for i in eachindex(α_deg)]
    CD_linear = [CD_0 + (CL_0 + CL_alpha * deg2rad(α_deg_sat[i]))^2 / induced_drag_factor for i in eachindex(α_deg)]
    Cm_linear = [Cm_0 + Cm_alpha * deg2rad(α_deg_sat[i])                           for i in eachindex(α_deg)]

    # --- Post-stall (flat-plate + restoring Cm) traces ---
    CL_POST_SCALE = 1.10
    CD_POST_FLOOR = 0.05
    CD_POST_PEAK  = 1.60
    CM_POST_SCALE = 0.12

    CL_post = [CL_POST_SCALE * sin(2.0 * deg2rad(a))                 for a in α_deg]
    CD_post = [CD_POST_FLOOR + (CD_POST_PEAK - CD_POST_FLOOR) * sin(deg2rad(a))^2 for a in α_deg]
    Cm_post = [-CM_POST_SCALE * sin(2.0 * deg2rad(a))                for a in α_deg]

    # --- Blended traces (pre→post-stall using the same smoothstep the sim uses) ---
    function stall_blend(a_deg)
        if a_deg >= 0.0
            t = (a_deg - max(alpha_stall_pos, 1.0)) / 10.0
        else
            t = (-a_deg - max(-alpha_stall_neg, 1.0)) / 10.0
        end
        t = clamp(t, 0.0, 1.0)
        return t * t * (3.0 - 2.0 * t)
    end

    blend = [stall_blend(a) for a in α_deg]
    CL_blend = [(1 - blend[i]) * CL_linear[i] + blend[i] * CL_post[i] for i in eachindex(α_deg)]
    CD_blend = [(1 - blend[i]) * CD_linear[i] + blend[i] * CD_post[i] for i in eachindex(α_deg)]
    Cm_blend = [(1 - blend[i]) * Cm_linear[i] + blend[i] * Cm_post[i] for i in eachindex(α_deg)]

    # --- Lateral-directional traces vs β (saturated) ---
    CY_beta_trace = [CY_beta * deg2rad(β_deg_sat[i]) for i in eachindex(β_deg)]
    Cl_beta_trace = [Cl_beta * deg2rad(β_deg_sat[i]) for i in eachindex(β_deg)]
    Cn_beta_trace = [Cn_beta * deg2rad(β_deg_sat[i]) for i in eachindex(β_deg)]

    # --- Control-effectiveness traces ---
    max_da = _inspector_constant(aircraft_data, :max_aileron_deflection_deg, 25.0)
    max_de = _inspector_constant(aircraft_data, :max_elevator_deflection_deg, 25.0)
    max_dr = _inspector_constant(aircraft_data, :max_rudder_deflection_deg,   30.0)

    # The control-surface plots use the PHYSICAL deflection on the x-axis —
    # the aerodynamic convention (δe > 0 = trailing-edge DOWN, nose-down
    # command) — so the trace slope directly shows `Cl_delta_a`, `Cm_delta_e`,
    # `Cn_delta_r` as they are defined in the linear model.  The pilot-stick
    # command maps to δe via `δe = -pitch_demand × max_de` (hence the minus
    # on the elevator x-axis), and to δa/δr via `δa = roll_demand × max_da`
    # and `δr = yaw_demand × max_dr` (no flip).
    da_deg_axis = [c * max_da for c in ctrl]
    de_deg_axis = [-c * max_de for c in ctrl]   # physical δe: stick back → -25° TE up
    dr_deg_axis = [c * max_dr for c in ctrl]

    Cl_da_trace = [Cl_delta_a * deg2rad(d) for d in da_deg_axis]
    Cm_de_trace = [Cm_delta_e * deg2rad(d) for d in de_deg_axis]
    Cn_dr_trace = [Cn_delta_r * deg2rad(d) for d in dr_deg_axis]

    # --- Damping traces: ΔC vs body rate ---
    ref_b = _inspector_constant(aircraft_data, :reference_span, 9.0)
    ref_c = _inspector_constant(aircraft_data, :wing_mean_aerodynamic_chord, 1.8)
    V_ref = 70.0   # representative cruise speed for the non-dim rate hat-form

    Cl_p_trace = [Cl_p * (p * ref_b / (2.0 * V_ref)) for p in rate]
    Cm_q_trace = [Cm_q * (q * ref_c / (2.0 * V_ref)) for q in rate]
    Cn_r_trace = [Cn_r * (r * ref_b / (2.0 * V_ref)) for r in rate]

    # --- Constants groups ---
    constants_groups = Vector{Any}()
    push!(constants_groups, Dict(
        "title" => "Longitudinal",
        "rows"  => [
            _scalar_row("CL_0",       CL_0,       "-"),
            _scalar_row("CL_alpha",   CL_alpha,   "/rad"),
            _scalar_row("CL_q_hat",   CL_q_hat,   "-"),
            _scalar_row("CL_delta_e", CL_delta_e, "/rad"),
            _scalar_row("CD_0",       CD_0,       "-"),
            _scalar_row("AR",         AR,         "-"),
            _scalar_row("Oswald",     Oswald,     "-"),
            _scalar_row("Cm_0",       Cm_0,       "-"),
            _scalar_row("Cm_alpha",   Cm_alpha,   "/rad"),
            _scalar_row("Cm_q",       Cm_q,       "-"),
            _scalar_row("Cm_delta_e", Cm_delta_e, "/rad"),
        ],
    ))
    push!(constants_groups, Dict(
        "title" => "Lateral-Directional",
        "rows"  => [
            _scalar_row("CY_beta",    CY_beta,    "/rad"),
            _scalar_row("CY_delta_r", CY_delta_r, "/rad"),
            _scalar_row("Cl_beta",    Cl_beta,    "/rad"),
            _scalar_row("Cl_p",       Cl_p,       "-"),
            _scalar_row("Cl_r",       Cl_r,       "-"),
            _scalar_row("Cl_delta_a", Cl_delta_a, "/rad"),
            _scalar_row("Cl_delta_r", Cl_delta_r, "/rad"),
            _scalar_row("Cn_beta",    Cn_beta,    "/rad"),
            _scalar_row("Cn_p",       Cn_p,       "-"),
            _scalar_row("Cn_r",       Cn_r,       "-"),
            _scalar_row("Cn_delta_a", Cn_delta_a, "/rad"),
            _scalar_row("Cn_delta_r", Cn_delta_r, "/rad"),
        ],
    ))
    push!(constants_groups, Dict(
        "title" => "Stall limits",
        "rows"  => [
            _scalar_row("α_stall_positive",     alpha_stall_pos,  "deg"),
            _scalar_row("α_stall_negative",     alpha_stall_neg,  "deg"),
            _scalar_row("β_stall (± symmetric)", beta_stall_deg,  "deg"),
            _scalar_row("α saturation knee",     alpha_knee_deg,  "deg"),
            _scalar_row("β saturation knee",     beta_knee_deg,   "deg"),
        ],
    ))

    # --- Plot definitions ---
    plots = Vector{Any}()
    push!(plots, Dict(
        "title"  => "Saturation map α_sat vs α",
        "xlabel" => "α (deg)",
        "ylabel" => "α_sat (deg)",
        "traces" => [
            Dict("name" => "α_sat (soft-clipped)", "x" => α_deg, "y" => α_deg_sat),
            Dict("name" => "identity reference",   "x" => α_deg, "y" => α_deg),
        ],
    ))
    push!(plots, Dict(
        "title"  => "Saturation map β_sat vs β",
        "xlabel" => "β (deg)",
        "ylabel" => "β_sat (deg)",
        "traces" => [
            Dict("name" => "β_sat (soft-clipped)", "x" => β_deg, "y" => β_deg_sat),
            Dict("name" => "identity reference",   "x" => β_deg, "y" => β_deg),
        ],
    ))
    push!(plots, Dict(
        "title"  => "CL vs α (β=0, stick centred)",
        "xlabel" => "α (deg)",
        "ylabel" => "CL",
        "traces" => [
            Dict("name" => "Linear (α_sat-clipped)", "x" => α_deg, "y" => CL_linear),
            Dict("name" => "Post-stall",             "x" => α_deg, "y" => CL_post),
            Dict("name" => "Blended (active)",       "x" => α_deg, "y" => CL_blend),
        ],
    ))
    push!(plots, Dict(
        "title"  => "CD vs α (β=0, stick centred)",
        "xlabel" => "α (deg)",
        "ylabel" => "CD",
        "traces" => [
            Dict("name" => "Parabolic (α_sat-clipped)", "x" => α_deg, "y" => CD_linear),
            Dict("name" => "Post-stall",                "x" => α_deg, "y" => CD_post),
            Dict("name" => "Blended (active)",          "x" => α_deg, "y" => CD_blend),
        ],
    ))
    push!(plots, Dict(
        "title"  => "Cm vs α (β=0, stick centred)",
        "xlabel" => "α (deg)",
        "ylabel" => "Cm",
        "traces" => [
            Dict("name" => "Linear (α_sat-clipped)", "x" => α_deg, "y" => Cm_linear),
            Dict("name" => "Post-stall restore",     "x" => α_deg, "y" => Cm_post),
            Dict("name" => "Blended (active)",       "x" => α_deg, "y" => Cm_blend),
        ],
    ))
    push!(plots, Dict(
        "title"  => "CL / CD vs α",
        "xlabel" => "α (deg)",
        "ylabel" => "CL/CD",
        "traces" => [
            Dict(
                "name" => "L/D (blended)",
                "x"    => α_deg,
                "y"    => [abs(CD_blend[i]) > 1e-6 ? CL_blend[i] / CD_blend[i] : 0.0 for i in eachindex(α_deg)],
            ),
        ],
    ))

    push!(plots, Dict(
        "title"  => "Side force CY vs β  (soft-clipped at ±β_stall)",
        "xlabel" => "β (deg)",
        "ylabel" => "CY",
        "traces" => [Dict("name" => "CY_beta × β_sat", "x" => β_deg, "y" => CY_beta_trace)],
    ))
    push!(plots, Dict(
        "title"  => "Rolling moment Cl vs β  (soft-clipped at ±β_stall)",
        "xlabel" => "β (deg)",
        "ylabel" => "Cl",
        "traces" => [Dict("name" => "Cl_beta × β_sat (dihedral)", "x" => β_deg, "y" => Cl_beta_trace)],
    ))
    push!(plots, Dict(
        "title"  => "Yawing moment Cn vs β  (soft-clipped at ±β_stall)",
        "xlabel" => "β (deg)",
        "ylabel" => "Cn",
        "traces" => [Dict("name" => "Cn_beta × β_sat (weathercock)", "x" => β_deg, "y" => Cn_beta_trace)],
    ))

    push!(plots, Dict(
        "title"  => "Aileron effectiveness ΔCl vs δa",
        "xlabel" => "δa (deg)",
        "ylabel" => "ΔCl",
        "traces" => [Dict("name" => "Cl_delta_a × δa", "x" => da_deg_axis, "y" => Cl_da_trace)],
    ))
    push!(plots, Dict(
        "title"  => "Elevator effectiveness ΔCm vs δe  (δe > 0 = TE down = nose-down command)",
        "xlabel" => "δe (deg)",
        "ylabel" => "ΔCm",
        "traces" => [Dict("name" => "Cm_delta_e × δe  (stable: negative slope)", "x" => de_deg_axis, "y" => Cm_de_trace)],
    ))
    push!(plots, Dict(
        "title"  => "Rudder effectiveness ΔCn vs δr",
        "xlabel" => "δr (deg)",
        "ylabel" => "ΔCn",
        "traces" => [Dict("name" => "Cn_delta_r × δr", "x" => dr_deg_axis, "y" => Cn_dr_trace)],
    ))

    push!(plots, Dict(
        "title"  => "Roll damping ΔCl vs p  (at V_ref = $(V_ref) m/s)",
        "xlabel" => "p (rad/s)",
        "ylabel" => "ΔCl",
        "traces" => [Dict("name" => "Cl_p × p_hat", "x" => rate, "y" => Cl_p_trace)],
    ))
    push!(plots, Dict(
        "title"  => "Pitch damping ΔCm vs q  (at V_ref = $(V_ref) m/s)",
        "xlabel" => "q (rad/s)",
        "ylabel" => "ΔCm",
        "traces" => [Dict("name" => "Cm_q × q_hat", "x" => rate, "y" => Cm_q_trace)],
    ))
    push!(plots, Dict(
        "title"  => "Yaw damping ΔCn vs r  (at V_ref = $(V_ref) m/s)",
        "xlabel" => "r (rad/s)",
        "ylabel" => "ΔCn",
        "traces" => [Dict("name" => "Cn_r × r_hat", "x" => rate, "y" => Cn_r_trace)],
    ))

    return constants_groups, plots
end

# ── Table-mode payload ────────────────────────────────────────────────

function _table_has_numeric_axis(meta::CoefficientMetadata, param::String)
    return haskey(meta.parameter_kinds, param) && meta.parameter_kinds[param] == :numeric
end

function _table_axis_values_deg(meta::CoefficientMetadata, canonical::String)
    # Returns the sorted numeric axis for the given canonical parameter name
    # (already-normalised: "alpha", "beta", "mach", …), or an empty vector if
    # the coefficient doesn't use that axis.
    if !haskey(meta.parameter_lookup, canonical)
        return Float64[]
    end
    param = meta.parameter_lookup[canonical]
    if meta.parameter_kinds[param] != :numeric
        return Float64[]
    end
    return copy(meta.sorted_data[param].values)
end

function _safe_lookup(coeff_name::String, default_value::Float64; kwargs...)
    try
        return _fetch_coefficient_with_default(coeff_name, default_value; kwargs...)
    catch
        return default_value
    end
end

function _sweep_coefficient_vs_alpha(coeff_name::String, alpha_deg_axis::Vector{Float64};
                                     beta_deg::Float64=0.0, mach::Float64=0.2,
                                     configuration::String="clean")
    return [
        _safe_lookup(coeff_name, 0.0;
            alpha = a, alpha_deg = a,
            beta  = beta_deg, beta_deg = beta_deg,
            mach  = mach, Mach = mach,
            config = configuration, configuration = configuration,
        )
        for a in alpha_deg_axis
    ]
end

function _sweep_coefficient_vs_beta(coeff_name::String, beta_deg_axis::Vector{Float64};
                                    alpha_deg::Float64=0.0, mach::Float64=0.2,
                                    configuration::String="clean")
    return [
        _safe_lookup(coeff_name, 0.0;
            alpha = alpha_deg, alpha_deg = alpha_deg,
            beta  = b, beta_deg = b,
            mach  = mach, Mach = mach,
            config = configuration, configuration = configuration,
        )
        for b in beta_deg_axis
    ]
end

function _table_alpha_axis(default_axis::Vector{Float64})
    coeff_names = ("CL", "Cm", "CD", "Cl", "Cn", "CY", "CS")
    for name in coeff_names
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, name)
            resolved = _resolve_coefficient_name(aircraft_aero_and_propulsive_database, name)
            meta = aircraft_aero_and_propulsive_database.metadata[resolved]
            axis = _table_axis_values_deg(meta, "alpha")
            if !isempty(axis)
                return [a for a in axis if -30.0 <= a <= 30.0]
            end
        end
    end
    return default_axis
end

function _table_beta_axis(default_axis::Vector{Float64})
    for name in ("CY", "CS", "Cl", "Cn")
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, name)
            resolved = _resolve_coefficient_name(aircraft_aero_and_propulsive_database, name)
            meta = aircraft_aero_and_propulsive_database.metadata[resolved]
            axis = _table_axis_values_deg(meta, "beta")
            if !isempty(axis)
                return [b for b in axis if -20.0 <= b <= 20.0]
            end
        end
    end
    return default_axis
end

function _table_mode_payload(aircraft_data; range::String="normal")
    current_config = string(get(aircraft_data, :default_configuration, "clean"))

    default_α = range == "wide" ? _AERO_INSPECTOR_ALPHA_SWEEP_WIDE_DEG : _AERO_INSPECTOR_ALPHA_SWEEP_DEG
    default_β = range == "wide" ? _AERO_INSPECTOR_BETA_SWEEP_WIDE_DEG  : _AERO_INSPECTOR_BETA_SWEEP_DEG

    α_axis = range == "wide" ? default_α : _table_alpha_axis(default_α)
    β_axis = range == "wide" ? default_β : _table_beta_axis(default_β)

    if isempty(α_axis); α_axis = default_α; end
    if isempty(β_axis); β_axis = default_β; end

    # Coefficients swept over α (at β=0, mach=0.2, current config).
    # When v3 split tables are loaded we overlay wing_body + per-tail traces
    # on top of the total curve for visual attribution.
    longitudinal_plots = Vector{Any}()
    tail_surfaces_meta = get(aircraft_data, :tail_surfaces, NamedTuple[])

    for (coeff_name, plot_title, ylabel) in (
        ("CL", "CL vs α  (table)", "CL"),
        ("CD", "CD vs α  (table)", "CD"),
        ("Cm", "Cm vs α  (table)", "Cm"),
    )
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, coeff_name)
            traces = Vector{Any}()
            y_total = _sweep_coefficient_vs_alpha(coeff_name, α_axis; configuration=current_config)
            push!(traces, Dict("name" => "$(coeff_name) total", "x" => α_axis, "y" => y_total))

            wb_key = "wb_" * coeff_name
            if has_aero_coefficient(aircraft_aero_and_propulsive_database, wb_key)
                y_wb = _sweep_coefficient_vs_alpha(wb_key, α_axis; configuration=current_config)
                push!(traces, Dict("name" => "wing+body", "x" => α_axis, "y" => y_wb))
            end
            for ts in tail_surfaces_meta
                # Tail tables use local angles — for overlay purposes we plot
                # them against aircraft α with no ε correction, giving the user
                # a "tail contribution at zero-downwash" reference curve.
                t_key = "tail_" * ts.name * "_" * (coeff_name == "Cm" ? "Cm_at_AC" :
                                                    coeff_name == "Cl" ? "Cl_at_AC" :
                                                    coeff_name == "Cn" ? "Cn_at_AC" : coeff_name)
                if has_aero_coefficient(aircraft_aero_and_propulsive_database, t_key)
                    y_t = _sweep_coefficient_vs_alpha(t_key, α_axis; configuration=current_config)
                    push!(traces, Dict("name" => "tail: $(ts.name)", "x" => α_axis, "y" => y_t))
                end
            end
            push!(longitudinal_plots, Dict(
                "title"  => plot_title,
                "xlabel" => "α (deg)",
                "ylabel" => ylabel,
                "traces" => traces,
            ))
        end
    end

    lateral_plots = Vector{Any}()
    for (coeff_name, plot_title, ylabel) in (
        ("CY", "CY vs β  (table)", "CY"),
        ("CS", "CS vs β  (table)", "CS"),
        ("Cl", "Cl vs β  (table)", "Cl"),
        ("Cn", "Cn vs β  (table)", "Cn"),
    )
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, coeff_name)
            traces = Vector{Any}()
            y_total = _sweep_coefficient_vs_beta(coeff_name, β_axis; configuration=current_config)
            push!(traces, Dict("name" => "$(coeff_name) total", "x" => β_axis, "y" => y_total))

            wb_key = "wb_" * coeff_name
            if has_aero_coefficient(aircraft_aero_and_propulsive_database, wb_key)
                y_wb = _sweep_coefficient_vs_beta(wb_key, β_axis; configuration=current_config)
                push!(traces, Dict("name" => "wing+body", "x" => β_axis, "y" => y_wb))
            end
            for ts in tail_surfaces_meta
                t_key = "tail_" * ts.name * "_" * (coeff_name == "Cm" ? "Cm_at_AC" :
                                                    coeff_name == "Cl" ? "Cl_at_AC" :
                                                    coeff_name == "Cn" ? "Cn_at_AC" : coeff_name)
                if has_aero_coefficient(aircraft_aero_and_propulsive_database, t_key)
                    y_t = _sweep_coefficient_vs_beta(t_key, β_axis; configuration=current_config)
                    push!(traces, Dict("name" => "tail: $(ts.name)", "x" => β_axis, "y" => y_t))
                end
            end
            push!(lateral_plots, Dict(
                "title"  => plot_title,
                "xlabel" => "β (deg)",
                "ylabel" => ylabel,
                "traces" => traces,
            ))
        end
    end

    # ── Interference plots (schema v3.0) ──
    interference_plots = Vector{Any}()
    for (key, title, ylabel, xlabel, axis) in (
        ("interference_downwash_deg", "Downwash ε vs α  (interference)", "ε (deg)", "α (deg)", α_axis),
        ("interference_eta_h",        "η_h (tail q-ratio) vs α",          "η_h",     "α (deg)", α_axis),
    )
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, key)
            y = _sweep_coefficient_vs_alpha(key, axis; configuration=current_config)
            push!(interference_plots, Dict(
                "title"  => title,
                "xlabel" => xlabel,
                "ylabel" => ylabel,
                "traces" => [Dict("name" => key, "x" => axis, "y" => y)],
            ))
        end
    end
    for (key, title, ylabel, xlabel, axis) in (
        ("interference_sidewash_deg", "Sidewash σ vs β  (interference)", "σ (deg)", "β (deg)", β_axis),
        ("interference_eta_v",        "η_v (fin q-ratio) vs β",          "η_v",     "β (deg)", β_axis),
    )
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, key)
            y = _sweep_coefficient_vs_beta(key, axis; configuration=current_config)
            push!(interference_plots, Dict(
                "title"  => title,
                "xlabel" => xlabel,
                "ylabel" => ylabel,
                "traces" => [Dict("name" => key, "x" => axis, "y" => y)],
            ))
        end
    end

    # Dynamic derivatives vs α
    dynamic_plots = Vector{Any}()
    for (coeff_name, plot_title, ylabel) in (
        ("Cl_p_hat", "Cl_p vs α  (table)", "Cl_p_hat"),
        ("Cm_q_hat", "Cm_q vs α  (table)", "Cm_q_hat"),
        ("Cn_r_hat", "Cn_r vs α  (table)", "Cn_r_hat"),
        ("Cn_p_hat", "Cn_p vs α  (table)", "Cn_p_hat"),
        ("Cl_r_hat", "Cl_r vs α  (table)", "Cl_r_hat"),
    )
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, coeff_name)
            y = _sweep_coefficient_vs_alpha(coeff_name, α_axis; configuration=current_config)
            push!(dynamic_plots, Dict(
                "title"  => plot_title,
                "xlabel" => "α (deg)",
                "ylabel" => ylabel,
                "traces" => [Dict("name" => "$(coeff_name) ($(current_config))",
                                  "x" => α_axis, "y" => y)],
            ))
        end
    end

    # Control effectiveness vs α
    control_plots = Vector{Any}()
    for (coeff_name, plot_title, ylabel) in (
        ("Cl_da_per_deg", "Cl_δa vs α  (table)", "Cl_δa /deg"),
        ("Cm_de_per_deg", "Cm_δe vs α  (table)", "Cm_δe /deg"),
        ("Cn_dr_per_deg", "Cn_δr vs α  (table)", "Cn_δr /deg"),
        ("Cn_da_per_deg", "Cn_δa vs α  (table)", "Cn_δa /deg"),
        ("Cl_dr_per_deg", "Cl_δr vs α  (table)", "Cl_δr /deg"),
    )
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, coeff_name)
            y = _sweep_coefficient_vs_alpha(coeff_name, α_axis; configuration=current_config)
            push!(control_plots, Dict(
                "title"  => plot_title,
                "xlabel" => "α (deg)",
                "ylabel" => ylabel,
                "traces" => [Dict("name" => "$(coeff_name) ($(current_config))",
                                  "x" => α_axis, "y" => y)],
            ))
        end
    end

    # ── Rate-swept damping plots (moment contribution vs body rate) ──
    # Evaluate each non-dim damping derivative at α≈0 (trim/cruise) and show
    # the resulting moment contribution as the rate sweeps through its plot
    # range. Mirrors the linear-mode damping view so the two modes are
    # visually comparable.
    damping_rate_plots = Vector{Any}()
    V_ref  = 70.0
    b_ref  = _inspector_constant(aircraft_data, :reference_span, 9.0)
    c_ref  = _inspector_constant(aircraft_data, :wing_mean_aerodynamic_chord, 1.8)
    α_trim = 0.0

    # Look up each damping coefficient at α=trim, β=0, mach=0.2, current config.
    # Falls back to a small safe default if the table is missing.
    function _scalar_deriv(name::String, fallback::Float64)
        if has_aero_coefficient(aircraft_aero_and_propulsive_database, name)
            return _safe_lookup(name, fallback;
                alpha=α_trim, alpha_deg=α_trim,
                beta=0.0, beta_deg=0.0,
                mach=0.2, Mach=0.2,
                config=current_config, configuration=current_config)
        end
        return fallback
    end

    Cl_p_0 = _scalar_deriv("Cl_p_hat", -0.50)
    Cm_q_0 = _scalar_deriv("Cm_q_hat", -18.0)
    Cn_r_0 = _scalar_deriv("Cn_r_hat", -0.20)
    Cn_p_0 = _scalar_deriv("Cn_p_hat", -0.05)
    Cl_r_0 = _scalar_deriv("Cl_r_hat",  0.10)
    CL_q_0 = _scalar_deriv("CL_q_hat",  4.00)
    CY_p_0 = _scalar_deriv("CY_p_hat",  0.00)
    CY_r_0 = _scalar_deriv("CY_r_hat",  0.15)

    rate_sweep = _AERO_INSPECTOR_RATE_SWEEP

    Cl_from_p = [Cl_p_0 * (p * b_ref / (2.0 * V_ref)) for p in rate_sweep]
    Cm_from_q = [Cm_q_0 * (q * c_ref / (2.0 * V_ref)) for q in rate_sweep]
    Cn_from_r = [Cn_r_0 * (r * b_ref / (2.0 * V_ref)) for r in rate_sweep]
    Cn_from_p = [Cn_p_0 * (p * b_ref / (2.0 * V_ref)) for p in rate_sweep]
    Cl_from_r = [Cl_r_0 * (r * b_ref / (2.0 * V_ref)) for r in rate_sweep]
    CL_from_q = [CL_q_0 * (q * c_ref / (2.0 * V_ref)) for q in rate_sweep]
    CY_from_p = [CY_p_0 * (p * b_ref / (2.0 * V_ref)) for p in rate_sweep]
    CY_from_r = [CY_r_0 * (r * b_ref / (2.0 * V_ref)) for r in rate_sweep]

    for (title, xlabel, ylabel, trace_name, ys, rate) in (
        ("Roll damping ΔCl vs p  (table, α=0, V=$(V_ref) m/s)",
         "p (rad/s)", "ΔCl", "Cl_p × p_hat", Cl_from_p, rate_sweep),
        ("Pitch damping ΔCm vs q  (table, α=0, V=$(V_ref) m/s)",
         "q (rad/s)", "ΔCm", "Cm_q × q_hat", Cm_from_q, rate_sweep),
        ("Yaw damping ΔCn vs r  (table, α=0, V=$(V_ref) m/s)",
         "r (rad/s)", "ΔCn", "Cn_r × r_hat", Cn_from_r, rate_sweep),
        ("Yaw-from-roll-rate ΔCn vs p  (table, α=0, V=$(V_ref) m/s)",
         "p (rad/s)", "ΔCn", "Cn_p × p_hat", Cn_from_p, rate_sweep),
        ("Roll-from-yaw-rate ΔCl vs r  (table, α=0, V=$(V_ref) m/s)",
         "r (rad/s)", "ΔCl", "Cl_r × r_hat", Cl_from_r, rate_sweep),
        ("Lift from pitch rate ΔCL vs q  (table, α=0, V=$(V_ref) m/s)",
         "q (rad/s)", "ΔCL", "CL_q × q_hat", CL_from_q, rate_sweep),
        ("Side-force from roll rate ΔCY vs p  (table, α=0, V=$(V_ref) m/s)",
         "p (rad/s)", "ΔCY", "CY_p × p_hat", CY_from_p, rate_sweep),
        ("Side-force from yaw rate ΔCY vs r  (table, α=0, V=$(V_ref) m/s)",
         "r (rad/s)", "ΔCY", "CY_r × r_hat", CY_from_r, rate_sweep),
    )
        push!(damping_rate_plots, Dict(
            "title"  => title,
            "xlabel" => xlabel,
            "ylabel" => ylabel,
            "traces" => [Dict("name" => trace_name, "x" => collect(rate), "y" => ys)],
        ))
    end

    plots = vcat(longitudinal_plots, lateral_plots, interference_plots,
                 dynamic_plots, control_plots, damping_rate_plots)

    # Scalar constants group (pulled from aircraft_data)
    function _row(name::String, symbol::Symbol, unit::String, default::Float64=0.0)
        return _scalar_row(name, _inspector_constant(aircraft_data, symbol, default), unit)
    end

    constants_groups = Vector{Any}([
        Dict(
            "title" => "Reference geometry",
            "rows"  => [
                _row("Wing area S",           :reference_area,              "m²"),
                _row("Span b",                :reference_span,              "m"),
                _row("MAC c",                 :wing_mean_aerodynamic_chord, "m"),
                _row("Aspect ratio AR",       :AR,                          "-"),
                _row("Oswald factor",         :Oswald_factor,               "-"),
                _row("Mass",                  :aircraft_mass,               "kg"),
                _row("CoG x",                 :x_CoG,                       "m"),
                _row("Wing AC x",             :x_wing_aerodynamic_center,   "m"),
                _row("Tail ref area",         :tail_reference_area,         "m²"),
            ],
        ),
        Dict(
            "title" => "Control limits",
            "rows"  => [
                _row("Max aileron",           :max_aileron_deflection_deg,  "deg"),
                _row("Max elevator",          :max_elevator_deflection_deg, "deg"),
                _row("Max rudder",            :max_rudder_deflection_deg,   "deg"),
            ],
        ),
        Dict(
            "title" => "Stall / post-stall",
            "rows"  => [
                _row("α stall positive",      :alpha_stall_positive, "deg"),
                _row("α stall negative",      :alpha_stall_negative, "deg"),
                _row("CL max",                :CL_max,               "-"),
                _row("CD0 (scalar)",          :CD0,                  "-"),
                _row("Post-stall CL scale",   :poststall_cl_scale,   "-"),
                _row("Post-stall CD_90",      :poststall_cd90,       "-"),
            ],
        ),
    ])

    return constants_groups, plots
end

# ── Top-level payload builder ─────────────────────────────────────────

"""
    build_aero_inspector_payload(aircraft_data) -> Dict

Assemble the full JSON-serialisable payload describing every aerodynamic
coefficient currently in use by the simulator, routed to the
appropriate builder based on `aircraft_data.aerodynamic_model_mode`.
"""
function build_aero_inspector_payload(aircraft_data; range::String="normal")
    mode = lowercase(string(get(aircraft_data, :aerodynamic_model_mode, "table")))
    mode_resolved = mode == "linear" ? "linear" : "table"

    aircraft_name = "unknown"
    try
        if @isdefined(MISSION_DATA) && haskey(MISSION_DATA, "aircraft_name")
            aircraft_name = string(MISSION_DATA["aircraft_name"])
        end
    catch
    end

    constants_groups, plots = if mode_resolved == "linear"
        _linear_mode_payload(aircraft_data; range=range)
    else
        _table_mode_payload(aircraft_data; range=range)
    end

    return Dict(
        "mode"             => mode_resolved,
        "aircraft_name"    => aircraft_name,
        "reference"        => _make_reference(aircraft_data),
        "constants_groups" => constants_groups,
        "plots"            => plots,
        "range"            => range,
    )
end

"""
    aero_inspector_json_response() -> HTTP.Response

Serialise the payload to JSON and wrap it in an HTTP 200 response ready to
be returned by `serve_static`.
"""
function aero_inspector_json_response(; range::String="normal")
    try
        payload = build_aero_inspector_payload(aircraft_flight_physics_and_propulsive_data; range=range)
        body = JSON.json(payload)
        headers = ["Content-Type" => "application/json; charset=utf-8",
                   "Cache-Control" => "no-cache"]
        return HTTP.Response(200, headers, body)
    catch e
        err_body = JSON.json(Dict("error" => string(e)))
        headers = ["Content-Type" => "application/json; charset=utf-8"]
        return HTTP.Response(500, headers, err_body)
    end
end
