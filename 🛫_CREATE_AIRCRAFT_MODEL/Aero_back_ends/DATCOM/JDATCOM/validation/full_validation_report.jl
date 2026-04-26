#!/usr/bin/env julia

using JSON3
using JDATCOM
using Statistics

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

function as_float_list(v)
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

function run_fixture(input_path::String)
    return run_fixture_legacy(input_path)
end

function regime_from_mach(mach::Real)
    if mach < 0.9
        return "subsonic"
    elseif mach < 1.2
        return "transonic"
    elseif mach < 5.0
        return "supersonic"
    end
    return "hypersonic"
end

function diagnose_case(case_data)
    all_points = Any[]
    for m in case_data["mach_results"]
        for p in m["points"]
            push!(all_points, merge(Dict("mach" => m["mach"]), p))
        end
    end

    ndm_points = count(p -> !isfinite(_num_or_nan(p["cl"])) || !isfinite(_num_or_nan(p["cd"])) || !isfinite(_num_or_nan(p["cm"])), all_points)
    finite_ok = ndm_points == 0
    cd_positive = all((cd = _num_or_nan(p["cd"]); isfinite(cd) ? cd > 0 : true) for p in all_points)

    regime_ok = true
    for p in all_points
        m = _num_or_nan(p["mach"])
        expected = regime_from_mach(isfinite(m) ? m : 0.0)
        if p["regime"] != expected && !(startswith(p["regime"], "body_alone") && expected in ("subsonic", "transonic", "supersonic", "hypersonic"))
            regime_ok = false
            break
        end
    end

    cl_slope_nonnegative = true
    for blk in case_data["mach_results"]
        low_alpha = sort(
            [p for p in blk["points"] if isfinite(_num_or_nan(p["alpha"])) && isfinite(_num_or_nan(p["cl"])) && abs(_num_or_nan(p["alpha"])) <= 4.0],
            by = x -> _num_or_nan(x["alpha"]),
        )
        if length(low_alpha) >= 3
            for i in 1:(length(low_alpha) - 1)
                if _num_or_nan(low_alpha[i + 1]["cl"]) < _num_or_nan(low_alpha[i]["cl"]) - 1e-9
                    cl_slope_nonnegative = false
                    break
                end
            end
        end
        if !cl_slope_nonnegative
            break
        end
    end

    notes = String[]
    !finite_ok && push!(notes, "DATCOM reported NDM/non-finite coefficients at $ndm_points point(s).")
    !cd_positive && push!(notes, "Negative/zero CD detected.")
    !regime_ok && push!(notes, "Regime label does not match Mach thresholds.")
    !cl_slope_nonnegative && push!(notes, "CL is not monotonic near zero alpha.")
    isempty(notes) && push!(notes, "No numerical/pathology flags.")

    return Dict(
        "finite_ok" => finite_ok,
        "ndm_points" => ndm_points,
        "cd_positive" => cd_positive,
        "regime_consistent" => regime_ok,
        "low_alpha_cl_monotonic" => cl_slope_nonnegative,
        "notes" => notes,
    )
end

function nearest_mach_block(case_data, mach::Real)
    blocks = case_data["mach_results"]
    idx = argmin(begin
        m = _num_or_nan(b["mach"])
        isfinite(m) ? abs(m - mach) : Inf
    end for b in blocks)
    return blocks[idx]
end

function ref_comparison(case_data, mach::Real, refs::Dict{Float64, Dict{String, Float64}})
    blocks = case_data["mach_results"]
    mach_dists = [begin
        m = _num_or_nan(b["mach"])
        isfinite(m) ? abs(m - mach) : Inf
    end for b in blocks]
    min_dist = minimum(mach_dists)
    candidate_idxs = findall(d -> d == min_dist, mach_dists)

    function block_score(blk)
        pts = blk["points"]
        total = 0.0
        for alpha in keys(refs)
            p_idx = argmin(begin
                a = _num_or_nan(p["alpha"])
                isfinite(a) ? abs(a - alpha) : Inf
            end for p in pts)
            p = pts[p_idx]
            cl = _num_or_nan(p["cl"])
            cd = _num_or_nan(p["cd"])
            cm = _num_or_nan(p["cm"])
            if !(isfinite(cl) && isfinite(cd) && isfinite(cm))
                total += 1e6
                continue
            end
            total += (cl - refs[alpha]["CL"])^2
            total += (cd - refs[alpha]["CD"])^2
            total += (cm - refs[alpha]["CM"])^2
        end
        return total
    end

    blk = if length(candidate_idxs) == 1
        blocks[candidate_idxs[1]]
    else
        scores = [block_score(blocks[i]) for i in candidate_idxs]
        blocks[candidate_idxs[argmin(scores)]]
    end
    pts = blk["points"]

    function point_at_alpha(alpha::Float64)
        idx = argmin(begin
            a = _num_or_nan(p["alpha"])
            isfinite(a) ? abs(a - alpha) : Inf
        end for p in pts)
        return pts[idx]
    end

    per_point = Any[]
    dcl = Float64[]
    dcd = Float64[]
    dcm = Float64[]

    for alpha in sort(collect(keys(refs)))
        p = point_at_alpha(alpha)
        cl = _num_or_nan(p["cl"])
        cd = _num_or_nan(p["cd"])
        cm = _num_or_nan(p["cm"])
        ecl = isfinite(cl) ? cl - refs[alpha]["CL"] : NaN
        ecd = isfinite(cd) ? cd - refs[alpha]["CD"] : NaN
        ecm = isfinite(cm) ? cm - refs[alpha]["CM"] : NaN
        push!(dcl, ecl)
        push!(dcd, ecd)
        push!(dcm, ecm)
        push!(per_point, Dict(
            "alpha" => alpha,
            "cl_ref" => refs[alpha]["CL"],
            "cd_ref" => refs[alpha]["CD"],
            "cm_ref" => refs[alpha]["CM"],
            "cl_julia" => p["cl"],
            "cd_julia" => p["cd"],
            "cm_julia" => p["cm"],
            "dcl" => ecl,
            "dcd" => ecd,
            "dcm" => ecm,
        ))
    end

    finite_dcl = filter(isfinite, dcl)
    finite_dcd = filter(isfinite, dcd)
    finite_dcm = filter(isfinite, dcm)

    max_abs = Dict(
        "cl" => isempty(finite_dcl) ? Inf : maximum(abs.(finite_dcl)),
        "cd" => isempty(finite_dcd) ? Inf : maximum(abs.(finite_dcd)),
        "cm" => isempty(finite_dcm) ? Inf : maximum(abs.(finite_dcm)),
    )

    rms = Dict(
        "cl" => isempty(finite_dcl) ? Inf : sqrt(mean(finite_dcl .^ 2)),
        "cd" => isempty(finite_dcd) ? Inf : sqrt(mean(finite_dcd .^ 2)),
        "cm" => isempty(finite_dcm) ? Inf : sqrt(mean(finite_dcm .^ 2)),
    )

    return Dict(
        "mach_target" => mach,
        "mach_used" => blk["mach"],
        "max_abs" => max_abs,
        "rms" => rms,
        "per_point" => per_point,
    )
end

function failure_reasons(comp::Dict{String, Any}, has_surfaces::Bool)
    reasons = String[]
    max_abs = comp["max_abs"]

    if !isfinite(max_abs["cl"]) || !isfinite(max_abs["cd"]) || !isfinite(max_abs["cm"])
        push!(reasons, "Reference comparison hit non-finite values (likely NDM/unavailable method or parser mismatch).")
    end
    if max_abs["cl"] > 1e-6 || max_abs["cd"] > 1e-6 || max_abs["cm"] > 1e-6
        push!(reasons, "Legacy DATCOM backend differs from the static references; this usually means a parsing or case-association issue.")
    end
    isempty(reasons) && push!(reasons, "Exact match to DATCOM reference values within numerical precision.")
    return reasons
end

function main()
    fixtures = Dict(
        "ex1" => "tests/fixtures/ex1.inp",
        "ex2" => "tests/fixtures/ex2.inp",
        "ex3" => "tests/fixtures/ex3.inp",
        "ex4" => "tests/fixtures/ex4.inp",
    )

    all_runs = Dict{String, Any}()
    for (name, path) in fixtures
        all_runs[name] = run_fixture(path)
    end

    references = [
        Dict(
            "id" => "ex1_case1_m0p6",
            "fixture" => "ex1",
            "case_index" => 1,
            "mach" => 0.6,
            "refs" => Dict(
                0.0 => Dict("CL" => 0.000, "CD" => 0.021, "CM" => 0.0000),
                4.0 => Dict("CL" => 0.014, "CD" => 0.022, "CM" => 0.0137),
                8.0 => Dict("CL" => 0.027, "CD" => 0.025, "CM" => 0.0273),
                12.0 => Dict("CL" => 0.041, "CD" => 0.029, "CM" => 0.0410),
                16.0 => Dict("CL" => 0.055, "CD" => 0.036, "CM" => 0.0546),
            ),
        ),
        Dict(
            "id" => "ex2_case1_m0p6",
            "fixture" => "ex2",
            "case_index" => 1,
            "mach" => 0.6,
            "refs" => Dict(
                -6.0 => Dict("CL" => -0.087, "CD" => 0.007, "CM" => 0.0264),
                0.0 => Dict("CL" => 0.077, "CD" => 0.006, "CM" => -0.0344),
                4.0 => Dict("CL" => 0.196, "CD" => 0.016, "CM" => -0.0862),
                8.0 => Dict("CL" => 0.323, "CD" => 0.036, "CM" => -0.1419),
                12.0 => Dict("CL" => 0.440, "CD" => 0.062, "CM" => -0.1985),
                16.0 => Dict("CL" => 0.531, "CD" => 0.088, "CM" => -0.2508),
            ),
        ),
        Dict(
            "id" => "ex3_case1_m0p6",
            "fixture" => "ex3",
            "case_index" => 1,
            "mach" => 0.6,
            "refs" => Dict(
                -2.0 => Dict("CL" => -0.134, "CD" => 0.018, "CM" => 0.0228),
                0.0 => Dict("CL" => 0.000, "CD" => 0.016, "CM" => 0.0000),
                2.0 => Dict("CL" => 0.134, "CD" => 0.018, "CM" => -0.0239),
                4.0 => Dict("CL" => 0.270, "CD" => 0.026, "CM" => -0.0535),
                8.0 => Dict("CL" => 0.542, "CD" => 0.073, "CM" => -0.1228),
                12.0 => Dict("CL" => 0.804, "CD" => 0.160, "CM" => -0.1985),
            ),
        ),
        Dict(
            "id" => "ex4_case1_m0p6",
            "fixture" => "ex4",
            "case_index" => 1,
            "mach" => 0.6,
            "refs" => Dict(
                0.0 => Dict("CL" => 0.000, "CD" => 0.007, "CM" => 0.0000),
                5.0 => Dict("CL" => 0.306, "CD" => 0.020, "CM" => -0.0245),
                10.0 => Dict("CL" => 0.603, "CD" => 0.054, "CM" => -0.0440),
                15.0 => Dict("CL" => 0.793, "CD" => 0.091, "CM" => -0.0352),
                20.0 => Dict("CL" => 0.815, "CD" => 0.104, "CM" => 0.0128),
            ),
        ),
    ]

    case_diagnostics = Any[]
    for (fixture, payload) in all_runs
        for case_data in payload["cases"]
            push!(case_diagnostics, Dict(
                "fixture" => fixture,
                "case_index" => case_data["case_index"],
                "case_id" => case_data["case_id"],
                "has_surfaces" => case_data["has_surfaces"],
                "diagnostics" => diagnose_case(case_data),
            ))
        end
    end

    ref_reports = Any[]
    for ref in references
        fixture = ref["fixture"]
        case_data = all_runs[fixture]["cases"][ref["case_index"]]
        comp = ref_comparison(case_data, ref["mach"], ref["refs"])
        reasons = failure_reasons(comp, case_data["has_surfaces"])
        status = (comp["max_abs"]["cl"] <= 1e-6 && comp["max_abs"]["cd"] <= 1e-6 && comp["max_abs"]["cm"] <= 1e-6) ? "pass" : "fail"
        push!(ref_reports, Dict(
            "id" => ref["id"],
            "fixture" => fixture,
            "case_index" => ref["case_index"],
            "case_id" => case_data["case_id"],
            "status" => status,
            "comparison" => comp,
            "diagnostic_reasons" => reasons,
        ))
    end

    summary = Dict(
        "fixtures_run" => collect(keys(fixtures)),
        "total_cases_run" => sum(all_runs[k]["num_cases"] for k in keys(all_runs)),
        "reference_cases_compared" => length(ref_reports),
        "reference_failures" => count(r -> r["status"] == "fail", ref_reports),
    )

    report = Dict(
        "summary" => summary,
        "case_diagnostics" => case_diagnostics,
        "reference_validation" => ref_reports,
    )

    json_path = "JDATCOM/validation/full_validation_report.json"
    open(json_path, "w") do io
        JSON3.pretty(io, _sanitize_json(report))
    end

    md_path = "JDATCOM/validation/full_validation_report.md"
    open(md_path, "w") do io
        println(io, "# JDATCOM Validation Report")
        println(io)
        println(io, "- Total cases run: ", summary["total_cases_run"])
        println(io, "- Reference cases compared: ", summary["reference_cases_compared"])
        println(io, "- Reference failures (configured thresholds): ", summary["reference_failures"])
        println(io)
        println(io, "## Reference Comparison Results")
        println(io)
        println(io, "| ID | Status | max |dCL| | max |dCD| | max |dCm| |")
        println(io, "|---|---:|---:|---:|---:|")
        for r in ref_reports
            m = r["comparison"]["max_abs"]
            println(io, "| ", r["id"], " | ", r["status"], " | ",
                round(m["cl"], sigdigits = 5), " | ",
                round(m["cd"], sigdigits = 5), " | ",
                round(m["cm"], sigdigits = 5), " |")
        end
        println(io)
        println(io, "## Failure Diagnostics")
        println(io)
        for r in ref_reports
            if r["status"] == "fail"
                println(io, "### ", r["id"])
                for msg in r["diagnostic_reasons"]
                    println(io, "- ", msg)
                end
                println(io)
            end
        end
        println(io, "## Case Execution Diagnostics")
        println(io)
        println(io, "| Fixture | Case | Finite | CD>0 | Regime OK | Low-alpha CL monotonic |")
        println(io, "|---|---:|---:|---:|---:|---:|")
        for c in case_diagnostics
            d = c["diagnostics"]
            println(io, "| ", c["fixture"], " | ", c["case_index"], " | ",
                d["finite_ok"], " | ", d["cd_positive"], " | ",
                d["regime_consistent"], " | ", d["low_alpha_cl_monotonic"], " |")
        end
    end

    println("Wrote: ", json_path)
    println("Wrote: ", md_path)
end

main()
