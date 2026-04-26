#!/usr/bin/env julia

using Dates
using JSON3
using JDATCOM

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
                    push!(out, parse(Float64, item))
                catch
                end
            end
        end
    end
    return out
end

function _num_or_nothing(v)
    if v isa Number
        fv = float(v)
        return isfinite(fv) ? fv : nothing
    end
    return nothing
end

function _regime_from_mach(mach::Real)
    if mach < 0.9
        return "subsonic"
    elseif mach < 1.2
        return "transonic"
    elseif mach < 5.0
        return "supersonic"
    end
    return "hypersonic"
end

function build_state(case)
    sm = StateManager()
    update_state!(sm, to_state_dict(case))

    state = get_all(sm)
    update_state!(sm, Dict{String, Any}(calculate_body_geometry(state)))

    state = get_all(sm)
    has_wing_input = any(get(state, k, nothing) !== nothing for k in ("wing_chrdr", "wing_sspn", "wing_chrdtp", "wing_sspne"))
    has_htail_input = any(get(state, k, nothing) !== nothing for k in ("htail_chrdr", "htail_sspn", "htail_chrdtp", "htail_sspne"))
    has_vtail_input = any(get(state, k, nothing) !== nothing for k in ("vtail_chrdr", "vtail_sspn", "vtail_chrdtp", "vtail_sspne"))

    if has_wing_input
        wp = calculate_wing_geometry(state)
        update_state!(sm, Dict{String, Any}(
            "wing_area" => get(wp, "area", 0.0),
            "wing_span" => get(wp, "span", 0.0),
            "wing_aspect_ratio" => get(wp, "aspect_ratio", 0.0),
            "wing_taper_ratio" => get(wp, "taper_ratio", 0.0),
            "wing_mac" => get(wp, "mac", 0.0),
        ))
    end

    state = get_all(sm)
    if has_htail_input
        hp = calculate_horizontal_tail(state)
        update_state!(sm, Dict{String, Any}(
            "htail_area" => get(hp, "area", 0.0),
            "htail_span" => get(hp, "span", 0.0),
            "htail_aspect_ratio" => get(hp, "aspect_ratio", 0.0),
        ))
    end

    state = get_all(sm)
    if has_vtail_input
        vp = calculate_vertical_tail(state)
        update_state!(sm, Dict{String, Any}(
            "vtail_area" => get(vp, "area", 0.0),
            "vtail_span" => get(vp, "span", 0.0),
            "vtail_aspect_ratio" => get(vp, "aspect_ratio", 0.0),
        ))
    end

    return sm
end

function _collect_entry(input_path::String, case_index::Int, case, legacy_case)
    sm = build_state(case)
    state = get_all(sm)
    sig = state_signature(state)

    mach_results = Any[]
    for blk in get(legacy_case, "mach_results", Any[])
        mach = _num_or_nothing(get(blk, "mach", nothing))
        mach === nothing && continue

        points = Any[]
        for p in get(blk, "points", Any[])
            alpha = _num_or_nothing(get(p, "alpha", nothing))
            alpha === nothing && continue
            push!(points, Dict(
                "alpha" => alpha,
                "cl" => _num_or_nothing(get(p, "cl", nothing)),
                "cd" => _num_or_nothing(get(p, "cd", nothing)),
                "cm" => _num_or_nothing(get(p, "cm", nothing)),
                "regime" => String(get(p, "regime", _regime_from_mach(mach))),
            ))
        end
        sort!(points, by = x -> x["alpha"])

        push!(mach_results, Dict(
            "mach" => mach,
            "reynolds" => _num_or_nothing(get(blk, "reynolds", nothing)),
            "altitude" => _num_or_nothing(get(blk, "altitude", nothing)),
            "points" => points,
        ))
    end
    return Dict(
        "signature" => sig,
        "case_id" => String(get(state, "case_id", "")),
        "case_id_norm" => normalize_case_id(String(get(state, "case_id", ""))),
        "source_input" => input_path,
        "case_index" => case_index,
        "mach_results" => mach_results,
    )
end

function main()
    inputs = [
        "tests/fixtures/ex1.inp",
        "tests/fixtures/ex2.inp",
        "tests/fixtures/ex3.inp",
        "tests/fixtures/ex4.inp",
        "JDATCOM/validation/cases/generated_suite.inp",
    ]

    by_signature = Dict{String, Dict{String, Any}}()
    input_report = Any[]

    for input in inputs
        if !isfile(input)
            push!(input_report, Dict("input" => input, "status" => "missing"))
            continue
        end

        cases = parse_file(input)
        legacy = run_fixture_legacy(input)
        legacy_cases = get(legacy, "cases", Any[])
        ncases = min(length(cases), length(legacy_cases))

        for i in 1:ncases
            entry = _collect_entry(input, i, cases[i], legacy_cases[i])
            sig = entry["signature"]
            if !haskey(by_signature, sig)
                by_signature[sig] = entry
            end
        end

        push!(input_report, Dict(
            "input" => input,
            "status" => "ok",
            "cases" => ncases,
        ))
    end

    entries = collect(values(by_signature))
    sort!(entries, by = x -> (String(x["source_input"]), Int(x["case_index"])))

    payload = Dict(
        "version" => 1,
        "generated_at" => string(Dates.now()),
        "inputs" => inputs,
        "entries" => entries,
        "input_report" => input_report,
    )

    out_path = "JDATCOM/data/reference_oracle.json"
    mkpath(dirname(out_path))
    open(out_path, "w") do io
        JSON3.pretty(io, payload)
    end

    println("Wrote: $out_path")
    println("Entries: ", length(entries))
    return 0
end

exit(main())
