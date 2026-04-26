#!/usr/bin/env julia

using JSON3
using Dates

include("run_parity_suite.jl")

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

function _write_report(report::Dict{String, Any}, json_path::String, md_path::String)
    mkpath(dirname(json_path))
    open(json_path, "w") do io
        JSON3.pretty(io, _sanitize_json(report))
    end
    write_markdown(report, md_path)
end

function main()
    full_inputs = [
        "tests/fixtures/ex1.inp",
        "tests/fixtures/ex2.inp",
        "tests/fixtures/ex3.inp",
        "tests/fixtures/ex4.inp",
        "JDATCOM/validation/cases/generated_suite.inp",
    ]

    holdout_input = "JDATCOM/validation/cases/holdout_suite.inp"
    if !isfile(holdout_input)
        include("generate_validation_cases.jl")
        generate_cases(holdout_input; seed = 20260225)
    end

    report_oracle = run_suite(full_inputs; rel_tol = 0.005, use_oracle = true)
    report_holdout = run_suite([holdout_input]; rel_tol = 0.005, use_oracle = false)

    _write_report(
        report_oracle,
        "JDATCOM/validation/pure_julia_parity_report.json",
        "JDATCOM/validation/pure_julia_parity_report.md",
    )
    _write_report(
        report_holdout,
        "JDATCOM/validation/analytic_holdout_report.json",
        "JDATCOM/validation/analytic_holdout_report.md",
    )

    summary_path = "JDATCOM/validation/phase2_progress_summary.md"
    open(summary_path, "w") do io
        println(io, "# Phase 2 Progress Summary")
        println(io)
        println(io, "- Generated at: ", Dates.now())
        so = report_oracle["summary"]
        sh = report_holdout["summary"]
        println(io, "- Oracle parity comparable pass rate: ", round(100 * so["comparable_pass_rate"], digits = 2), "%")
        println(io, "- Holdout no-oracle comparable pass rate: ", round(100 * sh["comparable_pass_rate"], digits = 2), "%")
        println(io)
        println(io, "## Oracle Parity")
        println(io)
        println(io, "- Comparable blocks: ", so["comparable_blocks"])
        println(io, "- Passed: ", so["passed_blocks"])
        println(io, "- Failed: ", so["failed_blocks"])
        println(io, "- Skipped: ", so["skipped_blocks"])
        println(io)
        println(io, "## Holdout No-Oracle")
        println(io)
        println(io, "- Comparable blocks: ", sh["comparable_blocks"])
        println(io, "- Passed: ", sh["passed_blocks"])
        println(io, "- Failed: ", sh["failed_blocks"])
        println(io, "- Skipped: ", sh["skipped_blocks"])
    end

    println("Wrote: JDATCOM/validation/pure_julia_parity_report.json")
    println("Wrote: JDATCOM/validation/pure_julia_parity_report.md")
    println("Wrote: JDATCOM/validation/analytic_holdout_report.json")
    println("Wrote: JDATCOM/validation/analytic_holdout_report.md")
    println("Wrote: $summary_path")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
