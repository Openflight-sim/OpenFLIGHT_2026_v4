"""
    AeroModel.jl — Unified Aerodynamic Model Generation Framework

Orchestrates VortexLattice.jl, JAVL (Julia AVL), and JDATCOM backends
to produce dense lookup tables for flight simulator aerodynamic models.
"""
module AeroModel

using JSON
using Dates
using LinearAlgebra
using Printf

# Submodules
include("input.jl")
include("component_split.jl")
include("stall_estimation.jl")
include("vlm_backend.jl")
include("javl_backend.jl")
include("datcom_backend.jl")
include("merge.jl")
include("full_envelope.jl")
include("validation.jl")
include("output.jl")
include("server.jl")

export run_analysis, start_server, start_server_async, AircraftInput

function strip_derived_aero_inputs(aircraft_json::AbstractDict)
    sanitized = deepcopy(Dict{String,Any}(string(k) => v for (k, v) in pairs(aircraft_json)))

    for key in ("stall_parameters", "dynamic_stall", "tail_properties")
        if haskey(sanitized, key)
            delete!(sanitized, key)
        end
    end

    general = get(sanitized, "general", nothing)
    if general isa AbstractDict
        for key in ("Oswald_factor", "sideslip_drag_K", "scale_tail_forces")
            if haskey(general, key)
                delete!(general, key)
            end
        end
    end

    surfaces = get(sanitized, "lifting_surfaces", nothing)
    if surfaces isa AbstractVector
        for surf in surfaces
            if surf isa AbstractDict
                for key in ("Oswald_factor", "aerodynamic_center_pos_xyz_m")
                    if haskey(surf, key)
                        delete!(surf, key)
                    end
                end
            end
        end
    end

    return sanitized
end

const MIN_AUTO_STATIC_MARGIN = 0.12
const TARGET_AUTO_STATIC_MARGIN = 0.14
const MAX_AUTO_STATIC_MARGIN = 0.30
# Allow up to 4 CG-shift iterations. A single pass leaves the static margin
# off-target by a few percent because VLM's effective neutral point shifts
# slightly when the CG is moved (downwash on tail, mesh discretisation,
# moment-reference change). Iterating until |Δstatic_margin| ≤ 1% MAC keeps
# the generated linear scalars (Cm_α, Cn_β) in physical proportion to the
# control derivatives (Cm_δe, Cn_δr), so the simulator does not see a
# tail with strong control authority but feeble static stiffness.
const MAX_CG_ADJUSTMENT_PASSES = 4
const CG_ADJUSTMENT_TOLERANCE_MAC = 0.01

function _finite_float(value, default=NaN)
    try
        v = Float64(value)
        return isfinite(v) ? v : default
    catch
        return default
    end
end

function _maybe_adjust_cg_for_static_margin(model::Dict,
                                            input::AircraftInput,
                                            sanitized_json::Dict{String,Any},
                                            cg_adjustment_pass::Int)
    cg_adjustment_pass >= MAX_CG_ADJUSTMENT_PASSES && return nothing

    runtime = get(model, "runtime_model", Dict())
    CL_alpha = _finite_float(get(runtime, "CL_alpha", NaN))
    Cm_alpha = _finite_float(get(runtime, "Cm_alpha", NaN))
    CL0 = _finite_float(get(runtime, "CL_0", NaN))
    Cm0 = _finite_float(get(runtime, "Cm0", NaN))
    if !isfinite(CL_alpha) || abs(CL_alpha) < 1e-6 || !isfinite(Cm_alpha)
        return nothing
    end

    static_margin = -Cm_alpha / CL_alpha

    cref = max(input.general.cref, 1e-6)
    x_cg = input.general.CoG[1]
    x_np = x_cg + static_margin * cref
    target_x_cg = x_cg
    reason = "static_margin"
    direction = "none"

    trim_alpha_deg = if isfinite(Cm0) && abs(Cm_alpha) > 1e-6
        rad2deg(-Cm0 / Cm_alpha)
    else
        NaN
    end

    if static_margin < MIN_AUTO_STATIC_MARGIN || Cm_alpha > -0.1
        # In the model creator convention x increases aft. Low/negative
        # static margin is corrected by moving the CG forward.
        target_x_cg = x_np - TARGET_AUTO_STATIC_MARGIN * cref
        direction = "forward"
        reason = "low_static_margin"
        if target_x_cg >= x_cg - 1e-4
            return nothing
        end
    elseif static_margin > MAX_AUTO_STATIC_MARGIN ||
           (isfinite(trim_alpha_deg) && trim_alpha_deg < -2.0)
        # Excessive positive static margin can make an otherwise stable
        # aircraft unusable because it needs constant up-elevator to fly at
        # positive lift. Correct it by moving the CG aft, but keep the target
        # ahead of the neutral point.
        target_x_cg = x_np - TARGET_AUTO_STATIC_MARGIN * cref
        aft_limit = x_np - MIN_AUTO_STATIC_MARGIN * cref
        target_x_cg = min(target_x_cg, aft_limit)
        direction = "aft"
        reason = static_margin > MAX_AUTO_STATIC_MARGIN ? "excessive_static_margin" : "negative_trim_alpha"
        if target_x_cg <= x_cg + 1e-4
            return nothing
        end
    else
        return nothing
    end
    target_x_cg = round(target_x_cg, digits=3)

    adjusted = deepcopy(sanitized_json)
    gen = get!(adjusted, "general", Dict{String,Any}())
    cg = collect(Any, get(gen, "aircraft_CoG_coords_xyz_m", [x_cg, 0.0, 0.0]))
    while length(cg) < 3
        push!(cg, 0.0)
    end
    cg[1] = target_x_cg
    gen["aircraft_CoG_coords_xyz_m"] = cg
    adjusted["general"] = gen

    return (
        adjusted_json = adjusted,
        previous_x_m = x_cg,
        new_x_m = target_x_cg,
        static_margin = static_margin,
        target_static_margin = TARGET_AUTO_STATIC_MARGIN,
        neutral_point_x_m = x_np,
        trim_alpha_deg = trim_alpha_deg,
        direction = direction,
        reason = reason
    )
end

"""
    run_analysis(aircraft_json::Dict; progress_callback=nothing) -> Dict

Main entry point. Takes an extended aircraft JSON dictionary,
runs all requested backends, merges results, and returns
the unified aerodynamic model in schema v2.1 format.

`progress_callback(backend, status, percent, message)` is called
for real-time progress reporting.
"""
function run_analysis(aircraft_json::AbstractDict; progress_callback=nothing, cg_adjustment_pass::Int=0)
    cb = isnothing(progress_callback) ? (args...) -> nothing : progress_callback
    sanitized_json = strip_derived_aero_inputs(aircraft_json)

    # 1. Parse and validate input
    cb("input", "running", 0, "Parsing aircraft definition...")
    input = parse_aircraft_input(sanitized_json)
    cb("input", "complete", 100, "Input validated.")

    # 2. Determine backends to run
    backends = get(get(sanitized_json, "analysis", Dict()), "backends", ["vlm", "datcom"])
    results = Dict{String,Any}()

    # 3. Run VLM backend
    if "vlm" in backends
        cb("vlm", "running", 0, "Starting VortexLattice analysis...")
        try
            results["vlm"] = run_vlm_backend(input; progress_callback=(s, p, m) -> cb("vlm", s, p, m))
            cb("vlm", "complete", 100, "VLM analysis complete.")
        catch e
            bt = sprint(showerror, e, catch_backtrace())
            cb("vlm", "error", 0, "VLM error: $bt")
            results["vlm"] = nothing
        end
    end

    # 4. Run JAVL backend
    if "javl" in backends
        cb("javl", "running", 0, "Starting Julia AVL analysis...")
        try
            results["javl"] = run_javl_backend(input; progress_callback=(s, p, m) -> cb("javl", s, p, m))
            cb("javl", "complete", 100, "JAVL analysis complete.")
        catch e
            cb("javl", "error", 0, "JAVL error: $(sprint(showerror, e))")
            results["javl"] = nothing
        end
    end

    # 5. Run DATCOM backend
    if "datcom" in backends
        cb("datcom", "running", 0, "Starting DATCOM analysis...")
        try
            results["datcom"] = run_datcom_backend(input; progress_callback=(s, p, m) -> cb("datcom", s, p, m))
            cb("datcom", "complete", 100, "DATCOM analysis complete.")
        catch e
            cb("datcom", "error", 0, "DATCOM error: $(sprint(showerror, e))")
            results["datcom"] = nothing
        end
    end

    # 6. Build full aerobatic envelope (±180°)
    # Always runs — uses VLM linear derivatives when available, otherwise
    # generates all coefficients from geometry-based estimates alone.
    # This ensures CY, Cl, Cn are always populated (DATCOM doesn't compute them).
    cb("envelope", "running", 0, "Building full aerodynamic envelope...")
    vlm_data = get(results, "vlm", nothing)
    results["vlm"] = extend_to_full_envelope(input, vlm_data, sanitized_json)
    cb("envelope", "complete", 100, "Full envelope complete.")

    # 7. Merge results into unified model
    cb("merge", "running", 0, "Merging results...")
    model = merge_results(input, results, sanitized_json)
    cb("merge", "complete", 100, "Model generation complete.")

    cg_adjustment = _maybe_adjust_cg_for_static_margin(model, input, sanitized_json, cg_adjustment_pass)
    if !isnothing(cg_adjustment)
        cb("stability", "running", 0,
           "Static margin $(round(cg_adjustment.static_margin * 100; digits=1))% MAC; moving CG $(cg_adjustment.direction) and regenerating...")
        adjusted_model = run_analysis(cg_adjustment.adjusted_json;
                                      progress_callback=progress_callback,
                                      cg_adjustment_pass=cg_adjustment_pass + 1)
        meta = get!(adjusted_model, "meta", Dict{String,Any}())
        existing_notes = string(get(meta, "notes", ""))
        note = "CG auto-shifted from x=$(round(cg_adjustment.previous_x_m; digits=3)) m to x=$(round(cg_adjustment.new_x_m; digits=3)) m for $(round(cg_adjustment.target_static_margin * 100; digits=1))% target static margin"
        meta["notes"] = isempty(existing_notes) ? note : existing_notes * "; " * note
        quality = get!(adjusted_model, "quality", Dict{String,Any}())
        quality["cg_auto_adjustment"] = Dict(
            "previous_x_m" => cg_adjustment.previous_x_m,
            "new_x_m" => cg_adjustment.new_x_m,
            "initial_static_margin" => cg_adjustment.static_margin,
            "target_static_margin" => cg_adjustment.target_static_margin,
            "neutral_point_x_m" => cg_adjustment.neutral_point_x_m,
            "trim_alpha_deg" => cg_adjustment.trim_alpha_deg,
            "direction" => cg_adjustment.direction,
            "reason" => cg_adjustment.reason
        )
        cb("stability", "complete", 100, "CG adjusted and aerodynamic data regenerated.")
        return adjusted_model
    end

    # 8. Validate aerodynamic data quality
    cb("validation", "running", 0, "Running quality checks...")
    validation_report = validate_aero_model(model, input)
    if haskey(model, "quality")
        model["quality"]["validation"] = report_to_dict(validation_report)
    else
        model["quality"] = Dict("validation" => report_to_dict(validation_report))
    end
    print_report(validation_report)
    cb("validation", "complete", 100, validation_report.summary)

    return model
end

end # module
