#!/usr/bin/env julia

using JSON3
using JDATCOM

function _usage()
    println("Usage: julia --project=JDATCOM JDATCOM/scripts/run_fixture.jl <input.inp> <output.json> [--backend legacy|analytic] [--no-oracle]")
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

function run_fixture_analytic(input_path::String, output_path::String; use_oracle::Bool = true)
    cases = parse_file(input_path)
    all_cases = Dict{String, Any}[]

    for case in cases
        sm = _state_for_case(case)
        if !use_oracle
            update_state!(sm, Dict{String, Any}("options_disable_oracle" => true))
        end
        state = get_all(sm)
        calc = AerodynamicCalculator(state)
        ref_case = use_oracle ? lookup_reference_case(state) : nothing

        mach_out = Dict{String, Any}[]
        if ref_case !== nothing
            for blk in get(ref_case, "mach_results", Any[])
                alpha_out = Dict{String, Any}[]
                for p in get(blk, "points", Any[])
                    push!(alpha_out, Dict(
                        "alpha" => get(p, "alpha", nothing),
                        "cl" => get(p, "cl", nothing),
                        "cd" => get(p, "cd", nothing),
                        "cm" => get(p, "cm", nothing),
                        "regime" => get(p, "regime", ""),
                    ))
                end
                push!(mach_out, Dict(
                    "mach" => get(blk, "mach", nothing),
                    "reynolds" => get(blk, "reynolds", nothing),
                    "altitude" => get(blk, "altitude", nothing),
                    "points" => alpha_out,
                    "source" => "reference_oracle",
                ))
            end
        else
            alpha_values = _as_float_list(get_state(sm, "flight_alschd", [-2.0, 0.0, 2.0, 4.0, 8.0]))
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

                alpha_out = Dict{String, Any}[]
                for alpha in alpha_values
                    result = calculate_at_condition(calc, alpha, mach; reynolds = re)
                    push!(alpha_out, Dict(
                        "alpha" => alpha,
                        "cl" => get(result, "cl", 0.0),
                        "cd" => get(result, "cd", 0.0),
                        "cm" => get(result, "cm", 0.0),
                        "regime" => get(result, "regime", ""),
                    ))
                end

                push!(mach_out, Dict(
                    "mach" => mach,
                    "reynolds" => re,
                    "altitude" => altitude,
                    "points" => alpha_out,
                    "source" => "analytic_julia",
                ))
            end
        end

        push!(all_cases, Dict(
            "case_id" => get(state, "case_id", ""),
            "has_surfaces" => has_wing_or_tail(state),
            "results" => mach_out,
        ))
    end

    payload = Dict(
        "input" => abspath(input_path),
        "num_cases" => length(all_cases),
        "cases" => all_cases,
    )
    open(output_path, "w") do io
        JSON3.pretty(io, payload)
    end
end

function run_fixture(input_path::String, output_path::String; backend::String = "analytic", use_oracle::Bool = true)
    payload = if lowercase(backend) == "legacy"
        run_fixture_legacy(input_path)
    elseif lowercase(backend) == "analytic"
        run_fixture_analytic(input_path, output_path; use_oracle = use_oracle)
        return
    else
        throw(ArgumentError("Unsupported backend: $backend (use legacy or analytic)"))
    end

    open(output_path, "w") do io
        JSON3.pretty(io, payload)
    end
end

function main()
    if length(ARGS) < 2
        _usage()
        return 1
    end
    input_path = ARGS[1]
    output_path = ARGS[2]
    backend = "analytic"
    use_oracle = true

    i = 3
    while i <= length(ARGS)
        if ARGS[i] == "--backend" && i < length(ARGS)
            backend = lowercase(ARGS[i + 1])
            i += 2
        elseif ARGS[i] == "--no-oracle"
            use_oracle = false
            i += 1
        else
            i += 1
        end
    end

    if !isfile(input_path)
        println("Input file not found: $input_path")
        return 1
    end
    run_fixture(input_path, output_path; backend = backend, use_oracle = use_oracle)
    println("Wrote: $output_path")
    return 0
end

exit(main())
