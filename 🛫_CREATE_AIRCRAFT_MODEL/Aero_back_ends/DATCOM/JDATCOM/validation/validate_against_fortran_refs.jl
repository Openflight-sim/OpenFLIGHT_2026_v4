#!/usr/bin/env julia

using JSON3
using JDATCOM

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

function eval_reference_set(name::String, input_path::String, case_idx::Int, mach::Float64, refs::Dict{Float64, Dict{String, Float64}})
    payload = run_fixture_legacy(input_path)
    case_data = payload["cases"][case_idx]
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
    raw_points = blk["points"]

    println("\n", name)
    println("  Mach = ", mach, ", case index = ", case_idx)
    println("  ", rpad("alpha", 8), rpad("CL err", 14), rpad("CD err", 14), "Cm err")

    max_abs = Dict("cl" => 0.0, "cd" => 0.0, "cm" => 0.0)
    result_points = Any[]

    for alpha in sort(collect(keys(refs)))
        p_idx = argmin(begin
            a = _num_or_nan(p["alpha"])
            isfinite(a) ? abs(a - alpha) : Inf
        end for p in raw_points)
        p = raw_points[p_idx]
        dcl = _num_or_nan(p["cl"]) - refs[alpha]["CL"]
        dcd = _num_or_nan(p["cd"]) - refs[alpha]["CD"]
        dcm = _num_or_nan(p["cm"]) - refs[alpha]["CM"]
        max_abs["cl"] = max(max_abs["cl"], abs(dcl))
        max_abs["cd"] = max(max_abs["cd"], abs(dcd))
        max_abs["cm"] = max(max_abs["cm"], abs(dcm))

        println("  ", lpad(alpha, 6), "  ", lpad(round(dcl, sigdigits = 6), 12), "  ", lpad(round(dcd, sigdigits = 6), 12), "  ", lpad(round(dcm, sigdigits = 6), 12))
        push!(result_points, Dict(
            "alpha" => alpha,
            "cl_ref" => refs[alpha]["CL"],
            "cd_ref" => refs[alpha]["CD"],
            "cm_ref" => refs[alpha]["CM"],
            "cl_julia" => p["cl"],
            "cd_julia" => p["cd"],
            "cm_julia" => p["cm"],
            "dcl" => dcl,
            "dcd" => dcd,
            "dcm" => dcm,
        ))
    end

    return Dict(
        "name" => name,
        "input" => input_path,
        "case_idx" => case_idx,
        "mach" => mach,
        "max_abs" => max_abs,
        "points" => result_points,
    )
end

function main()
    reports = Any[]

    ex1_refs = Dict(
        0.0 => Dict("CL" => 0.000, "CD" => 0.021, "CM" => 0.0000),
        4.0 => Dict("CL" => 0.014, "CD" => 0.022, "CM" => 0.0137),
        8.0 => Dict("CL" => 0.027, "CD" => 0.025, "CM" => 0.0273),
        12.0 => Dict("CL" => 0.041, "CD" => 0.029, "CM" => 0.0410),
        16.0 => Dict("CL" => 0.055, "CD" => 0.036, "CM" => 0.0546),
    )
    push!(reports, eval_reference_set("EX1 Case 1 (Body Alone)", "tests/fixtures/ex1.inp", 1, 0.6, ex1_refs))

    ex2_refs = Dict(
        -6.0 => Dict("CL" => -0.087, "CD" => 0.007, "CM" => 0.0264),
        0.0 => Dict("CL" => 0.077, "CD" => 0.006, "CM" => -0.0344),
        4.0 => Dict("CL" => 0.196, "CD" => 0.016, "CM" => -0.0862),
        8.0 => Dict("CL" => 0.323, "CD" => 0.036, "CM" => -0.1419),
        12.0 => Dict("CL" => 0.440, "CD" => 0.062, "CM" => -0.1985),
        16.0 => Dict("CL" => 0.531, "CD" => 0.088, "CM" => -0.2508),
    )
    push!(reports, eval_reference_set("EX2 Case 1 (Wing)", "tests/fixtures/ex2.inp", 1, 0.6, ex2_refs))

    ex3_refs = Dict(
        -2.0 => Dict("CL" => -0.134, "CD" => 0.018, "CM" => 0.0228),
        0.0 => Dict("CL" => 0.000, "CD" => 0.016, "CM" => 0.0000),
        2.0 => Dict("CL" => 0.134, "CD" => 0.018, "CM" => -0.0239),
        4.0 => Dict("CL" => 0.270, "CD" => 0.026, "CM" => -0.0535),
        8.0 => Dict("CL" => 0.542, "CD" => 0.073, "CM" => -0.1228),
        12.0 => Dict("CL" => 0.804, "CD" => 0.160, "CM" => -0.1985),
    )
    push!(reports, eval_reference_set("EX3 Case 1 (Full Config)", "tests/fixtures/ex3.inp", 1, 0.6, ex3_refs))

    ex4_refs = Dict(
        0.0 => Dict("CL" => 0.000, "CD" => 0.007, "CM" => 0.0000),
        5.0 => Dict("CL" => 0.306, "CD" => 0.020, "CM" => -0.0245),
        10.0 => Dict("CL" => 0.603, "CD" => 0.054, "CM" => -0.0440),
        15.0 => Dict("CL" => 0.793, "CD" => 0.091, "CM" => -0.0352),
        20.0 => Dict("CL" => 0.815, "CD" => 0.104, "CM" => 0.0128),
    )
    push!(reports, eval_reference_set("EX4 Case 1 (Canard)", "tests/fixtures/ex4.inp", 1, 0.6, ex4_refs))

    out_path = "JDATCOM/validation/fortran_reference_report.json"
    open(out_path, "w") do io
        JSON3.pretty(io, _sanitize_json(Dict("reports" => reports)))
    end
    println("\nWrote: ", out_path)
end

main()
