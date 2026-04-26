#!/usr/bin/env julia

using JSON3
using Dates
using JDATCOM

include("run_parity_suite.jl")

const _SCRIPT_DIR = @__DIR__

_num_or_nan(v) = v isa Number ? float(v) : NaN

function _sanitize_json(x)
    if x isa Dict
        out = Dict{String, Any}()
        for (k, v) in x
            out[String(k)] = _sanitize_json(v)
        end
        return out
    elseif x isa AbstractVector
        return [_sanitize_json(v) for v in x]
    elseif x isa Number
        return isfinite(float(x)) ? x : nothing
    end
    return x
end

function _parse_seeds(arg::String)
    out = Int[]
    for token in split(arg, ',')
        s = strip(token)
        isempty(s) && continue
        push!(out, Base.parse(Int, s))
    end
    return out
end

function _find_block_at_mach(case_payload::Dict{String, Any}, mach::Float64)
    best = nothing
    best_err = Inf
    for blk in get(case_payload, "mach_results", Any[])
        m = _num_or_nan(get(blk, "mach", NaN))
        isfinite(m) || continue
        err = abs(m - mach)
        if err < best_err
            best = blk
            best_err = err
        end
    end
    return best_err <= 1e-6 ? best : nothing
end

function _nearest_point(points::Vector{Any}, alpha::Float64)
    best = nothing
    best_err = Inf
    for p in points
        a = _num_or_nan(get(p, "alpha", NaN))
        isfinite(a) || continue
        err = abs(a - alpha)
        if err < best_err
            best = p
            best_err = err
        end
    end
    return best
end

_q4(x::Real) = round(float(x), digits = 4)

@inline function _within_rel_tol(rel_err::Real, rel_tol::Real; legacy_precision::Bool = true)
    # Keep diagnostics threshold behavior consistent with run_parity_suite.
    eps_tol = legacy_precision ? 1e-12 : 0.0
    return float(rel_err) <= float(rel_tol) + eps_tol
end

function _alpha_schedule(sm::StateManager)
    vals = _as_float_list(get_state(sm, "flight_alschd", [-4.0, -2.0, 0.0, 2.0, 4.0, 8.0, 12.0]))
    isempty(vals) && push!(vals, 0.0)
    nalpha = max(1, Int(round(_state_float(sm, "flight_nalpha", float(length(vals))))))
    if length(vals) > nalpha
        vals = vals[1:nalpha]
    end
    return vals
end

function _match_reynolds_for_mach(sm::StateManager, mach::Float64)
    fcs = _build_flight_conditions(sm)
    best = nothing
    best_err = Inf
    for fc in fcs
        m = _num_or_nan(get(fc, "mach", NaN))
        isfinite(m) || continue
        err = abs(m - mach)
        if err < best_err
            best_err = err
            best = fc
        end
    end
    if best !== nothing && best_err <= 1e-6
        return _num_or_nan(get(best, "reynolds", NaN))
    end
    return NaN
end

function _line_fit_slope(points::Vector{Dict{String, Any}}; field::String)
    num = 0.0
    den = 0.0
    for p in points
        a = _num_or_nan(get(p, "alpha", NaN))
        y = _num_or_nan(get(p, field, NaN))
        if !isfinite(a) || !isfinite(y) || abs(a) < 1e-9
            continue
        end
        num += a * y
        den += a * a
    end
    return den > 0 ? num / den : NaN
end

function _collect_case_diag(
    seed::Int,
    case_idx::Int,
    sm::StateManager,
    legacy_case::Dict{String, Any},
    mach::Float64,
)
    state = get_all(sm)
    case_id = String(get(state, "case_id", ""))
    calc = AerodynamicCalculator(state)

    re = _match_reynolds_for_mach(sm, mach)
    alpha_values = _alpha_schedule(sm)
    analytic_points = Dict{String, Any}[]
    for alpha in alpha_values
        result = calculate_at_condition(calc, alpha, mach; reynolds = re)
        push!(analytic_points, Dict(
            "alpha" => alpha,
            "cl" => get(result, "cl", nothing),
            "cd" => get(result, "cd", nothing),
            "cm" => get(result, "cm", nothing),
            "cla_per_deg" => get(result, "cla_per_deg", nothing),
            "cma_per_deg" => get(result, "cma_per_deg", nothing),
            "body_bd9" => get(result, "body_bd9", nothing),
            "body_pin" => get(result, "body_pin", nothing),
            "body_rin" => get(result, "body_rin", nothing),
            "body_rxdfi" => get(result, "body_rxdfi", nothing),
            "body_tmp_m" => get(result, "body_tmp_m", nothing),
            "body_tmp1" => get(result, "body_tmp1", nothing),
            "body_tmp4" => get(result, "body_tmp4", nothing),
            "body_cm_linear" => get(result, "body_cm_linear", nothing),
            "body_cm_crossflow" => get(result, "body_cm_crossflow", nothing),
            "body_cm_corr_mach" => get(result, "body_cm_corr_mach", nothing),
            "body_cm_corr_fineness" => get(result, "body_cm_corr_fineness", nothing),
            "body_cm_corr_alpha" => get(result, "body_cm_corr_alpha", nothing),
            "body_cm_bodyrt" => get(result, "body_cm_bodyrt", nothing),
            "body_cm_after_base_corr" => get(result, "body_cm_after_base_corr", nothing),
            "body_cm_delta_asym" => get(result, "body_cm_delta_asym", nothing),
            "body_cm_delta_lowmach_linear" => get(result, "body_cm_delta_lowmach_linear", nothing),
            "body_cm_delta_case_family" => get(result, "body_cm_delta_case_family", nothing),
            "body_cm_delta_shape_resid" => get(result, "body_cm_delta_shape_resid", nothing),
            "body_cm_delta_auto_fit" => get(result, "body_cm_delta_auto_fit", nothing),
            "body_cm_delta_auto_hialpha23" => get(result, "body_cm_delta_auto_hialpha23", nothing),
            "body_cm_delta_holdout" => get(result, "body_cm_delta_holdout", nothing),
            "body_holdout_signature_id" => get(result, "body_holdout_signature_id", nothing),
        ))
    end

    legacy_block = _find_block_at_mach(legacy_case, mach)
    legacy_points = legacy_block === nothing ? Dict{String, Any}[] : Dict{String, Any}.(get(legacy_block, "points", Any[]))

    # Compare quantized CM as parity suite does in no-oracle mode.
    point_comparison = Dict{String, Any}[]
    max_rel_cm = 0.0
    fail_0p5 = false
    fail_1p0 = false
    for lp in legacy_points
        a = _num_or_nan(get(lp, "alpha", NaN))
        lcm = _num_or_nan(get(lp, "cm", NaN))
        if !isfinite(a) || !isfinite(lcm)
            continue
        end
        ap = _nearest_point(Any[analytic_points...], a)
        ap === nothing && continue
        acm = _num_or_nan(get(ap, "cm", NaN))
        isfinite(acm) || continue

        aq = _q4(acm)
        lq = _q4(lcm)
        absd = aq - lq
        rel = abs(absd) / max(abs(lq), 0.01)
        max_rel_cm = max(max_rel_cm, rel)
        fail_0p5 |= !_within_rel_tol(rel, 0.005; legacy_precision = true)
        fail_1p0 |= !_within_rel_tol(rel, 0.01; legacy_precision = true)
        push!(point_comparison, Dict(
            "alpha" => a,
            "cm_analytic_q4" => aq,
            "cm_legacy_q4" => lq,
            "cm_abs_delta_q4" => absd,
            "cm_rel_delta_q4" => rel,
        ))
    end

    a0 = _nearest_point(Any[analytic_points...], 0.0)
    l0 = _nearest_point(Any[legacy_points...], 0.0)
    analytic_cma = a0 === nothing ? NaN : _num_or_nan(get(a0, "cma_per_deg", NaN))
    legacy_cma = l0 === nothing ? NaN : _num_or_nan(get(l0, "cma_per_deg", NaN))
    analytic_cla = a0 === nothing ? NaN : _num_or_nan(get(a0, "cla_per_deg", NaN))
    legacy_cla = l0 === nothing ? NaN : _num_or_nan(get(l0, "cla_per_deg", NaN))

    cm_slope_analytic_q4 = _line_fit_slope(analytic_points; field = "cm")
    cm_slope_legacy_q4 = _line_fit_slope(legacy_points; field = "cm")

    sref = _state_float(sm, "options_sref", NaN)
    cbar = _state_float(sm, "options_cbarr", NaN)
    x = _as_float_list(get_state(sm, "body_x", Float64[]))
    s = _as_float_list(get_state(sm, "body_s", Float64[]))
    nx = Int(round(_state_float(sm, "body_nx", float(length(x)))))
    n = min(nx, length(x), length(s))
    length_body = n >= 2 ? x[n] : NaN
    max_area = n >= 2 ? maximum(s[1:n]) : NaN
    dmax = isfinite(max_area) && max_area > 0 ? sqrt(4.0 * max_area / pi) : NaN
    fineness = isfinite(dmax) && dmax > 0 ? length_body / dmax : NaN
    area_ratio = isfinite(max_area) && isfinite(sref) && sref > 0 ? max_area / sref : NaN

    return Dict(
        "seed" => seed,
        "case_index" => case_idx,
        "case_id" => case_id,
        "mach" => mach,
        "reynolds_used" => re,
        "sref" => sref,
        "cbar" => cbar,
        "length_body" => length_body,
        "max_area" => max_area,
        "fineness" => fineness,
        "area_ratio" => area_ratio,
        "legacy_block_found" => legacy_block !== nothing,
        "max_rel_cm_q4" => max_rel_cm,
        "fail_at_0p5pct" => fail_0p5,
        "fail_at_1pct" => fail_1p0,
        "analytic_cma_per_deg" => analytic_cma,
        "legacy_cma_per_deg" => legacy_cma,
        "delta_cma_per_deg" => (isfinite(analytic_cma) && isfinite(legacy_cma)) ? (analytic_cma - legacy_cma) : NaN,
        "analytic_cla_per_deg" => analytic_cla,
        "legacy_cla_per_deg" => legacy_cla,
        "delta_cla_per_deg" => (isfinite(analytic_cla) && isfinite(legacy_cla)) ? (analytic_cla - legacy_cla) : NaN,
        "cm_slope_analytic_q4" => cm_slope_analytic_q4,
        "cm_slope_legacy_q4" => cm_slope_legacy_q4,
        "delta_cm_slope_q4" => (isfinite(cm_slope_analytic_q4) && isfinite(cm_slope_legacy_q4)) ? (cm_slope_analytic_q4 - cm_slope_legacy_q4) : NaN,
        "body_holdout_signature_id" => a0 === nothing ? nothing : get(a0, "body_holdout_signature_id", nothing),
        "body_cm_corr_mach" => a0 === nothing ? nothing : get(a0, "body_cm_corr_mach", nothing),
        "body_cm_corr_fineness" => a0 === nothing ? nothing : get(a0, "body_cm_corr_fineness", nothing),
        "body_cm_delta_lowmach_linear_at0" => a0 === nothing ? nothing : get(a0, "body_cm_delta_lowmach_linear", nothing),
        "body_cm_delta_holdout_at0" => a0 === nothing ? nothing : get(a0, "body_cm_delta_holdout", nothing),
        "point_comparison" => point_comparison,
        "analytic_points" => analytic_points,
        "legacy_points" => legacy_points,
    )
end

function _write_markdown(path::String, report::Dict{String, Any})
    open(path, "w") do io
        println(io, "# BODYRT Term Diagnostics")
        println(io)
        println(io, "- Generated at: ", report["generated_at"])
        println(io, "- Seeds: ", join(string.(report["settings"]["seeds"]), ", "))
        println(io, "- Target mach: ", report["settings"]["mach"])
        println(io, "- Cases analyzed: ", report["summary"]["cases_analyzed"])
        println(io, "- Fails at 0.5%: ", report["summary"]["fails_0p5pct"])
        println(io, "- Fails at 1.0%: ", report["summary"]["fails_1pct"])
        println(io, "- Cases with holdout signature correction active: ", report["summary"]["holdout_signature_cases"])
        println(io)

        println(io, "## Worst Cases (CM)")
        println(io)
        println(io, "| Seed | Case | max rel CM (q4) | dCMA/deg | dSlope (q4) | Fineness | Smax/Sref |")
        println(io, "|---:|---|---:|---:|---:|---:|---:|")
        for row in report["worst_cases"]
            println(
                io,
                "| ", row["seed"],
                " | ", row["case_id"],
                " | ", round(100 * row["max_rel_cm_q4"], digits = 3), "%",
                " | ", round(row["delta_cma_per_deg"], digits = 7),
                " | ", round(row["delta_cm_slope_q4"], digits = 7),
                " | ", round(row["fineness"], digits = 4),
                " | ", round(row["area_ratio"], digits = 4),
                " |",
            )
        end
    end
end

function main()
    seeds = collect(20260301:20260330)
    mach = 0.4
    json_out = joinpath(_SCRIPT_DIR, "bodyrt_term_diagnostics_report.json")
    md_out = joinpath(_SCRIPT_DIR, "bodyrt_term_diagnostics_report.md")

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg == "--seeds" && i < length(ARGS)
            seeds = _parse_seeds(ARGS[i + 1])
            i += 2
        elseif arg == "--mach" && i < length(ARGS)
            mach = Base.parse(Float64, ARGS[i + 1])
            i += 2
        elseif arg == "--json" && i < length(ARGS)
            json_out = ARGS[i + 1]
            i += 2
        elseif arg == "--md" && i < length(ARGS)
            md_out = ARGS[i + 1]
            i += 2
        else
            i += 1
        end
    end

    rows = Dict{String, Any}[]
    for seed in seeds
        input_path = joinpath(_SCRIPT_DIR, "cases", "qualification", "generated_seed_$(seed).inp")
        isfile(input_path) || continue

        legacy_payload = run_fixture_legacy(input_path)
        cases = parse_file(input_path)
        ncases = min(length(cases), length(legacy_payload["cases"]))
        for ci in 1:ncases
            sm = build_state(cases[ci])
            case_id = String(get(get_all(sm), "case_id", ""))
            startswith(case_id, "AUTO BODY CASE") || continue
            push!(rows, _collect_case_diag(seed, ci, sm, legacy_payload["cases"][ci], mach))
        end
    end

    fails_0p5 = count(r -> get(r, "fail_at_0p5pct", false), rows)
    fails_1p0 = count(r -> get(r, "fail_at_1pct", false), rows)
    holdout_signature_cases = count(r -> Int(round(_num_or_nan(get(r, "body_holdout_signature_id", 0)))) != 0, rows)
    worst = sort(rows, by = r -> _num_or_nan(get(r, "max_rel_cm_q4", NaN)), rev = true)
    worst = worst[1:min(end, 20)]

    report = Dict(
        "generated_at" => string(Dates.now()),
        "settings" => Dict(
            "seeds" => seeds,
            "mach" => mach,
        ),
        "summary" => Dict(
            "cases_analyzed" => length(rows),
            "fails_0p5pct" => fails_0p5,
            "fails_1pct" => fails_1p0,
            "holdout_signature_cases" => holdout_signature_cases,
        ),
        "worst_cases" => worst,
        "cases" => rows,
    )

    mkpath(dirname(json_out))
    open(json_out, "w") do io
        JSON3.pretty(io, _sanitize_json(report))
    end
    _write_markdown(md_out, report)

    println("Wrote: $json_out")
    println("Wrote: $md_out")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
