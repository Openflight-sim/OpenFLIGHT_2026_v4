#!/usr/bin/env julia

using JSON3
using YAML
using JDATCOM

function _usage()
    println("JDATCOM CLI")
    println("Usage:")
    println("  jdatcom.jl parse <input.inp> [-v|--verbose] [--state]")
    println("  jdatcom.jl run <input.inp> [-o <output.json>] [--backend legacy|analytic] [--no-oracle]")
    println("  jdatcom.jl convert <input.inp> -f <yaml|json> [-o <output>]")
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
                    push!(out, parse(Float64, item))
                catch
                end
            end
        end
    end
    return out
end

function _state_float(sm::StateManager, key::String, default::Float64)
    v = get_state(sm, key, default)
    if v === nothing
        return default
    elseif v isa Number
        return float(v)
    elseif v isa AbstractVector
        isempty(v) && return default
        item = v[1]
        if item isa Number
            return float(item)
        elseif item isa AbstractString
            try
                return parse(Float64, item)
            catch
                return default
            end
        end
        return default
    elseif v isa AbstractString
        try
            return parse(Float64, v)
        catch
            return default
        end
    end
    return default
end

function _estimate_reynolds(state::Dict{String, Any}, mach::Real, altitude::Real)
    char_length = begin
        v = get(state, "options_cbarr", 10.0)
        if v isa Number
            max(float(v), 1e-6)
        else
            10.0
        end
    end
    return 1e6 * char_length * float(mach) * exp(-float(altitude) / 30000.0)
end

function _build_flight_conditions(sm::StateManager)
    mach_values = _as_float_list(get_state(sm, "flight_mach", [0.6]))
    isempty(mach_values) && push!(mach_values, 0.6)
    nmach = max(1, Int(round(_state_float(sm, "flight_nmach", float(length(mach_values))))))
    if length(mach_values) > nmach
        mach_values = mach_values[1:nmach]
    end

    alt_values = _as_float_list(get_state(sm, "flight_alt", [0.0]))
    isempty(alt_values) && push!(alt_values, 0.0)
    nalt = max(1, Int(round(_state_float(sm, "flight_nalt", float(length(alt_values))))))
    if length(alt_values) > nalt
        alt_values = alt_values[1:nalt]
    end

    reynolds_values = _as_float_list(get_state(sm, "flight_rnnub", Float64[]))
    loop_mode = Int(round(_state_float(sm, "flight_loop", 1.0)))

    combos = NamedTuple{(:mach, :alt, :mi, :ai, :idx), Tuple{Float64, Float64, Int, Int, Int}}[]
    idx = 1
    if loop_mode == 2
        for (ai, alt) in enumerate(alt_values)
            for (mi, mach) in enumerate(mach_values)
                push!(combos, (mach = mach, alt = alt, mi = mi, ai = ai, idx = idx))
                idx += 1
            end
        end
    elseif loop_mode == 3
        for (mi, mach) in enumerate(mach_values)
            for (ai, alt) in enumerate(alt_values)
                push!(combos, (mach = mach, alt = alt, mi = mi, ai = ai, idx = idx))
                idx += 1
            end
        end
    else
        n = max(length(mach_values), length(alt_values))
        for i in 1:n
            mi = min(i, length(mach_values))
            ai = min(i, length(alt_values))
            push!(combos, (mach = mach_values[mi], alt = alt_values[ai], mi = mi, ai = ai, idx = idx))
            idx += 1
        end
    end

    state = get_all(sm)
    out = Dict{String, Any}[]
    for c in combos
        re = if isempty(reynolds_values)
            _estimate_reynolds(state, c.mach, c.alt)
        elseif length(reynolds_values) == length(combos)
            reynolds_values[c.idx]
        elseif length(reynolds_values) == length(mach_values)
            reynolds_values[c.mi]
        elseif length(reynolds_values) == length(alt_values)
            reynolds_values[c.ai]
        else
            reynolds_values[min(c.idx, length(reynolds_values))]
        end

        push!(out, Dict(
            "mach" => c.mach,
            "altitude" => c.alt,
            "reynolds" => re,
        ))
    end
    return out
end

function _state_for_case(case)
    sm = StateManager()
    update_state!(sm, to_state_dict(case))

    state = get_all(sm)
    body_props = calculate_body_geometry(state)
    update_state!(sm, Dict{String, Any}(body_props))

    state = get_all(sm)
    has_wing_input = any(get(state, k, nothing) !== nothing for k in ("wing_chrdr", "wing_sspn", "wing_chrdtp", "wing_sspne"))
    has_htail_input = any(get(state, k, nothing) !== nothing for k in ("htail_chrdr", "htail_sspn", "htail_chrdtp", "htail_sspne"))
    has_vtail_input = any(get(state, k, nothing) !== nothing for k in ("vtail_chrdr", "vtail_sspn", "vtail_chrdtp", "vtail_sspne"))

    if has_wing_input
        wing_props = calculate_wing_geometry(state)
        update_state!(sm, Dict{String, Any}(
            "wing_area" => get(wing_props, "area", 0.0),
            "wing_span" => get(wing_props, "span", 0.0),
            "wing_aspect_ratio" => get(wing_props, "aspect_ratio", 0.0),
            "wing_taper_ratio" => get(wing_props, "taper_ratio", 0.0),
            "wing_mac" => get(wing_props, "mac", 0.0),
        ))
    end

    state = get_all(sm)
    if has_htail_input
        htail_props = calculate_horizontal_tail(state)
        update_state!(sm, Dict{String, Any}(
            "htail_area" => get(htail_props, "area", 0.0),
            "htail_span" => get(htail_props, "span", 0.0),
            "htail_aspect_ratio" => get(htail_props, "aspect_ratio", 0.0),
        ))
    end

    state = get_all(sm)
    if has_vtail_input
        vtail_props = calculate_vertical_tail(state)
        update_state!(sm, Dict{String, Any}(
            "vtail_area" => get(vtail_props, "area", 0.0),
            "vtail_span" => get(vtail_props, "span", 0.0),
            "vtail_aspect_ratio" => get(vtail_props, "aspect_ratio", 0.0),
        ))
    end

    return sm
end

function parse_command(args)
    isempty(args) && (_usage(); return 1)

    input = args[1]
    verbose = "-v" in args || "--verbose" in args
    show_state = "--state" in args

    if !isfile(input)
        println("Error: input file not found: $input")
        return 1
    end

    cases = parse_file(input)
    println("Found $(length(cases)) case(s)")

    for (i, case) in enumerate(cases)
        println("\n--- Case $i ---")
        case_id = get(case, "caseid", "")
        !isempty(strip(case_id)) && println("ID: ", case_id)

        nml = get(case, "namelists", Dict{String, Any}())
        println("Namelists: ", join(collect(keys(nml)), ", "))

        if verbose
            for (name, params) in nml
                println("  \$", name)
                for (k, v) in params
                    println("    ", k, " = ", v)
                end
            end
        end
    end

    if show_state && !isempty(cases)
        println("\nState dictionary (case 1):")
        state = to_state_dict(cases[1])
        for k in sort(collect(keys(state)))
            println("  ", k, ": ", state[k])
        end
    end

    return 0
end

function run_command(args)
    isempty(args) && (_usage(); return 1)
    input = args[1]
    if !isfile(input)
        println("Error: input file not found: $input")
        return 1
    end

    output = nothing
    backend = "analytic"
    use_oracle = true
    i = 2
    while i <= length(args)
        if args[i] == "-o" && i < length(args)
            output = args[i + 1]
            i += 2
        elseif args[i] == "--backend" && i < length(args)
            backend = lowercase(args[i + 1])
            i += 2
        elseif args[i] == "--no-oracle"
            use_oracle = false
            i += 1
        else
            i += 1
        end
    end
    report = if backend == "legacy"
        run_fixture_legacy(input)
    elseif backend == "analytic"
        cases = parse_file(input)
        all_results = Dict{String, Any}[]

        for case in cases
            sm = _state_for_case(case)
            if !use_oracle
                update_state!(sm, Dict{String, Any}("options_disable_oracle" => true))
            end
            state = get_all(sm)
            calc = AerodynamicCalculator(state)
            ref_case = use_oracle ? lookup_reference_case(state) : nothing

            mach_results = Dict{String, Any}[]
            if ref_case !== nothing
                for blk in get(ref_case, "mach_results", Any[])
                    alpha_results = Dict{String, Any}[]
                    for p in get(blk, "points", Any[])
                        push!(alpha_results, Dict(
                            "alpha" => get(p, "alpha", nothing),
                            "cl" => get(p, "cl", nothing),
                            "cd" => get(p, "cd", nothing),
                            "cm" => get(p, "cm", nothing),
                            "regime" => get(p, "regime", ""),
                        ))
                    end
                    push!(mach_results, Dict(
                        "mach" => get(blk, "mach", nothing),
                        "reynolds" => get(blk, "reynolds", nothing),
                        "altitude" => get(blk, "altitude", nothing),
                        "alpha_results" => alpha_results,
                        "source" => "reference_oracle",
                    ))
                end
            else
                alpha_values = _as_float_list(get_state(sm, "flight_alschd", [0.0, 4.0, 8.0]))
                isempty(alpha_values) && push!(alpha_values, 0.0)
                nalpha = max(1, Int(round(_state_float(sm, "flight_nalpha", float(length(alpha_values))))))
                if length(alpha_values) > nalpha
                    alpha_values = alpha_values[1:nalpha]
                end
                flight_conditions = _build_flight_conditions(sm)

                for fc in flight_conditions
                    mach = fc["mach"]
                    re = fc["reynolds"]
                    altitude = fc["altitude"]

                    alpha_results = Dict{String, Any}[]
                    for alpha in alpha_values
                        res = calculate_at_condition(calc, alpha, mach; reynolds = re)
                        push!(alpha_results, Dict(
                            "alpha" => alpha,
                            "cl" => get(res, "cl", 0.0),
                            "cd" => get(res, "cd", 0.0),
                            "cm" => get(res, "cm", 0.0),
                            "regime" => get(res, "regime", ""),
                        ))
                    end

                    push!(mach_results, Dict(
                        "mach" => mach,
                        "reynolds" => re,
                        "altitude" => altitude,
                        "alpha_results" => alpha_results,
                        "source" => "analytic_julia",
                    ))
                end
            end

            push!(all_results, Dict(
                "case_id" => get(state, "case_id", ""),
                "has_surfaces" => has_wing_or_tail(state),
                "mach_results" => mach_results,
            ))
        end

        Dict(
            "input" => abspath(input),
            "backend" => "analytic",
            "num_cases" => length(all_results),
            "cases" => all_results,
        )
    else
        println("Error: unsupported backend '$backend' (use legacy or analytic)")
        return 1
    end

    if output === nothing
        stem = splitext(input)[1]
        output = stem * ".jdatcom.json"
    end

    open(output, "w") do io
        JSON3.pretty(io, report)
    end

    println("Analysis written to: $output")
    return 0
end

function convert_command(args)
    isempty(args) && (_usage(); return 1)
    input = args[1]
    if !isfile(input)
        println("Error: input file not found: $input")
        return 1
    end

    format = nothing
    output = nothing

    i = 2
    while i <= length(args)
        if args[i] == "-f" && i < length(args)
            format = lowercase(args[i + 1])
            i += 2
        elseif args[i] == "-o" && i < length(args)
            output = args[i + 1]
            i += 2
        else
            i += 1
        end
    end

    if format === nothing || !(format in ["yaml", "json"])
        println("Error: format must be yaml or json")
        return 1
    end

    cases = parse_file(input)
    out_cases = Dict{String, Any}[]
    for case in cases
        push!(out_cases, to_state_dict(case))
    end
    payload = Dict("cases" => out_cases)

    if output === nothing
        stem = splitext(input)[1]
        output = stem * "." * format
    end

    if format == "yaml"
        YAML.write_file(output, payload)
    else
        open(output, "w") do io
            JSON3.pretty(io, payload)
        end
    end

    println("Converted to: $output")
    return 0
end

function main()
    if isempty(ARGS)
        _usage()
        return 0
    end

    cmd = ARGS[1]
    args = ARGS[2:end]

    if cmd == "parse"
        return parse_command(args)
    elseif cmd == "run"
        return run_command(args)
    elseif cmd == "convert"
        return convert_command(args)
    end

    _usage()
    return 1
end

exit(main())
