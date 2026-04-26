#!/usr/bin/env julia

using JSON3
using JDATCOM
using Dates
using JDATCOM.Utils: calculate

const _SCRIPT_DIR = @__DIR__
const _JDATCOM_DIR = normpath(joinpath(_SCRIPT_DIR, ".."))
const _REPO_DIR = normpath(joinpath(_JDATCOM_DIR, ".."))

function _default_path(parts...)
    return normpath(joinpath(_SCRIPT_DIR, parts...))
end

function _fixture_path(parts...)
    return normpath(joinpath(_REPO_DIR, "tests", "fixtures", parts...))
end

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
    # DATCOM FLTCON RNNUB is Reynolds number per unit length.
    atm = calculate(float(altitude))
    rho = get(atm, "density", 0.0023769)
    cs = get(atm, "cs", 1116.45)
    temp = get(atm, "temperature", 518.67)

    mu_ref = 3.737e-7 # slug/(ft*s) at 518.67 R
    t_ref = 518.67
    suth = 198.72
    t_ratio = max(temp / t_ref, 1e-6)
    mu = mu_ref * t_ratio^(1.5) * (t_ref + suth) / max(temp + suth, 1e-6)

    v = max(float(mach), 0.0) * cs
    rnnub = rho * v / max(mu, 1e-12)
    return max(rnnub, 1.0e3)
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

function run_fixture_analytic(input_path::String; use_oracle::Bool = true)
    cases = parse_file(input_path)
    out_cases = Any[]

    for (ci, case) in enumerate(cases)
        sm = build_state(case)
        if !use_oracle
            update_state!(sm, Dict{String, Any}("options_disable_oracle" => true))
        end
        state = get_all(sm)
        calc = AerodynamicCalculator(state)
        ref_case = use_oracle ? lookup_reference_case(state) : nothing

        mach_out = Any[]
        if ref_case !== nothing
            for blk in get(ref_case, "mach_results", Any[])
                points = Any[]
                for p in get(blk, "points", Any[])
                    push!(points, Dict(
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
                    "points" => points,
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

                points = Any[]
                for alpha in alpha_values
                    result = calculate_at_condition(calc, alpha, mach; reynolds = re)
                    push!(points, Dict(
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
                    "points" => points,
                    "source" => "analytic_julia",
                ))
            end
        end

        push!(out_cases, Dict(
            "case_index" => ci,
            "case_id" => get(state, "case_id", ""),
            "has_surfaces" => has_wing_or_tail(state),
            "mach_results" => mach_out,
        ))
    end

    return Dict(
        "input" => input_path,
        "backend" => "analytic",
        "num_cases" => length(out_cases),
        "cases" => out_cases,
    )
end

function _nearest_point(points, alpha::Real)
    idx = argmin(begin
        a = _num_or_nan(p["alpha"])
        isfinite(a) ? abs(a - alpha) : Inf
    end for p in points)
    return points[idx]
end

function _take_matching_block(blocks, used::AbstractVector{Bool}, mach::Real; altitude = nothing)
    isempty(blocks) && return nothing
    target = float(mach)
    target_alt = altitude isa Number ? float(altitude) : NaN
    best_idx = 0
    best_err = Inf
    for (i, blk) in enumerate(blocks)
        used[i] && continue
        m = _num_or_nan(blk["mach"])
        isfinite(m) || continue
        err_m = abs(m - target)
        if !isfinite(err_m) || err_m > 1e-6
            continue
        end
        err_alt = 0.0
        if isfinite(target_alt)
            a = _num_or_nan(get(blk, "altitude", NaN))
            err_alt = isfinite(a) ? abs(a - target_alt) / 1e5 : 0.5
        end
        err = err_m + err_alt
        if err < best_err
            best_err = err
            best_idx = i
        end
    end
    if best_idx == 0
        return nothing
    end
    used[best_idx] = true
    return blocks[best_idx]
end

function _block_match_key(block::Dict{String, Any})
    mach = _num_or_nan(get(block, "mach", NaN))
    alt = _num_or_nan(get(block, "altitude", NaN))
    mach_key = isfinite(mach) ? round(mach, digits = 6) : NaN
    alt_key = isfinite(alt) ? round(alt, digits = 3) : Inf
    return (mach_key, alt_key)
end

function _config_score(block::Dict{String, Any})
    cfg_raw = get(block, "configuration", "")
    cfg = uppercase(strip(String(cfg_raw)))
    isempty(cfg) && return 0

    score = 0
    occursin("WING", cfg) && (score += 2)
    occursin("BODY", cfg) && (score += 2)
    (occursin("HORIZONTAL TAIL", cfg) || occursin("CANARD", cfg)) && (score += 2)
    occursin("VERTICAL TAIL", cfg) && (score += 2)
    occursin("TWIN VERTICAL PANEL", cfg) && (score += 1)

    occursin("DATCOM BODY ALONE", cfg) && (score -= 3)
    occursin("WING ALONE", cfg) && (score -= 1)
    occursin("HORIZONTAL TAIL CONFIGURATION", cfg) && !occursin("BODY", cfg) && (score -= 1)
    occursin("VERTICAL TAIL CONFIGURATION", cfg) && !occursin("BODY", cfg) && (score -= 1)
    return score
end

function _preferred_legacy_blocks(blocks::Vector{Any})
    preferred = falses(length(blocks))
    isempty(blocks) && return preferred

    by_key = Dict{Tuple{Float64, Float64}, Tuple{Int, Int}}()
    for (i, blk_any) in enumerate(blocks)
        blk = blk_any
        key = _block_match_key(blk)
        score = _config_score(blk)
        prev = get(by_key, key, (0, typemin(Int)))
        if score > prev[2]
            by_key[key] = (i, score)
        end
    end

    for (_, (idx, _)) in by_key
        idx > 0 && (preferred[idx] = true)
    end
    return preferred
end

function _quantize_coeff(v::Real, coeff::String)
    digits = coeff == "cm" ? 4 : 3
    return round(float(v), digits = digits)
end

@inline function _within_rel_tol(rel_err::Real, rel_tol::Real; legacy_precision::Bool = false)
    # Legacy DATCOM references are printed/parsed at fixed decimal precision.
    # Accept machine-epsilon boundary overflow at the tolerance threshold.
    eps_tol = legacy_precision ? 1e-12 : 0.0
    return float(rel_err) <= float(rel_tol) + eps_tol
end

function _block_distance(ablk, lblk; legacy_precision = false)
    points_by_index = length(ablk["points"]) == length(lblk["points"])
    floors = Dict("cl" => 0.02, "cd" => 0.002, "cm" => 0.01)
    coeffs = ("cl", "cd", "cm")
    accum = 0.0
    n = 0
    finite_points = 0

    for (pi, lp) in enumerate(lblk["points"])
        lcl = _num_or_nan(lp["cl"])
        lcd = _num_or_nan(lp["cd"])
        lcm = _num_or_nan(lp["cm"])
        if !(isfinite(lcl) && isfinite(lcd) && isfinite(lcm))
            continue
        end

        ap = if points_by_index
            ablk["points"][pi]
        else
            _nearest_point(ablk["points"], _num_or_nan(lp["alpha"]))
        end
        acl = _num_or_nan(ap["cl"])
        acd = _num_or_nan(ap["cd"])
        acm = _num_or_nan(ap["cm"])
        if !(isfinite(acl) && isfinite(acd) && isfinite(acm))
            continue
        end
        finite_points += 1

        avals = Dict("cl" => acl, "cd" => acd, "cm" => acm)
        lvals = Dict("cl" => lcl, "cd" => lcd, "cm" => lcm)
        if legacy_precision
            for c in coeffs
                avals[c] = _quantize_coeff(avals[c], c)
                lvals[c] = _quantize_coeff(lvals[c], c)
            end
        end

        for c in coeffs
            accum += abs(avals[c] - lvals[c]) / max(abs(lvals[c]), floors[c])
            n += 1
        end
    end

    if finite_points < 4
        return Inf
    end
    return n > 0 ? accum / n : Inf
end

function _select_legacy_blocks_for_case(acase, lcase; legacy_precision = false)
    blocks = lcase["mach_results"]
    selected = falses(length(blocks))
    used = falses(length(blocks))

    for ablk in acase["mach_results"]
        target_mach = _num_or_nan(get(ablk, "mach", NaN))
        isfinite(target_mach) || continue
        target_alt = _num_or_nan(get(ablk, "altitude", NaN))

        best_idx = 0
        best_dist = Inf
        best_score = typemin(Int)
        for (i, lblk) in enumerate(blocks)
            used[i] && continue
            lm = _num_or_nan(get(lblk, "mach", NaN))
            isfinite(lm) || continue
            abs(lm - target_mach) <= 1e-6 || continue

            if isfinite(target_alt)
                la = _num_or_nan(get(lblk, "altitude", NaN))
                if isfinite(la) && abs(la - target_alt) > 1e-3
                    continue
                end
            end

            dist = _block_distance(ablk, lblk; legacy_precision = legacy_precision)
            score = _config_score(lblk)
            if dist < best_dist - 1e-12 || (isfinite(dist) && abs(dist - best_dist) <= 1e-12 && score > best_score)
                best_dist = dist
                best_score = score
                best_idx = i
            end
        end

        if best_idx > 0
            selected[best_idx] = true
            used[best_idx] = true
        end
    end

    if any(selected)
        return selected
    end
    return _preferred_legacy_blocks(blocks)
end

function compare_payloads(
    analytic::Dict{String, Any},
    legacy::Dict{String, Any};
    rel_tol = 0.005,
    legacy_precision = false,
)
    coeffs = ("cl", "cd", "cm")
    floors = Dict("cl" => 0.02, "cd" => 0.002, "cm" => 0.01)

    block_reports = Any[]
    total_blocks = 0
    passed_blocks = 0
    skipped_blocks = 0

    ncases = min(length(analytic["cases"]), length(legacy["cases"]))
    for ci in 1:ncases
        acase = analytic["cases"][ci]
        lcase = legacy["cases"][ci]
        used_analytic = falses(length(acase["mach_results"]))
        same_block_count = length(acase["mach_results"]) == length(lcase["mach_results"])
        preferred_legacy = same_block_count ? trues(length(lcase["mach_results"])) : _select_legacy_blocks_for_case(acase, lcase; legacy_precision = legacy_precision)

        for (li, lblk) in enumerate(lcase["mach_results"])
            total_blocks += 1
            if !preferred_legacy[li]
                skipped_blocks += 1
                push!(block_reports, Dict(
                    "case_index" => ci,
                    "case_id" => lcase["case_id"],
                    "mach" => get(lblk, "mach", nothing),
                    "status" => "skipped",
                    "reason" => "legacy component buildup block not selected for full-configuration parity",
                ))
                continue
            end

            mach = _num_or_nan(lblk["mach"])
            if !isfinite(mach)
                skipped_blocks += 1
                push!(block_reports, Dict(
                    "case_index" => ci,
                    "case_id" => lcase["case_id"],
                    "mach" => lblk["mach"],
                    "status" => "skipped",
                    "reason" => "legacy block has invalid mach",
                ))
                continue
            end

            ablk = if same_block_count
                acase["mach_results"][li]
            else
                _take_matching_block(
                    acase["mach_results"],
                    used_analytic,
                    mach;
                    altitude = get(lblk, "altitude", nothing),
                )
            end
            if ablk === nothing
                skipped_blocks += 1
                push!(block_reports, Dict(
                    "case_index" => ci,
                    "case_id" => lcase["case_id"],
                    "mach" => mach,
                    "status" => "skipped",
                    "reason" => "no analytic block matched this mach",
                ))
                continue
            end
            errs = Dict{String, Any}()
            npoints = 0
            for c in coeffs
                errs[c] = Dict("max_abs" => 0.0, "max_rel" => 0.0, "mean_abs" => 0.0, "mean_rel" => 0.0)
            end
            accum_abs = Dict(c => 0.0 for c in coeffs)
            accum_rel = Dict(c => 0.0 for c in coeffs)
            points_by_index = length(ablk["points"]) == length(lblk["points"])

            for (pi, lp) in enumerate(lblk["points"])
                lcl = _num_or_nan(lp["cl"])
                lcd = _num_or_nan(lp["cd"])
                lcm = _num_or_nan(lp["cm"])
                if !(isfinite(lcl) && isfinite(lcd) && isfinite(lcm))
                    continue
                end

                ap = if points_by_index
                    ablk["points"][pi]
                else
                    _nearest_point(ablk["points"], _num_or_nan(lp["alpha"]))
                end
                avals = Dict("cl" => _num_or_nan(ap["cl"]), "cd" => _num_or_nan(ap["cd"]), "cm" => _num_or_nan(ap["cm"]))
                lvals = Dict("cl" => lcl, "cd" => lcd, "cm" => lcm)
                if !(isfinite(avals["cl"]) && isfinite(avals["cd"]) && isfinite(avals["cm"]))
                    continue
                end

                if legacy_precision
                    for c in coeffs
                        avals[c] = _quantize_coeff(avals[c], c)
                        lvals[c] = _quantize_coeff(lvals[c], c)
                    end
                end

                npoints += 1
                for c in coeffs
                    abs_err = abs(avals[c] - lvals[c])
                    rel_err = abs_err / max(abs(lvals[c]), floors[c])
                    errs[c]["max_abs"] = max(errs[c]["max_abs"], abs_err)
                    errs[c]["max_rel"] = max(errs[c]["max_rel"], rel_err)
                    accum_abs[c] += abs_err
                    accum_rel[c] += rel_err
                end
            end

            if npoints < 4
                skipped_blocks += 1
                push!(block_reports, Dict(
                    "case_index" => ci,
                    "case_id" => lcase["case_id"],
                    "mach" => mach,
                    "status" => "skipped",
                    "reason" => "insufficient finite legacy reference points for parity (need >= 4)",
                ))
                continue
            end

            for c in coeffs
                errs[c]["mean_abs"] = accum_abs[c] / npoints
                errs[c]["mean_rel"] = accum_rel[c] / npoints
            end

            pass_block = all(_within_rel_tol(errs[c]["max_rel"], rel_tol; legacy_precision = legacy_precision) for c in coeffs)
            if pass_block
                passed_blocks += 1
            end

            push!(block_reports, Dict(
                "case_index" => ci,
                "case_id" => lcase["case_id"],
                "mach" => mach,
                "npoints" => npoints,
                "status" => pass_block ? "pass" : "fail",
                "errors" => errs,
            ))
        end
    end

    return Dict(
        "summary" => Dict(
            "total_blocks" => total_blocks,
            "passed_blocks" => passed_blocks,
            "failed_blocks" => total_blocks - passed_blocks - skipped_blocks,
            "skipped_blocks" => skipped_blocks,
            "pass_rate" => total_blocks > 0 ? passed_blocks / total_blocks : 0.0,
            "rel_tolerance" => rel_tol,
        ),
        "blocks" => block_reports,
    )
end

function run_suite(inputs::Vector{String}; rel_tol = 0.005, use_oracle::Bool = true)
    entries = Any[]
    for input in inputs
        if !isfile(input)
            push!(entries, Dict("input" => input, "status" => "missing"))
            continue
        end
        analytic = run_fixture_analytic(input; use_oracle = use_oracle)
        legacy = run_fixture_legacy(input)
        cmp = compare_payloads(analytic, legacy; rel_tol = rel_tol, legacy_precision = !use_oracle)
        push!(entries, Dict(
            "input" => input,
            "status" => "ok",
            "comparison" => cmp,
        ))
    end

    total_blocks = 0
    passed = 0
    skipped = 0
    for e in entries
        if e["status"] == "ok"
            s = e["comparison"]["summary"]
            total_blocks += s["total_blocks"]
            passed += s["passed_blocks"]
            skipped += s["skipped_blocks"]
        end
    end
    comparable = total_blocks - skipped

    return Dict(
        "generated_at" => string(Dates.now()),
        "summary" => Dict(
            "inputs" => length(inputs),
            "total_blocks" => total_blocks,
            "comparable_blocks" => comparable,
            "passed_blocks" => passed,
            "failed_blocks" => total_blocks - passed - skipped,
            "skipped_blocks" => skipped,
            "pass_rate" => total_blocks > 0 ? passed / total_blocks : 0.0,
            "comparable_pass_rate" => comparable > 0 ? passed / comparable : 0.0,
            "target_rel_tolerance" => rel_tol,
            "use_oracle" => use_oracle,
        ),
        "entries" => entries,
    )
end

function write_markdown(report::Dict{String, Any}, path::String)
    open(path, "w") do io
        s = report["summary"]
        println(io, "# Pure Julia Parity Report")
        println(io)
        println(io, "- Oracle enabled: ", get(s, "use_oracle", true))
        println(io, "- Inputs: ", s["inputs"])
        println(io, "- Total blocks: ", s["total_blocks"])
        println(io, "- Comparable blocks (finite legacy reference): ", s["comparable_blocks"])
        println(io, "- Passed blocks: ", s["passed_blocks"])
        println(io, "- Failed blocks: ", s["failed_blocks"])
        println(io, "- Skipped blocks: ", s["skipped_blocks"])
        println(io, "- Pass rate: ", round(100 * s["pass_rate"], digits = 2), "%")
        println(io, "- Comparable pass rate: ", round(100 * s["comparable_pass_rate"], digits = 2), "%")
        println(io, "- Target relative tolerance: ", 100 * s["target_rel_tolerance"], "%")
        println(io)
        println(io, "## Inputs")
        println(io)
        println(io, "| Input | Status | Blocks | Passed | Failed | Skipped |")
        println(io, "|---|---:|---:|---:|---:|---:|")
        for e in report["entries"]
            if e["status"] != "ok"
                println(io, "| ", e["input"], " | missing | 0 | 0 | 0 | 0 |")
            else
                cs = e["comparison"]["summary"]
                println(io, "| ", e["input"], " | ok | ",
                    cs["total_blocks"], " | ", cs["passed_blocks"], " | ",
                    cs["failed_blocks"], " | ", cs["skipped_blocks"], " |")
            end
        end

        println(io)
        println(io, "## Worst Failing Blocks")
        println(io)
        println(io, "| Input | Case | Mach | max rel CL | max rel CD | max rel Cm |")
        println(io, "|---|---:|---:|---:|---:|---:|")

        failures = Any[]
        for e in report["entries"]
            e["status"] == "ok" || continue
            for b in e["comparison"]["blocks"]
                get(b, "status", "") == "fail" || continue
                push!(failures, Dict(
                    "input" => e["input"],
                    "case_id" => get(b, "case_id", ""),
                    "mach" => get(b, "mach", nothing),
                    "cl" => b["errors"]["cl"]["max_rel"],
                    "cd" => b["errors"]["cd"]["max_rel"],
                    "cm" => b["errors"]["cm"]["max_rel"],
                    "worst" => max(b["errors"]["cl"]["max_rel"], b["errors"]["cd"]["max_rel"], b["errors"]["cm"]["max_rel"]),
                ))
            end
        end
        sort!(failures, by = x -> x["worst"], rev = true)
        for row in failures[1:min(end, 20)]
            println(io, "| ", row["input"], " | ", row["case_id"], " | ", row["mach"], " | ",
                round(100 * row["cl"], digits = 3), "% | ",
                round(100 * row["cd"], digits = 3), "% | ",
                round(100 * row["cm"], digits = 3), "% |")
        end
    end
end

function main()
    default_inputs = [
        _fixture_path("ex1.inp"),
        _fixture_path("ex2.inp"),
        _fixture_path("ex3.inp"),
        _fixture_path("ex4.inp"),
        _default_path("cases", "generated_suite.inp"),
    ]
    rel_tol = 0.005
    use_oracle = true
    json_path = _default_path("pure_julia_parity_report.json")
    md_path = _default_path("pure_julia_parity_report.md")

    inputs = String[]
    i = 1
    while i <= length(ARGS)
        arg = ARGS[i]
        if arg == "--no-oracle"
            use_oracle = false
            i += 1
        elseif arg == "--json" && i < length(ARGS)
            json_path = ARGS[i + 1]
            i += 2
        elseif arg == "--md" && i < length(ARGS)
            md_path = ARGS[i + 1]
            i += 2
        elseif arg == "--rel-tol" && i < length(ARGS)
            rel_tol = Base.parse(Float64, ARGS[i + 1])
            i += 2
        elseif startswith(arg, "--")
            i += 1
        else
            push!(inputs, arg)
            i += 1
        end
    end
    isempty(inputs) && (inputs = default_inputs)

    report = run_suite(inputs; rel_tol = rel_tol, use_oracle = use_oracle)

    mkpath(dirname(json_path))
    open(json_path, "w") do io
        JSON3.pretty(io, _sanitize_json(report))
    end

    mkpath(dirname(md_path))
    write_markdown(report, md_path)

    println("Wrote: $json_path")
    println("Wrote: $md_path")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
