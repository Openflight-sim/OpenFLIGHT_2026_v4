#!/usr/bin/env julia

using Random
using Printf

function fmt(x::Real; digits::Int = 4)
    return @sprintf("%.*f", digits, float(x))
end

function fmt_list(vals::AbstractVector{<:Real}; digits::Int = 4)
    return join((fmt(v; digits = digits) for v in vals), ",")
end

function body_profile(length_ft::Float64, radius_ft::Float64; nx::Int = 9)
    x = collect(range(0.0, length_ft, length = nx))
    r = [radius_ft * max(sin(π * xi / length_ft), 0.0)^0.85 for xi in x]
    r[1] = 0.0
    r[end] = 0.0
    s = [π * ri^2 for ri in r]
    p = [2π * ri for ri in r]
    return x, r, s, p
end

function write_body(io, length_ft::Float64, radius_ft::Float64)
    x, r, s, p = body_profile(length_ft, radius_ft)
    println(io, " \$BODY NX=$(length(x)).0,")
    println(io, "   X(1)=" * fmt_list(x; digits = 3) * ",")
    println(io, "   R(1)=" * fmt_list(r; digits = 3) * ",")
    println(io, "   S(1)=" * fmt_list(s; digits = 4) * ",")
    println(io, "   P(1)=" * fmt_list(p; digits = 4) * "\$")
    println(io, " \$BODY BNOSE=2.0, BTAIL=1.0, BLN=" * fmt(0.30 * length_ft; digits = 3) * ", BLA=" * fmt(0.22 * length_ft; digits = 3) * "\$")
end

function write_fltcon(io, machs::Vector{Float64}, alphas::Vector{Float64}, reynolds::Vector{Float64})
    println(io, " \$FLTCON NMACH=$(length(machs)).0, MACH(1)=" * fmt_list(machs; digits = 3) * ",")
    println(io, "   NALPHA=$(length(alphas)).0, ALSCHD(1)=" * fmt_list(alphas; digits = 2) * ",")
    println(io, "   RNNUB(1)=" * fmt_list(reynolds; digits = 1) * "\$")
end

function write_optins(io, sref::Float64, cbar::Float64, bref::Float64)
    println(io, " \$OPTINS SREF=" * fmt(sref; digits = 4) * ", CBARR=" * fmt(cbar; digits = 4) * ", BLREF=" * fmt(bref; digits = 4) * "\$")
end

function write_synths(io; xcg::Float64, xw::Union{Nothing, Float64} = nothing, xh::Union{Nothing, Float64} = nothing, xv::Union{Nothing, Float64} = nothing)
    fields = ["XCG=" * fmt(xcg; digits = 4), "ZCG=0.0"]
    if xw !== nothing
        push!(fields, "XW=" * fmt(xw; digits = 4))
        push!(fields, "ZW=0.0")
        push!(fields, "ALIW=0.0")
    end
    if xh !== nothing
        push!(fields, "XH=" * fmt(xh; digits = 4))
        push!(fields, "ZH=0.0")
        push!(fields, "ALIH=0.0")
    end
    if xv !== nothing
        push!(fields, "XV=" * fmt(xv; digits = 4))
        push!(fields, "VERTUP=.TRUE.")
    end
    println(io, " \$SYNTHS " * join(fields, ", ") * "\$")
end

function write_wing(io, cr::Float64, ct::Float64, sspn::Float64, sweep::Float64; cmo::Float64 = -0.02)
    println(io, " \$WGPLNF CHRDTP=" * fmt(ct; digits = 4) * ", SSPNE=" * fmt(sspn; digits = 4) *
            ", SSPN=" * fmt(sspn; digits = 4) * ", CHRDR=" * fmt(cr; digits = 4) *
            ", SAVSI=" * fmt(sweep; digits = 2) * ", CHSTAT=0.0, SWAFP=0.0, TWISTA=0.0, SSPNDD=0.0, DHDADI=0.0, DHDADO=0.0, TYPE=1.0\$")
    println(io, " \$WGSCHR TOVC=0.10, DELTAY=" * fmt(max(sspn - 0.05, 0.20); digits = 3) *
            ", XOVC=0.4, CLI=0.0, ALPHAI=0.0, CLALPA(1)=0.11, CLMAX(1)=1.25, CMO=" * fmt(cmo; digits = 4) *
            ", LERI=0.01, CAMBER=.FALSE., CLAMO=0.10\$")
end

function write_htail(io, cr::Float64, ct::Float64, sspn::Float64, sweep::Float64)
    println(io, " \$HTPLNF CHRDTP=" * fmt(ct; digits = 4) * ", SSPNE=" * fmt(sspn; digits = 4) *
            ", SSPN=" * fmt(sspn; digits = 4) * ", CHRDR=" * fmt(cr; digits = 4) *
            ", SAVSI=" * fmt(sweep; digits = 2) * ", CHSTAT=0.0, SWAFP=0.0, TWISTA=0.0, SSPNDD=0.0, DHDADI=0.0, DHDADO=0.0, TYPE=1.0\$")
    println(io, " \$HTSCHR TOVC=0.08, DELTAY=" * fmt(max(sspn - 0.05, 0.20); digits = 3) *
            ", XOVC=0.4, CLI=0.0, ALPHAI=0.0, CLALPA(1)=0.10, CLMAX(1)=1.10, CMO=0.0, LERI=0.01, CLAMO=0.10\$")
end

function write_vtail(io, cr::Float64, ct::Float64, sspn::Float64, sweep::Float64)
    println(io, " \$VTPLNF CHRDTP=" * fmt(ct; digits = 4) * ", SSPNE=" * fmt(sspn; digits = 4) *
            ", SSPN=" * fmt(sspn; digits = 4) * ", CHRDR=" * fmt(cr; digits = 4) *
            ", SAVSI=" * fmt(sweep; digits = 2) * ", CHSTAT=0.0, SWAFP=0.0, TWISTA=0.0, TYPE=0.0\$")
    println(io, " \$VTSCHR TOVC=0.09, XOVC=0.4, CLALPA(1)=0.10, LERI=0.01\$")
end

function write_case_footer(io, id::String)
    println(io, "CASEID " * id)
    println(io, "NEXT CASE")
end

function generate_cases(output_path::String; seed::Int = 42)
    rng = MersenneTwister(seed)
    alphas = [-4.0, -2.0, 0.0, 2.0, 4.0, 8.0, 12.0]
    mach_sub = [0.40, 0.80]
    mach_mix = [0.60, 0.95, 1.40, 2.20]

    open(output_path, "w") do io
        println(io, "BUILD")

        # Body-only cases.
        for i in 1:6
            l = rand(rng, 5.5:0.5:12.0)
            rmax = rand(rng, 0.45:0.05:1.10)
            sref = π * rmax^2 * rand(rng, 7.0:0.5:10.0)
            cbar = rand(rng, 1.5:0.1:3.5)
            bref = rand(rng, 3.0:0.2:6.0)
            xcg = 0.52 * l
            reynolds = [rand(rng, 2.5e6:2.5e5:8.0e6) for _ in 1:length(mach_sub)]

            write_fltcon(io, mach_sub, alphas, reynolds)
            write_optins(io, sref, cbar, bref)
            write_synths(io; xcg = xcg)
            write_body(io, l, rmax)
            write_case_footer(io, "AUTO BODY CASE $i")
        end

        # Wing-only cases.
        for i in 1:6
            cr = rand(rng, 1.6:0.1:4.0)
            taper = rand(rng, 0.20:0.05:0.70)
            ct = taper * cr
            sspn = rand(rng, 1.2:0.1:4.2)
            sweep = rand(rng, 15.0:2.5:65.0)
            span = 2.0 * sspn
            sref = span * (cr + ct) / 2.0
            cbar = (2.0 / 3.0) * cr * (1.0 + taper + taper^2) / (1.0 + taper)
            xw = rand(rng, 2.0:0.2:6.0)
            xcg = xw + 0.35 * cbar
            reynolds = [rand(rng, 1.5e6:2.5e5:9.0e6) for _ in 1:length(mach_mix)]

            write_fltcon(io, mach_mix, alphas, reynolds)
            write_optins(io, sref, cbar, span)
            write_synths(io; xcg = xcg, xw = xw)
            write_wing(io, cr, ct, sspn, sweep; cmo = -0.02)
            write_case_footer(io, "AUTO WING CASE $i")
        end

        # Full configuration cases.
        for i in 1:6
            l = rand(rng, 8.0:0.5:16.0)
            rmax = rand(rng, 0.55:0.05:1.30)
            cr = rand(rng, 1.8:0.1:4.4)
            taper = rand(rng, 0.25:0.05:0.65)
            ct = taper * cr
            sspn = rand(rng, 1.4:0.1:4.4)
            sweep = rand(rng, 20.0:2.5:60.0)
            span = 2.0 * sspn
            sref = span * (cr + ct) / 2.0
            cbar = (2.0 / 3.0) * cr * (1.0 + taper + taper^2) / (1.0 + taper)
            xw = 0.35 * l
            xh = 0.78 * l
            xv = 0.72 * l
            xcg = 0.52 * l
            reynolds = [rand(rng, 2.0e6:2.5e5:1.0e7) for _ in 1:length(mach_mix)]

            write_fltcon(io, mach_mix, alphas, reynolds)
            write_optins(io, sref, cbar, span)
            write_synths(io; xcg = xcg, xw = xw, xh = xh, xv = xv)
            write_body(io, l, rmax)
            write_wing(io, cr, ct, sspn, sweep; cmo = -0.01)
            write_htail(io, 0.45 * cr, 0.35 * ct, 0.55 * sspn, sweep - 5.0)
            write_vtail(io, 0.55 * cr, 0.45 * ct, 0.45 * sspn, sweep + 8.0)
            write_case_footer(io, "AUTO FULL CONFIG CASE $i")
        end

        # Canard cases.
        for i in 1:2
            l = rand(rng, 10.0:0.5:18.0)
            rmax = rand(rng, 0.65:0.05:1.40)
            cr = rand(rng, 2.2:0.1:5.0)
            taper = rand(rng, 0.25:0.05:0.60)
            ct = taper * cr
            sspn = rand(rng, 2.0:0.1:5.0)
            sweep = rand(rng, 25.0:2.5:55.0)
            span = 2.0 * sspn
            sref = span * (cr + ct) / 2.0
            cbar = (2.0 / 3.0) * cr * (1.0 + taper + taper^2) / (1.0 + taper)
            xw = 0.46 * l
            xh = 0.24 * l  # Canard ahead of wing.
            xcg = 0.58 * l
            reynolds = [rand(rng, 2.0e6:2.5e5:9.0e6) for _ in 1:length(mach_mix)]

            write_fltcon(io, mach_mix, alphas, reynolds)
            write_optins(io, sref, cbar, span)
            write_synths(io; xcg = xcg, xw = xw, xh = xh)
            write_body(io, l, rmax)
            write_wing(io, cr, ct, sspn, sweep; cmo = -0.015)
            write_htail(io, 0.55 * cr, 0.40 * ct, 0.50 * sspn, sweep - 10.0)
            write_case_footer(io, "AUTO CANARD CASE $i")
        end
    end
end

function main()
    out_path = length(ARGS) >= 1 ? ARGS[1] : joinpath("JDATCOM", "validation", "cases", "generated_suite.inp")
    seed = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 42
    mkpath(dirname(out_path))
    generate_cases(out_path; seed = seed)
    println("Wrote: $out_path")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
