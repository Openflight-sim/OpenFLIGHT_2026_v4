#!/usr/bin/env julia
# ──────────────────────────────────────────────────────────────
# test_all_cases.jl — Comprehensive validation of Julia AVL solver
#                     against Fortran AVL 3.52 reference
# ──────────────────────────────────────────────────────────────
push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))
include(joinpath(@__DIR__, "..", "src", "AVL.jl"))
using .AVL
using Printf

const RUNS_DIR = joinpath(@__DIR__, "..", "validation", "cases")
const AVL_EXE = joinpath(@__DIR__, "..", "validation", "reference", "avl3.51-32.exe")
const ALPHA_DEG = 5.0

# Collect all .avl files (skip ._ macOS resource forks)
avl_files = sort([f for f in readdir(RUNS_DIR)
                  if endswith(f, ".avl") && !startswith(f, "._")])

println("=" ^ 80)
println("  Julia AVL Solver — Full Validation Report")
println("  $(length(avl_files)) test cases at alpha = $(ALPHA_DEG)°")
println("=" ^ 80)

# ─── Phase 1: Run Julia solver on all cases ──────────────────
struct CaseResult
    name::String
    parsed::Bool
    built::Bool
    solved::Bool
    nvor::Int
    nstrip::Int
    nsurf::Int
    cl::Float64
    cd::Float64
    cm::Float64
    clff::Float64
    cdff::Float64
    spanef::Float64
    error_msg::String
end

julia_results = Dict{String, CaseResult}()

println("\n── Phase 1: Julia Solver ──")
for avl_file in avl_files
    name = replace(avl_file, ".avl" => "")
    filepath = joinpath(RUNS_DIR, avl_file)

    parsed = false; built = false; solved = false
    nvor = 0; nstrip = 0; nsurf = 0
    cl = 0.0; cd = 0.0; cm = 0.0
    clff = 0.0; cdff = 0.0; spanef = 0.0
    error_msg = ""

    try
        config = AVL.read_avl(filepath)
        parsed = true

        vl = AVL.build_lattice(config)
        built = true
        nvor = vl.nvor; nstrip = vl.nstrip; nsurf = vl.nsurf

        if nvor == 0 && isempty(config.bodies)
            error_msg = "empty lattice (0 vortices, no bodies)"
        elseif nvor == 0 && !isempty(config.bodies)
            # body-only case: no vortex lattice, only body forces
            sol = AVL.AVLSolution(0, 0, 0)
            sol.alpha = deg2rad(ALPHA_DEG)
            vinf, _, _ = AVL.vinfab(sol.alpha, 0.0)
            sol.vinf = vinf
            sol.wrot = (0.0, 0.0, 0.0)

            AVL.makebody!(vl, config)
            if vl.nbody > 0
                src_u, dbl_u = AVL.srdset(vl, config)
                src = AVL.compute_body_src(src_u, vinf, sol.wrot)
                AVL.body_forces!(sol, vl, config, src, src_u)
            end
            sol.cd += config.cdref

            solved = true
            cl = sol.cl; cd = sol.cd; cm = sol.cmy
            clff = sol.clff; cdff = sol.cdff; spanef = sol.spanef
        else
            # body source model
            local src_u_kw = nothing
            local wcsrd_u = nothing
            local wvsrd_u_kw = nothing
            if !isempty(config.bodies)
                _src_u, _dbl_u, _wcsrd_u, _wvsrd_u = AVL.setup_body!(vl, config)
                src_u_kw = size(_src_u, 1) > 0 ? _src_u : nothing
                wcsrd_u = size(_wcsrd_u, 2) > 0 ? _wcsrd_u : nothing
                wvsrd_u_kw = size(_wvsrd_u, 2) > 0 ? _wvsrd_u : nothing
            end

            aic = AVL.setup_aic(vl, config)
            gam_u0, gam_u_d = AVL.solve_unit_rhs(vl, config, aic; wcsrd_u=wcsrd_u)

            sol = AVL.AVLSolution(vl.nvor, vl.ncontrol, vl.nstrip)
            rc = AVL.RunCase(vl.ncontrol)
            rc.icon[AVL.IVALFA] = AVL.ICALFA
            rc.conval[AVL.ICALFA] = deg2rad(ALPHA_DEG)
            AVL.exec_case!(sol, vl, config, aic, gam_u0, gam_u_d, rc;
                           src_u=src_u_kw, wvsrd_u=wvsrd_u_kw)

            solved = true
            cl = sol.cl; cd = sol.cd; cm = sol.cmy
            clff = sol.clff; cdff = sol.cdff; spanef = sol.spanef
        end
    catch e
        error_msg = sprint(showerror, e)
        # truncate long error messages
        if length(error_msg) > 120
            error_msg = error_msg[1:120] * "..."
        end
    end

    julia_results[name] = CaseResult(name, parsed, built, solved,
                                      nvor, nstrip, nsurf,
                                      cl, cd, cm, clff, cdff, spanef,
                                      error_msg)

    status = solved ? "OK" : (built ? "SOLVE_FAIL" : (parsed ? "BUILD_FAIL" : "PARSE_FAIL"))
    if solved
        @printf("  %-25s %s  nv=%3d  CL=%+8.5f  CDff=%8.5f  Cm=%+8.5f\n",
                name, status, nvor, cl, cdff, cm)
    else
        @printf("  %-25s %s  %s\n", name, status, error_msg[1:min(60,length(error_msg))])
    end
end

n_parsed = count(r -> r.parsed, values(julia_results))
n_built  = count(r -> r.built, values(julia_results))
n_solved = count(r -> r.solved, values(julia_results))
println("\nJulia: $(n_parsed)/$(length(avl_files)) parsed, $(n_built) built, $(n_solved) solved")

# ─── Phase 2: Run Fortran AVL on solved cases ───────────────
println("\n── Phase 2: Fortran AVL Reference ──")

struct AVLRefResult
    cl::Float64
    cd::Float64
    cm::Float64
    clff::Float64
    cdff::Float64
    spanef::Float64
    ok::Bool
end

avl_ref = Dict{String, AVLRefResult}()

solved_names = sort([r.name for r in values(julia_results) if r.solved])

# Read pre-generated AVL reference data from CSV
avl_csv = joinpath(@__DIR__, "avl_reference.csv")
if isfile(avl_csv)
    for line in readlines(avl_csv)
        startswith(line, "#") && continue
        isempty(strip(line)) && continue
        parts = split(line, ",")
        length(parts) < 7 && continue
        name = strip(parts[1])
        name in solved_names || continue
        try
            cl   = parse(Float64, parts[2])
            cd   = parse(Float64, parts[3])
            cm   = parse(Float64, parts[4])
            clff = parse(Float64, parts[5])
            cdff = parse(Float64, parts[6])
            e    = parse(Float64, parts[7])
            avl_ref[name] = AVLRefResult(cl, cd, cm, clff, cdff, e, true)
            @printf("  %-25s OK   CL=%+8.5f  CDff=%8.5f  Cm=%+8.5f\n", name, cl, cdff, cm)
        catch
            @printf("  %-25s FAIL (parse error)\n", name)
        end
    end
else
    println("  WARNING: avl_reference.csv not found!")
    println("  Run generate_avl_reference.sh first:")
    println("    cd JULIA_AVL/test && bash generate_avl_reference.sh")
end

n_avl_ok = count(r -> r.ok, values(avl_ref))
println("\nAVL reference: $(n_avl_ok)/$(length(solved_names)) successful")

# ─── Phase 3: Comparison Report ─────────────────────────────
println("\n" * "=" ^ 80)
println("  COMPARISON REPORT")
println("=" ^ 80)

# Header
@printf("\n%-20s │ %10s %10s │ %10s %10s │ %8s %8s │ %7s\n",
        "Case", "CL_julia", "CL_avl", "CDff_jul", "CDff_avl", "Cm_jul", "Cm_avl", "CL_err%")
println("─" ^ 20, "─┼─", "─" ^ 10, "─", "─" ^ 10, "─┼─", "─" ^ 10, "─", "─" ^ 10,
        "─┼─", "─" ^ 8, "─", "─" ^ 8, "─┼─", "─" ^ 7)

cl_errors = Float64[]
cdff_errors = Float64[]
cm_errors = Float64[]

for name in solved_names
    jr = julia_results[name]
    haskey(avl_ref, name) || continue
    ar = avl_ref[name]
    !ar.ok && continue

    # CL error
    cl_err = abs(jr.cl) > 1e-6 ? 100.0 * (jr.cl - ar.cl) / max(abs(ar.cl), 1e-10) : 0.0
    cdff_err = abs(ar.cdff) > 1e-8 ? 100.0 * (jr.cdff - ar.cdff) / max(abs(ar.cdff), 1e-10) : 0.0
    cm_err = abs(ar.cm) > 1e-6 ? 100.0 * (jr.cm - ar.cm) / max(abs(ar.cm), 1e-10) : 0.0

    push!(cl_errors, cl_err)
    push!(cdff_errors, cdff_err)
    push!(cm_errors, cm_err)

    @printf("%-20s │ %+10.5f %+10.5f │ %10.6f %10.6f │ %+8.4f %+8.4f │ %+6.2f%%\n",
            name, jr.cl, ar.cl, jr.cdff, ar.cdff, jr.cm, ar.cm, cl_err)
end

# Summary statistics
println("\n" * "=" ^ 80)
println("  SUMMARY STATISTICS")
println("=" ^ 80)

n_compared = length(cl_errors)
println("\nCases compared: $n_compared / $(length(avl_files)) total files")
println("  Parsed: $n_parsed / $(length(avl_files))")
println("  Built:  $n_built / $(length(avl_files))")
println("  Solved: $n_solved / $(length(avl_files))")
println("  AVL OK: $n_avl_ok / $n_solved")

if n_compared > 0
    abs_cl = abs.(cl_errors)
    abs_cdff = abs.(cdff_errors)
    abs_cm = abs.(cm_errors)

    @printf("\nCL error:   mean=%5.2f%%  max=%5.2f%%  median=%5.2f%%\n",
            sum(abs_cl)/length(abs_cl), maximum(abs_cl), sort(abs_cl)[div(length(abs_cl),2)+1])
    @printf("CDff error: mean=%5.2f%%  max=%5.2f%%  median=%5.2f%%\n",
            sum(abs_cdff)/length(abs_cdff), maximum(abs_cdff), sort(abs_cdff)[div(length(abs_cdff),2)+1])
    @printf("Cm error:   mean=%5.2f%%  max=%5.2f%%  median=%5.2f%%\n",
            sum(abs_cm)/length(abs_cm), maximum(abs_cm), sort(abs_cm)[div(length(abs_cm),2)+1])

    # Count cases within thresholds
    n1 = count(x -> x < 1.0, abs_cl)
    n5 = count(x -> x < 5.0, abs_cl)
    println("\nCL within 1%: $n1/$n_compared")
    println("CL within 5%: $n5/$n_compared")
end

# List failures
parse_fails = sort([r.name for r in values(julia_results) if !r.parsed])
build_fails = sort([r.name for r in values(julia_results) if r.parsed && !r.built])
solve_fails = sort([r.name for r in values(julia_results) if r.built && !r.solved])

if !isempty(parse_fails)
    println("\n── Parse Failures ──")
    for name in parse_fails
        @printf("  %-25s %s\n", name, julia_results[name].error_msg[1:min(70,length(julia_results[name].error_msg))])
    end
end

if !isempty(build_fails)
    println("\n── Build Failures ──")
    for name in build_fails
        @printf("  %-25s %s\n", name, julia_results[name].error_msg[1:min(70,length(julia_results[name].error_msg))])
    end
end

if !isempty(solve_fails)
    println("\n── Solve Failures ──")
    for name in solve_fails
        @printf("  %-25s %s\n", name, julia_results[name].error_msg[1:min(70,length(julia_results[name].error_msg))])
    end
end

# Worst cases (> 5% CL error)
if n_compared > 0
    println("\n── Cases with > 5% CL error ──")
    worst = [(name, cl_errors[i]) for (i, name) in enumerate(
                [n for n in solved_names if haskey(avl_ref, n) && avl_ref[n].ok])
             if abs(cl_errors[i]) > 5.0]
    if isempty(worst)
        println("  None! All cases within 5%.")
    else
        sort!(worst, by=x -> abs(x[2]), rev=true)
        for (name, err) in worst
            jr = julia_results[name]
            ar = avl_ref[name]
            @printf("  %-25s CL: %.5f vs %.5f  (%.1f%%)\n", name, jr.cl, ar.cl, err)
        end
    end
end

println("\n" * "=" ^ 80)
println("  Validation complete.")
println("=" ^ 80)
