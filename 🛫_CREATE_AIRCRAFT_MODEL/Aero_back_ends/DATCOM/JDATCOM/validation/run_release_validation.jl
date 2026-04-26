#!/usr/bin/env julia

using JSON3
using Dates

const _SCRIPT_DIR = @__DIR__
const _PROJECT_DIR = normpath(joinpath(_SCRIPT_DIR, ".."))

function _parse_seeds(arg::String)
    out = Int[]
    for token in split(arg, ',')
        s = strip(token)
        isempty(s) && continue
        push!(out, parse(Int, s))
    end
    return out
end

function _read_json(path::String)
    return JSON3.read(read(path, String), Dict{String, Any})
end

function _run_qualification(
    seeds::Vector{Int},
    rel_tol::Float64,
    json_out::String,
    md_out::String,
)
    seeds_arg = join(string.(seeds), ",")
    cmd = `$(Base.julia_cmd()) --project=$(_PROJECT_DIR) $(joinpath(_SCRIPT_DIR, "run_parity_qualification.jl")) --seeds $seeds_arg --rel-tol $(string(rel_tol)) --json $json_out --md $md_out`
    println(">> ", cmd)
    return success(cmd)
end

function _summary_line(name::String, report::Dict{String, Any})
    combined = report["combined"]
    return string(
        name, ": combined ",
        combined["passed_blocks"], "/", combined["comparable_blocks"],
        ", generated ",
        report["generated"]["passed_blocks"], "/", report["generated"]["comparable_blocks"],
        ", overall_pass=", get(report, "overall_pass", false),
    )
end

function _write_summary(
    path::String,
    gate_report::Dict{String, Any},
    smoke_report::Union{Dict{String, Any}, Nothing},
    gate_ok::Bool,
    baseline_report::Union{Dict{String, Any}, Nothing},
)
    open(path, "w") do io
        println(io, "# JDATCOM Release Validation Summary")
        println(io)
        println(io, "- Generated at: ", Dates.now())
        println(io, "- Gate status (1.0%): ", gate_ok ? "PASS" : "FAIL")
        println(io)
        println(io, "## Runs")
        println(io)
        println(io, "- ", _summary_line("1.0% full qualification (30 seeds)", gate_report))
        if smoke_report !== nothing
            println(io, "- ", _summary_line("0.5% smoke (5 seeds)", smoke_report))
        else
            println(io, "- 0.5% smoke (5 seeds): not available")
        end
        if baseline_report !== nothing
            cur = gate_report["combined"]
            base = baseline_report["combined"]
            println(io)
            println(io, "## Frozen Baseline Delta (1.0% combined)")
            println(io)
            println(io, "- Current passed/comparable: ", cur["passed_blocks"], "/", cur["comparable_blocks"])
            println(io, "- Baseline passed/comparable: ", base["passed_blocks"], "/", base["comparable_blocks"])
            println(io, "- Current failed: ", cur["failed_blocks"])
            println(io, "- Baseline failed: ", base["failed_blocks"])
        end
    end
end

function main()
    out_dir = joinpath(_SCRIPT_DIR, "release_current")
    full_seeds = collect(20260301:20260330)
    smoke_seeds = collect(20260301:20260305)
    baseline_path = joinpath(_SCRIPT_DIR, "release_baseline", "parity_qualification_report_1pct_seed30.json")

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg == "--out-dir" && i < length(ARGS)
            out_dir = ARGS[i + 1]
            i += 2
        elseif arg == "--full-seeds" && i < length(ARGS)
            full_seeds = _parse_seeds(ARGS[i + 1])
            i += 2
        elseif arg == "--smoke-seeds" && i < length(ARGS)
            smoke_seeds = _parse_seeds(ARGS[i + 1])
            i += 2
        elseif arg == "--baseline" && i < length(ARGS)
            baseline_path = ARGS[i + 1]
            i += 2
        else
            i += 1
        end
    end

    mkpath(out_dir)

    gate_json = joinpath(out_dir, "parity_qualification_report_1pct_seed30.json")
    gate_md = joinpath(out_dir, "parity_qualification_report_1pct_seed30.md")
    smoke_json = joinpath(out_dir, "parity_qualification_report_05pct_smoke_seed5.json")
    smoke_md = joinpath(out_dir, "parity_qualification_report_05pct_smoke_seed5.md")

    gate_ok = _run_qualification(full_seeds, 0.01, gate_json, gate_md)
    _run_qualification(smoke_seeds, 0.005, smoke_json, smoke_md)

    if !isfile(gate_json)
        println("Gate report not found: $gate_json")
        return 2
    end

    gate_report = _read_json(gate_json)
    smoke_report = isfile(smoke_json) ? _read_json(smoke_json) : nothing
    baseline_report = isfile(baseline_path) ? _read_json(baseline_path) : nothing

    summary_path = joinpath(out_dir, "release_validation_summary.md")
    _write_summary(summary_path, gate_report, smoke_report, gate_ok, baseline_report)

    println("Wrote: $gate_json")
    println("Wrote: $gate_md")
    if smoke_report !== nothing
        println("Wrote: $smoke_json")
        println("Wrote: $smoke_md")
    end
    println("Wrote: $summary_path")

    return gate_ok ? 0 : 2
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
