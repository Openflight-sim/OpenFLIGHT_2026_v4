# ──────────────────────────────────────────────────────────────
# output.jl — Output routines (matching AVL's aoutput.f)
# ──────────────────────────────────────────────────────────────

"""
    print_total_forces(io, sol, vl, config)

Print total force and moment summary (equivalent to AVL's FT command).
"""
function print_total_forces(io::IO, sol::AVLSolution, vl::VortexLattice, config::AVLConfig)
    println(io, "")
    println(io, " ---------------------------------------------------------------")
    println(io, " Vortex Lattice Output -- Total Forces")
    println(io, "")
    println(io, " Configuration: ", config.title)
    println(io, "")
    @printf(io, "   # Surfaces = %4d\n", vl.nsurf)
    @printf(io, "   # Strips   = %4d\n", vl.nstrip)
    @printf(io, "   # Vortices  = %4d\n", vl.nvor)
    println(io, "")
    @printf(io, "   Sref = %10.4f    Cref = %10.4f    Bref = %10.4f\n",
            config.sref, config.cref, config.bref)
    @printf(io, "   Xref = %10.4f    Yref = %10.4f    Zref = %10.4f\n",
            config.xyzref[1], config.xyzref[2], config.xyzref[3])
    println(io, "")
    println(io, " Standard axis orientation:  X fwd, Y right, Z up")
    println(io, "")
    @printf(io, " Run case: %s\n", "")
    println(io, "")
    @printf(io, "  Alpha = %10.5f deg     pb/2V = %10.6f\n",
            rad2deg(sol.alpha), sol.wrot[1]*config.bref/2.0)
    @printf(io, "  Beta  = %10.5f deg     qc/2V = %10.6f\n",
            rad2deg(sol.beta), sol.wrot[2]*config.cref/2.0)
    @printf(io, "  Mach  = %10.4f         rb/2V = %10.6f\n",
            sol.mach, sol.wrot[3]*config.bref/2.0)
    println(io, "")

    @printf(io, "  CXtot = %12.6f      Cltot = %12.6f     Cl'tot = %12.6f\n",
            sol.cfx, sol.cmx, sol.cmx_s)
    @printf(io, "  CYtot = %12.6f      Cmtot = %12.6f\n", sol.cfy, sol.cmy)
    @printf(io, "  CZtot = %12.6f      Cntot = %12.6f     Cn'tot = %12.6f\n",
            sol.cfz, sol.cmz, sol.cmz_s)
    println(io, "")

    @printf(io, "  CLtot = %12.6f\n", sol.cl)
    @printf(io, "  CDtot = %12.6f\n", sol.cd)
    @printf(io, "  CDvis = %12.6f     CDind = %12.6f\n", sol.cdv, sol.cdi)
    println(io, "")

    @printf(io, "  CLff  = %12.6f     CDff  = %12.6f    | Trefftz\n", sol.clff, sol.cdff)
    @printf(io, "  CYff  = %12.6f         e = %12.6f    | Plane\n", sol.cyff, sol.spanef)
    println(io, "")

    if vl.ncontrol > 0
        println(io, " Control deflections:")
        for n in 1:vl.ncontrol
            defl = n <= length(sol.delcon) ? rad2deg(sol.delcon[n]) : 0.0
            @printf(io, "   %-12s = %10.5f deg\n", vl.control_names[n], defl)
        end
        println(io, "")
    end

    println(io, " ---------------------------------------------------------------")
end

"""
    print_strip_forces(io, sol, vl, config)

Print per-strip force distribution (equivalent to AVL's FS command).
"""
function print_strip_forces(io::IO, sol::AVLSolution, vl::VortexLattice, config::AVLConfig)
    println(io, "")
    println(io, " ---------------------------------------------------------------")
    println(io, " Surface and Strip Forces (Trefftz Plane Projections)")
    println(io, "")

    for is in 1:vl.nsurf
        println(io, " Surface: ", vl.surf_names[is])
        @printf(io, " # Strips = %d,  # Chordwise = %d\n", vl.surf_nj[is], vl.surf_nk[is])
        println(io, "")
        @printf(io, "  %4s  %10s  %10s  %10s  %10s  %10s  %10s  %10s\n",
                "j", "Yle", "Chord", "Area", "c*cl", "ai", "cl_norm", "cl")
        println(io, " ", "-"^90)

        jfirst = vl.surf_jfrst[is]
        nj = vl.surf_nj[is]
        for j in jfirst:(jfirst+nj-1)
            j > vl.nstrip && break
            strip = vl.strips[j]
            cnc = j <= length(sol.strip_cnc) ? sol.strip_cnc[j] : 0.0
            cl_s = j <= length(sol.strip_cl) ? sol.strip_cl[j] : 0.0
            dw = j <= length(sol.strip_dwwake) ? sol.strip_dwwake[j] : 0.0
            area = strip.wstrip * strip.chord
            ai = rad2deg(atan(dw))

            @printf(io, "  %4d  %10.4f  %10.4f  %10.4f  %10.6f  %10.4f  %10.6f  %10.6f\n",
                    j - jfirst + 1, strip.rle[2], strip.chord, area,
                    cnc, ai, cl_s, cl_s)
        end
        println(io, "")
    end
    println(io, " ---------------------------------------------------------------")
end

"""
    print_stability_derivatives(io, sol, vl, config)

Print stability derivative matrix (equivalent to AVL's ST command).
"""
function print_stability_derivatives(io::IO, sol::AVLSolution, vl::VortexLattice, config::AVLConfig)
    nc = vl.ncontrol
    alpha = sol.alpha
    ca = cos(alpha); sa = sin(alpha)

    println(io, "")
    println(io, " ---------------------------------------------------------------")
    println(io, " Stability-axis derivatives (Wrt body-axis rates)")
    println(io, "")
    @printf(io, "  alpha = %10.5f deg\n", rad2deg(alpha))
    @printf(io, "  beta  = %10.5f deg\n", rad2deg(sol.beta))
    @printf(io, "  Mach  = %10.4f\n", sol.mach)
    println(io, "")

    # derivatives w.r.t. alpha, beta, p'=pb/2V, q'=qc/2V, r'=rb/2V
    # need to convert from unit-component derivatives to angle derivatives
    # d(CL)/d(alpha) = d(CL)/d(vinf) * d(vinf)/d(alpha)
    vinf, vinf_a, vinf_b = vinfab(alpha, sol.beta)

    cl_a = sol.cl_u[1]*vinf_a[1] + sol.cl_u[2]*vinf_a[2] + sol.cl_u[3]*vinf_a[3]
    cl_b = sol.cl_u[1]*vinf_b[1] + sol.cl_u[2]*vinf_b[2] + sol.cl_u[3]*vinf_b[3]
    cl_p = sol.cl_u[4]; cl_q = sol.cl_u[5]; cl_r = sol.cl_u[6]

    cy_a = sol.cy_u[1]*vinf_a[1] + sol.cy_u[2]*vinf_a[2] + sol.cy_u[3]*vinf_a[3]
    cy_b = sol.cy_u[1]*vinf_b[1] + sol.cy_u[2]*vinf_b[2] + sol.cy_u[3]*vinf_b[3]
    cy_p = sol.cy_u[4]; cy_q = sol.cy_u[5]; cy_r = sol.cy_u[6]

    # moments (body axes)
    cmx_a = sol.cmx_u[1]*vinf_a[1] + sol.cmx_u[2]*vinf_a[2] + sol.cmx_u[3]*vinf_a[3]
    cmx_b = sol.cmx_u[1]*vinf_b[1] + sol.cmx_u[2]*vinf_b[2] + sol.cmx_u[3]*vinf_b[3]
    cmx_p = sol.cmx_u[4]; cmx_q = sol.cmx_u[5]; cmx_r = sol.cmx_u[6]

    cmy_a = sol.cmy_u[1]*vinf_a[1] + sol.cmy_u[2]*vinf_a[2] + sol.cmy_u[3]*vinf_a[3]
    cmy_b = sol.cmy_u[1]*vinf_b[1] + sol.cmy_u[2]*vinf_b[2] + sol.cmy_u[3]*vinf_b[3]
    cmy_p = sol.cmy_u[4]; cmy_q = sol.cmy_u[5]; cmy_r = sol.cmy_u[6]

    cmz_a = sol.cmz_u[1]*vinf_a[1] + sol.cmz_u[2]*vinf_a[2] + sol.cmz_u[3]*vinf_a[3]
    cmz_b = sol.cmz_u[1]*vinf_b[1] + sol.cmz_u[2]*vinf_b[2] + sol.cmz_u[3]*vinf_b[3]
    cmz_p = sol.cmz_u[4]; cmz_q = sol.cmz_u[5]; cmz_r = sol.cmz_u[6]

    @printf(io, "                  %-12s  %-12s  %-12s  %-12s  %-12s\n",
            "alpha", "beta", "pb/2V", "qc/2V", "rb/2V")
    println(io, "  ", "-"^75)
    @printf(io, "  z' force CL |  %12.6f  %12.6f  %12.6f  %12.6f  %12.6f\n",
            cl_a, cl_b, cl_p, cl_q, cl_r)
    @printf(io, "  y  force CY |  %12.6f  %12.6f  %12.6f  %12.6f  %12.6f\n",
            cy_a, cy_b, cy_p, cy_q, cy_r)
    @printf(io, "  roll   Cl   |  %12.6f  %12.6f  %12.6f  %12.6f  %12.6f\n",
            cmx_a, cmx_b, cmx_p, cmx_q, cmx_r)
    @printf(io, "  pitch  Cm   |  %12.6f  %12.6f  %12.6f  %12.6f  %12.6f\n",
            cmy_a, cmy_b, cmy_p, cmy_q, cmy_r)
    @printf(io, "  yaw    Cn   |  %12.6f  %12.6f  %12.6f  %12.6f  %12.6f\n",
            cmz_a, cmz_b, cmz_p, cmz_q, cmz_r)
    println(io, "")

    if nc > 0
        println(io, " Control derivatives:")
        @printf(io, "                  ")
        for n in 1:nc
            @printf(io, "  %-12s", vl.control_names[n])
        end
        println(io, "")
        println(io, "  ", "-"^(18 + 14*nc))

        @printf(io, "  z' force CL |")
        for n in 1:nc; @printf(io, "  %12.6f", sol.cl_d[n]); end
        println(io)
        @printf(io, "  y  force CY |")
        for n in 1:nc; @printf(io, "  %12.6f", sol.cy_d[n]); end
        println(io)
        @printf(io, "  roll   Cl   |")
        for n in 1:nc; @printf(io, "  %12.6f", sol.cmx_d[n]); end
        println(io)
        @printf(io, "  pitch  Cm   |")
        for n in 1:nc; @printf(io, "  %12.6f", sol.cmy_d[n]); end
        println(io)
        @printf(io, "  yaw    Cn   |")
        for n in 1:nc; @printf(io, "  %12.6f", sol.cmz_d[n]); end
        println(io)
    end

    # neutral point
    if abs(cl_a) > 1e-10
        xnp = config.xyzref[1] - cmy_a / cl_a * config.cref
        @printf(io, "\n  Neutral point  Xnp = %10.5f\n", xnp)
    end

    println(io, "")
    println(io, " ---------------------------------------------------------------")
end

"""
    write_forces_file(filename, sol, vl, config)

Write total forces to a file.
"""
function write_forces_file(filename::AbstractString, sol::AVLSolution,
                            vl::VortexLattice, config::AVLConfig)
    open(filename, "w") do io
        print_total_forces(io, sol, vl, config)
    end
end

"""
    write_strip_file(filename, sol, vl, config)

Write strip loading distribution to a file.
"""
function write_strip_file(filename::AbstractString, sol::AVLSolution,
                           vl::VortexLattice, config::AVLConfig)
    open(filename, "w") do io
        for js in 1:vl.nstrip
            strip = vl.strips[js]
            cnc = js <= length(sol.strip_cnc) ? sol.strip_cnc[js] : 0.0
            cl_s = js <= length(sol.strip_cl) ? sol.strip_cl[js] : 0.0

            @printf(io, "%12.6f %12.6f %12.6f %12.6f %12.6f %12.6f %12.6f %12.6f\n",
                    strip.rle[1], strip.rle[2], strip.rle[3],
                    cnc, cl_s, strip.chord, strip.wstrip,
                    strip.wstrip * strip.chord)
        end
    end
end

"""
    write_element_file(filename, sol, vl)

Write per-element data (positions, DCP) to a file.
"""
function write_element_file(filename::AbstractString, sol::AVLSolution, vl::VortexLattice)
    open(filename, "w") do io
        @printf(io, "# %4s  %12s  %12s  %12s  %12s  %12s  %12s\n",
                "i", "X", "Y", "Z", "DX", "Slope", "DCP")
        for i in 1:vl.nvor
            elem = vl.elements[i]
            dcp = i <= length(sol.dcp) ? sol.dcp[i] : 0.0
            @printf(io, "  %4d  %12.6f  %12.6f  %12.6f  %12.6f  %12.6f  %12.6f\n",
                    i, elem.rv[1], elem.rv[2], elem.rv[3],
                    elem.dxv, elem.slopev, dcp)
        end
    end
end
