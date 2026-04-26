#!/usr/bin/env julia

using JSON3

function _read_json(path::String)
    return JSON3.read(read(path, String), Dict{String, Any})
end

function _usage()
    println("Usage:")
    println("  julia --project=JDATCOM JDATCOM/validation/check_frozen_baseline.jl --current <current_report.json> --baseline <baseline_report.json> [--scope combined]")
end

function main()
    current_path = ""
    baseline_path = ""
    scope = "combined"

    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg == "--current" && i < length(ARGS)
            current_path = ARGS[i + 1]
            i += 2
        elseif arg == "--baseline" && i < length(ARGS)
            baseline_path = ARGS[i + 1]
            i += 2
        elseif arg == "--scope" && i < length(ARGS)
            scope = ARGS[i + 1]
            i += 2
        else
            i += 1
        end
    end

    if isempty(current_path) || isempty(baseline_path) || !isfile(current_path) || !isfile(baseline_path)
        _usage()
        return 2
    end

    current = _read_json(current_path)
    baseline = _read_json(baseline_path)

    if !haskey(current, scope) || !haskey(baseline, scope)
        println("Missing scope '$scope' in one of the reports.")
        return 2
    end

    cur = current[scope]
    base = baseline[scope]

    failures = String[]

    if haskey(current, "overall_pass") && current["overall_pass"] != true
        push!(failures, "current overall_pass is false")
    end

    if cur["failed_blocks"] > base["failed_blocks"]
        push!(failures, "failed_blocks regressed: $(cur["failed_blocks"]) > $(base["failed_blocks"])")
    end
    if cur["passed_blocks"] < base["passed_blocks"]
        push!(failures, "passed_blocks regressed: $(cur["passed_blocks"]) < $(base["passed_blocks"])")
    end
    if cur["comparable_blocks"] < base["comparable_blocks"]
        push!(failures, "comparable_blocks regressed: $(cur["comparable_blocks"]) < $(base["comparable_blocks"])")
    end

    println("Scope: $scope")
    println("Current passed/comparable: $(cur["passed_blocks"])/$(cur["comparable_blocks"])")
    println("Baseline passed/comparable: $(base["passed_blocks"])/$(base["comparable_blocks"])")
    println("Current failed: $(cur["failed_blocks"])")
    println("Baseline failed: $(base["failed_blocks"])")

    if isempty(failures)
        println("Frozen baseline check: PASS")
        return 0
    end

    println("Frozen baseline check: FAIL")
    for msg in failures
        println("- $msg")
    end
    return 2
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
