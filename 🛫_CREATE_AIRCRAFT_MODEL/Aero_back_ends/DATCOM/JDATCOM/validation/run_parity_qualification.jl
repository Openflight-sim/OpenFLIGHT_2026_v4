#!/usr/bin/env julia

using JSON3
using Dates
using JDATCOM

include("run_parity_suite.jl")
include("generate_validation_cases.jl")

const _SCRIPT_DIR = @__DIR__
const _JDATCOM_DIR = normpath(joinpath(_SCRIPT_DIR, ".."))
const _REPO_DIR = normpath(joinpath(_JDATCOM_DIR, ".."))

function _default_path(parts...)
    return normpath(joinpath(_SCRIPT_DIR, parts...))
end

function _fixture_path(parts...)
    return normpath(joinpath(_REPO_DIR, "tests", "fixtures", parts...))
end

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

function _as_float_list(v)
    out = Float64[]
    if v === nothing
        return out
    elseif v isa Number
        push!(out, float(v))
        return out
    elseif v isa AbstractVector
        for item in v
            if item isa Number
                push!(out, float(item))
            elseif item isa AbstractString
                try
                    push!(out, Base.parse(Float64, item))
                catch
                end
            end
        end
    end
    return out
end

function _state_has_value(state::Dict{String, Any}, key::String)
    v = get(state, key, nothing)
    if v === nothing
        return false
    elseif v isa AbstractVector
        return any(item -> item !== nothing, v)
    end
    return true
end

function _has_expr_inputs(state::Dict{String, Any})
    for k in keys(state)
        ks = String(k)
        if startswith(ks, "expr01_") || startswith(ks, "expr02_")
            return true
        end
    end
    return false
end

function _wing_type_bucket(v)
    if v isa Number
        fv = float(v)
        if fv < 1.5
            return "wing_type_1"
        elseif fv < 2.5
            return "wing_type_2"
        end
        return "wing_type_3"
    end
    return nothing
end

function _has_true_flag(v)
    if v isa Bool
        return v
    elseif v isa Number
        return v != 0
    elseif v isa AbstractString
        s = lowercase(strip(v))
        return s in ("1", "true", ".true.", "yes", "on")
    end
    return false
end

function _coverage_counts(inputs::Vector{String})
    counts = Dict(
        "inputs" => length(inputs),
        "cases_total" => 0,
        "mach_points_total" => 0,
        "body_only_cases" => 0,
        "wing_only_cases" => 0,
        "full_config_cases" => 0,
        "canard_cases" => 0,
        "expr_cases" => 0,
        "hypersonic_cases" => 0,
        "wing_type_1" => 0,
        "wing_type_2" => 0,
        "wing_type_3" => 0,
        "subsonic_regime" => 0,
        "transonic_regime" => 0,
        "supersonic_regime" => 0,
        "hypersonic_regime" => 0,
    )

    for input_path in inputs
        isfile(input_path) || continue
        cases = parse_file(input_path)
        for case in cases
            state = to_state_dict(case)
            counts["cases_total"] += 1

            has_body = _state_has_value(state, "body_x") || _state_has_value(state, "body_nx")
            has_wing = _state_has_value(state, "wing_chrdr") || _state_has_value(state, "wing_sspn") || _state_has_value(state, "wing_chrdtp")
            has_htail = _state_has_value(state, "htail_chrdr") || _state_has_value(state, "htail_sspn") || _state_has_value(state, "htail_chrdtp")
            has_vtail = _state_has_value(state, "vtail_chrdr") || _state_has_value(state, "vtail_sspn") || _state_has_value(state, "vtail_chrdtp")

            if has_body && !has_wing && !has_htail && !has_vtail
                counts["body_only_cases"] += 1
            end
            if has_wing && !has_body && !has_htail && !has_vtail
                counts["wing_only_cases"] += 1
            end
            if has_body && has_wing && has_htail && has_vtail
                counts["full_config_cases"] += 1
            end

            xcg = get(state, "synths_xcg", nothing)
            xh = get(state, "synths_xh", nothing)
            if has_htail && xcg isa Number && xh isa Number && float(xh) < float(xcg)
                counts["canard_cases"] += 1
            end

            _has_expr_inputs(state) && (counts["expr_cases"] += 1)
            _has_true_flag(get(state, "flight_hypers", false)) && (counts["hypersonic_cases"] += 1)

            wing_bucket = _wing_type_bucket(get(state, "wing_type", nothing))
            wing_bucket !== nothing && (counts[wing_bucket] += 1)

            mach_values = _as_float_list(get(state, "flight_mach", Float64[]))
            counts["mach_points_total"] += length(mach_values)
            for m in mach_values
                if m < 0.9
                    counts["subsonic_regime"] += 1
                elseif m < 1.2
                    counts["transonic_regime"] += 1
                elseif m < 5.0
                    counts["supersonic_regime"] += 1
                else
                    counts["hypersonic_regime"] += 1
                end
            end
        end
    end

    return counts
end

function _skipped_reason_hist(report::Dict{String, Any})
    hist = Dict{String, Int}()
    for e in report["entries"]
        get(e, "status", "") == "ok" || continue
        for b in e["comparison"]["blocks"]
            if get(b, "status", "") == "skipped"
                reason = String(get(b, "reason", "unspecified"))
                hist[reason] = get(hist, reason, 0) + 1
            end
        end
    end
    return hist
end

function _worst_failures(report::Dict{String, Any}; limit::Int = 20)
    rows = Any[]
    for e in report["entries"]
        get(e, "status", "") == "ok" || continue
        input_path = String(get(e, "input", ""))
        for b in e["comparison"]["blocks"]
            get(b, "status", "") == "fail" || continue
            errs = get(b, "errors", Dict{String, Any}())
            cl_rel = get(get(errs, "cl", Dict{String, Any}()), "max_rel", NaN)
            cd_rel = get(get(errs, "cd", Dict{String, Any}()), "max_rel", NaN)
            cm_rel = get(get(errs, "cm", Dict{String, Any}()), "max_rel", NaN)
            worst = maximum([float(cl_rel), float(cd_rel), float(cm_rel)])
            push!(rows, Dict(
                "input" => input_path,
                "case_id" => String(get(b, "case_id", "")),
                "mach" => get(b, "mach", nothing),
                "max_rel_cl" => cl_rel,
                "max_rel_cd" => cd_rel,
                "max_rel_cm" => cm_rel,
                "worst_rel" => worst,
            ))
        end
    end
    sort!(rows, by = x -> x["worst_rel"], rev = true)
    return rows[1:min(end, limit)]
end

function _load_spec(path::String)
    if !isfile(path)
        return Dict("required_features" => Any[])
    end
    return JSON3.read(read(path, String), Dict{String, Any})
end

function _feature_gate_value(feature_id::String, counts::AbstractDict{<:Any, <:Any})
    if feature_id == "hypersonic_flag"
        return get(counts, "hypersonic_cases", 0)
    end
    return get(counts, feature_id, 0)
end

function _build_gates(
    report::AbstractDict{<:Any, <:Any},
    coverage::AbstractDict{<:Any, <:Any},
    spec::AbstractDict{<:Any, <:Any};
    min_comparable::Int,
)
    gates = Any[]
    summary = report["summary"]
    comp = Int(summary["comparable_blocks"])
    fail = Int(summary["failed_blocks"])

    push!(gates, Dict(
        "id" => "numeric_parity",
        "description" => "No failed comparable block at target tolerance.",
        "pass" => fail == 0,
        "value" => fail,
        "target" => 0,
    ))
    push!(gates, Dict(
        "id" => "comparable_volume",
        "description" => "Comparable block count is above minimum threshold.",
        "pass" => comp >= min_comparable,
        "value" => comp,
        "target" => min_comparable,
    ))

    for req in get(spec, "required_features", Any[])
        feature_id = String(get(req, "id", ""))
        isempty(feature_id) && continue
        feature_value = _feature_gate_value(feature_id, coverage)
        push!(gates, Dict(
            "id" => feature_id,
            "description" => String(get(req, "description", feature_id)),
            "pass" => feature_value > 0,
            "value" => feature_value,
            "target" => "> 0",
        ))
    end
    return gates
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

function _write_markdown(path::String, report::Dict{String, Any})
    open(path, "w") do io
        println(io, "# Parity Qualification Report")
        println(io)
        println(io, "- Generated at: ", report["generated_at"])
        println(io, "- Target relative tolerance: ", 100 * report["settings"]["rel_tol"], "%")
        println(io, "- Overall gate pass: ", report["overall_pass"])
        println(io)

        println(io, "## Parity Summaries")
        println(io)
        println(io, "| Scope | Inputs | Comparable | Passed | Failed | Skipped | Comparable Pass Rate |")
        println(io, "|---|---:|---:|---:|---:|---:|---:|")
        for scope_name in ("baseline", "generated", "combined")
            s = report[scope_name]
            println(
                io,
                "| ", scope_name,
                " | ", s["inputs"],
                " | ", s["comparable_blocks"],
                " | ", s["passed_blocks"],
                " | ", s["failed_blocks"],
                " | ", s["skipped_blocks"],
                " | ", round(100 * s["comparable_pass_rate"], digits = 2), "% |",
            )
        end
        println(io)

        println(io, "## Gate Status")
        println(io)
        println(io, "| Gate | Pass | Value | Target |")
        println(io, "|---|---:|---:|---:|")
        for g in report["gates"]
            println(io, "| ", g["id"], " | ", g["pass"], " | ", g["value"], " | ", g["target"], " |")
        end
        println(io)

        println(io, "## Coverage Counts")
        println(io)
        println(io, "| Metric | Count |")
        println(io, "|---|---:|")
        for k in sort(collect(keys(report["coverage"])))
            println(io, "| ", k, " | ", report["coverage"][k], " |")
        end
        println(io)

        println(io, "## Skipped Block Reasons (Combined)")
        println(io)
        println(io, "| Reason | Count |")
        println(io, "|---|---:|")
        skipped = report["skipped_reason_histogram"]
        rows = collect(skipped)
        sort!(rows, by = r -> r[2], rev = true)
        for (reason, count) in rows
            println(io, "| ", reason, " | ", count, " |")
        end
        println(io)

        println(io, "## Generated Inputs")
        println(io)
        for p in report["settings"]["generated_inputs"]
            println(io, "- ", p)
        end
        println(io)

        println(io, "## Worst Failing Blocks")
        println(io)
        println(io, "| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |")
        println(io, "|---|---|---:|---:|---:|---:|")
        for row in report["worst_failures"]
            println(
                io,
                "| ", row["input"],
                " | ", row["case_id"],
                " | ", row["mach"],
                " | ", round(100 * row["max_rel_cl"], digits = 3), "% | ",
                round(100 * row["max_rel_cd"], digits = 3), "% | ",
                round(100 * row["max_rel_cm"], digits = 3), "% |",
            )
        end
    end
end

function main()
    rel_tol = 0.005
    min_comparable = 20
    seeds = [20260301, 20260302, 20260303]
    json_out = _default_path("parity_qualification_report.json")
    md_out = _default_path("parity_qualification_report.md")
    spec_path = _default_path("parity_feature_spec.json")

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg == "--rel-tol" && i < length(ARGS)
            rel_tol = Base.parse(Float64, ARGS[i + 1])
            i += 2
        elseif arg == "--min-comparable" && i < length(ARGS)
            min_comparable = Base.parse(Int, ARGS[i + 1])
            i += 2
        elseif arg == "--seeds"
            if i < length(ARGS) && !startswith(ARGS[i + 1], "--")
                seeds = _parse_seeds(ARGS[i + 1])
                i += 2
            else
                seeds = Int[]
                i += 1
            end
        elseif arg == "--json" && i < length(ARGS)
            json_out = ARGS[i + 1]
            i += 2
        elseif arg == "--md" && i < length(ARGS)
            md_out = ARGS[i + 1]
            i += 2
        elseif arg == "--spec" && i < length(ARGS)
            spec_path = ARGS[i + 1]
            i += 2
        else
            i += 1
        end
    end

    base_inputs = [
        _fixture_path("ex1.inp"),
        _fixture_path("ex2.inp"),
        _fixture_path("ex3.inp"),
        _fixture_path("ex4.inp"),
        _default_path("cases", "generated_suite.inp"),
    ]

    generated_inputs = String[]
    qual_dir = _default_path("cases", "qualification")
    mkpath(qual_dir)
    for seed in seeds
        out_path = joinpath(qual_dir, "generated_seed_$(seed).inp")
        generate_cases(out_path; seed = seed)
        push!(generated_inputs, out_path)
    end

    baseline = run_suite(base_inputs; rel_tol = rel_tol, use_oracle = false)
    generated = run_suite(generated_inputs; rel_tol = rel_tol, use_oracle = false)
    combined_inputs = vcat(base_inputs, generated_inputs)
    combined = run_suite(combined_inputs; rel_tol = rel_tol, use_oracle = false)

    coverage = _coverage_counts(combined_inputs)
    skipped_hist = _skipped_reason_hist(combined)
    worst_failures = _worst_failures(combined; limit = 20)
    spec = _load_spec(spec_path)
    gates = _build_gates(combined, coverage, spec; min_comparable = min_comparable)
    overall_pass = all(get(g, "pass", false) for g in gates)

    report = Dict(
        "generated_at" => string(Dates.now()),
        "overall_pass" => overall_pass,
        "settings" => Dict(
            "rel_tol" => rel_tol,
            "min_comparable" => min_comparable,
            "seeds" => seeds,
            "base_inputs" => base_inputs,
            "generated_inputs" => generated_inputs,
            "spec_path" => spec_path,
        ),
        "baseline" => baseline["summary"],
        "generated" => generated["summary"],
        "combined" => combined["summary"],
        "coverage" => coverage,
        "skipped_reason_histogram" => skipped_hist,
        "worst_failures" => worst_failures,
        "gates" => gates,
    )

    mkpath(dirname(json_out))
    open(json_out, "w") do io
        JSON3.pretty(io, _sanitize_json(report))
    end
    _write_markdown(md_out, report)

    println("Wrote: $json_out")
    println("Wrote: $md_out")
    println("Overall pass: $overall_pass")
    return overall_pass ? 0 : 2
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
