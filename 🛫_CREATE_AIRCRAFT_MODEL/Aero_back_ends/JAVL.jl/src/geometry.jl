# ──────────────────────────────────────────────────────────────
# geometry.jl — Build vortex lattice from surface definitions
#               (matching AVL's amake.f and asetup.f)
# ──────────────────────────────────────────────────────────────

"""
    build_lattice(config::AVLConfig) → VortexLattice

Construct the complete vortex lattice discretization from the configuration.
"""
function build_lattice(config::AVLConfig)
    vl = VortexLattice()

    # collect all control and design variable names
    all_control_names = String[]
    all_design_names = String[]
    for surf in config.surfaces
        for sect in surf.sections
            for ctrl in sect.controls
                if !(ctrl.name in all_control_names)
                    push!(all_control_names, ctrl.name)
                end
            end
            for dname in sect.design_names
                if !(dname in all_design_names)
                    push!(all_design_names, dname)
                end
            end
        end
    end
    vl.ncontrol = length(all_control_names)
    vl.control_names = all_control_names
    vl.ndesign = length(all_design_names)
    vl.design_names = all_design_names

    # build each surface
    for (isurf, surfdef) in enumerate(config.surfaces)
        make_surface!(vl, config, surfdef, isurf, false)
        # handle YDUPLICATE
        if surfdef.has_ydup
            make_surface!(vl, config, surfdef, isurf, true)
        end
    end

    # allocate control sensitivity arrays
    nv = vl.nvor
    nc = vl.ncontrol
    vl.dcontrol = zeros(nv, nc)
    vl.enc_d = zeros(3, nv, nc)

    # fill control sensitivity data
    _fill_control_sensitivities!(vl, config)

    return vl
end

"""
    make_surface!(vl, config, surfdef, isurf, is_duplicate)

Discretize one surface (or its YDUPLICATE mirror) into vortex elements and strips.
"""
function make_surface!(vl::VortexLattice, config::AVLConfig,
                       surfdef::SurfaceDef, isurf::Int, is_duplicate::Bool)
    nsec = length(surfdef.sections)
    nsec < 2 && return

    nchord = surfdef.nchord

    # apply surface transforms to section data
    sections = _transform_sections(surfdef)

    # generate spanwise spacing
    spans_per_interval, sfrac_per_interval, sfrac_mid_per_interval = _compute_spanwise_panels(surfdef, sections)

    # track surface start
    surf_elem_start = vl.nvor + 1
    surf_strip_start = vl.nstrip + 1

    # chordwise spacing
    claf = sections[1].claf
    xpt, xvr, xsr, xcp = cspacer(nchord, surfdef.cspace, claf)

    total_strips = 0

    for isec in 1:nsec-1
        sec1 = sections[isec]
        sec2 = sections[isec+1]
        nspan = spans_per_interval[isec]
        sfrac = sfrac_per_interval[isec]
        sfrac_mid = sfrac_mid_per_interval[isec]

        for j in 1:nspan
            f1 = sfrac[j]
            f2 = sfrac[j+1]
            fmid = sfrac_mid[j]

            # interpolate section properties
            xle_l, yle_l, zle_l = _lerp_pos(sec1, sec2, f1)
            xle_r, yle_r, zle_r = _lerp_pos(sec1, sec2, f2)
            xle_m, yle_m, zle_m = _lerp_pos(sec1, sec2, fmid)
            chord_l = sec1.chord*(1-f1) + sec2.chord*f1
            chord_r = sec1.chord*(1-f2) + sec2.chord*f2
            chord_m = sec1.chord*(1-fmid) + sec2.chord*fmid
            ainc_m = sec1.ainc*(1-fmid) + sec2.ainc*fmid  # degrees

            # handle YDUPLICATE
            if is_duplicate
                yd = surfdef.yduplicate
                yle_l = 2*yd - yle_l
                yle_r = 2*yd - yle_r
                yle_m = 2*yd - yle_m
                # swap left/right for correct orientation
                xle_l, xle_r = xle_r, xle_l
                yle_l, yle_r = yle_r, yle_l
                zle_l, zle_r = zle_r, zle_l
                chord_l, chord_r = chord_r, chord_l
            end

            # strip width
            dy = yle_r - yle_l
            dz = zle_r - zle_l
            wstrip = sqrt(dy^2 + dz^2)

            # strip normal in Trefftz plane
            dsyz = max(wstrip, 1e-20)
            ensy = -dz / dsyz
            ensz =  dy / dsyz

            # chord ratios for spanwise interpolation (AVL amake.f)
            # Uses SECTION chords, not strip edge chords
            cr1 = sec1.chord / max(chord_m, 1e-20)  # CHORDL/CHORDC
            cr2 = sec2.chord / max(chord_m, 1e-20)  # CHORDR/CHORDC

            # interpolate CLAF with chord ratio (AVL amake.f line 487)
            claf_m = (1-fmid)*cr1*sec1.claf + fmid*cr2*sec2.claf

            # recompute chordwise spacing if CLAF varies
            xpt_loc, xvr_loc, xsr_loc, xcp_loc = cspacer(nchord, surfdef.cspace, claf_m)

            # interpolate camber slopes with chord ratio (AVL amake.f line 521)
            slopes_v = zeros(nchord)
            slopes_c = zeros(nchord)
            for k in 1:nchord
                sv1 = _interp_camber_slope(sec1, xvr_loc[k])
                sv2 = _interp_camber_slope(sec2, xvr_loc[k])
                slopes_v[k] = (1-fmid)*cr1*sv1 + fmid*cr2*sv2

                sc1 = _interp_camber_slope(sec1, xcp_loc[k])
                sc2 = _interp_camber_slope(sec2, xcp_loc[k])
                slopes_c[k] = (1-fmid)*cr1*sc1 + fmid*cr2*sc2
            end

            # create strip
            strip = Strip()
            strip.rle = (xle_m, yle_m, zle_m)
            strip.rle1 = (xle_l, yle_l, zle_l)
            strip.rle2 = (xle_r, yle_r, zle_r)
            strip.chord = chord_m
            strip.wstrip = wstrip
            strip.ainc = deg2rad(ainc_m)
            strip.ensy = ensy
            strip.ensz = ensz
            strip.isurf = length(vl.surf_names) + 1
            strip.ifirst = vl.nvor + 1
            strip.nelem = nchord
            strip.has_wake = !surfdef.nowake
            strip.sees_freestream = !surfdef.noalbe
            strip.contributes_load = !surfdef.noload

            # viscous polar: section or surface level
            if sec1.has_cdcl || sec2.has_cdcl
                cdcl1 = sec1.has_cdcl ? sec1.cdcl : (surfdef.has_cdcl ? surfdef.cdcl : Float64[])
                cdcl2 = sec2.has_cdcl ? sec2.cdcl : (surfdef.has_cdcl ? surfdef.cdcl : Float64[])
                if !isempty(cdcl1) && !isempty(cdcl2)
                    strip.cdcl = cdcl1*(1-fmid) .+ cdcl2*fmid
                    strip.has_cdcl = true
                elseif !isempty(cdcl1)
                    strip.cdcl = copy(cdcl1)
                    strip.has_cdcl = true
                elseif !isempty(cdcl2)
                    strip.cdcl = copy(cdcl2)
                    strip.has_cdcl = true
                end
            elseif surfdef.has_cdcl
                strip.cdcl = copy(surfdef.cdcl)
                strip.has_cdcl = true
            end

            # create vortex elements for this strip
            ainc_rad = deg2rad(ainc_m)
            for k in 1:nchord
                # bound vortex endpoints use LOCAL chord at each edge
                # (matching AVL: RV1 uses CHORD1, RV2 uses CHORD2)
                rv1 = (xle_l + xvr_loc[k]*chord_l, yle_l, zle_l)
                rv2 = (xle_r + xvr_loc[k]*chord_r, yle_r, zle_r)
                rv_mid = (0.5*(rv1[1]+rv2[1]), 0.5*(rv1[2]+rv2[2]), 0.5*(rv1[3]+rv2[3]))

                # control point at 3/4 chord of panel
                rc = (xle_m + xcp_loc[k]*chord_m, yle_m, zle_m)

                dxv = (xpt_loc[k+1] - xpt_loc[k]) * chord_m

                # normal vector (computed from incidence + camber)
                ang_v = ainc_rad - atan(slopes_v[k])
                ang_c = ainc_rad - atan(slopes_c[k])

                # the normal vector construction:
                # bound leg direction
                eb = normalize3((rv2[1]-rv1[1], rv2[2]-rv1[2], rv2[3]-rv1[3]))
                # camberline direction at control point
                ec = (cos(ang_c), -sin(ang_c)*ensy, -sin(ang_c)*ensz)
                # normal = ec × eb, normalized
                enc = normalize3(cross3(ec, eb))

                # at vortex midpoint
                ev = (cos(ang_v), -sin(ang_v)*ensy, -sin(ang_v)*ensz)
                env = normalize3(cross3(ev, eb))

                elem = VortexElement(rv1, rv2, rv_mid, rc, enc, env,
                                     dxv, chord_m, slopes_c[k], slopes_v[k],
                                     length(vl.surf_names)+1,
                                     vl.nstrip+1,
                                     surfdef.component)
                push!(vl.elements, elem)
                vl.nvor += 1
            end

            push!(vl.strips, strip)
            vl.nstrip += 1
            total_strips += 1
        end
    end

    # record surface info
    sname = is_duplicate ? surfdef.name * " (YDUP)" : surfdef.name
    push!(vl.surf_names, sname)
    push!(vl.surf_ifrst, surf_elem_start)
    push!(vl.surf_jfrst, surf_strip_start)
    push!(vl.surf_nj, total_strips)
    push!(vl.surf_nk, nchord)
    push!(vl.surf_comp, surfdef.component)
    vl.nsurf += 1
end

# ── Helper functions ────────────────────────────────────────

function _transform_sections(surfdef::SurfaceDef)
    sections = SectionDef[]
    for sec in surfdef.sections
        s = deepcopy(sec)
        # apply scale
        s.xle *= surfdef.scale[1]
        s.yle *= surfdef.scale[2]
        s.zle *= surfdef.scale[3]
        s.chord *= surfdef.scale[1]
        # apply translate
        s.xle += surfdef.translate[1]
        s.yle += surfdef.translate[2]
        s.zle += surfdef.translate[3]
        # apply angle offset
        s.ainc += surfdef.angle_offset
        push!(sections, s)
    end
    return sections
end

function _compute_spanwise_panels(surfdef::SurfaceDef, sections::Vector{SectionDef})
    nsec = length(sections)
    nintervals = nsec - 1

    spans = zeros(Int, nintervals)
    sfrac_all = Vector{Vector{Float64}}(undef, nintervals)
    sfrac_mid_all = Vector{Vector{Float64}}(undef, nintervals)

    if surfdef.nspan > 0
        # Case B (AVL amake.f lines 151-238): Surface-level NVS > 0
        # Generate single cosine spacing across full span, then fudge to align
        # with interior section boundaries.
        nvs = surfdef.nspan
        sspace = surfdef.sspace

        # Arc-length positions of sections (matching amake.f lines 102-107)
        yzlen = zeros(nsec)
        for isec in 2:nsec
            dy = sections[isec].yle - sections[isec-1].yle
            dz = sections[isec].zle - sections[isec-1].zle
            yzlen[isec] = yzlen[isec-1] + sqrt(dy^2 + dz^2)
        end

        # Generate full-span cosine spacing: 2*NVS+1 points (amake.f line 160-166)
        fspace = spacer(2*nvs, sspace)

        # Convert to absolute positions (amake.f lines 168-172)
        total_len = yzlen[nsec] - yzlen[1]
        ypt = zeros(nvs + 1)
        ycp = zeros(nvs)
        ypt[1] = yzlen[1]
        for ivs in 1:nvs
            ycp[ivs]   = yzlen[1] + total_len * fspace[2*ivs]       # even indices → centers
            ypt[ivs+1] = yzlen[1] + total_len * fspace[2*ivs + 1]   # odd indices → edges
        end
        npt = nvs + 1

        # Find nearest spacing node to each interior section (amake.f lines 176-189)
        iptloc = zeros(Int, nsec)
        for isec in 2:nsec-1
            yptloc = 1.0e9
            iptloc[isec] = 1
            for ipt in 1:npt
                yptdel = abs(yzlen[isec] - ypt[ipt])
                if yptdel < yptloc
                    yptloc = yptdel
                    iptloc[isec] = ipt
                end
            end
        end
        iptloc[1] = 1
        iptloc[nsec] = npt

        # Fudge spacing to align nodes exactly with section boundaries (amake.f lines 191-236)
        for isec in 2:nsec-1
            # Segment before: ISEC-1 to ISEC
            ipt1 = iptloc[isec-1]
            ipt2 = iptloc[isec]
            if ipt1 == ipt2
                error("Cannot adjust spanwise spacing at section $isec on surface $(surfdef.name): " *
                      "insufficient number of spanwise vortices")
            end
            ypt1 = ypt[ipt1]
            yscale = (yzlen[isec] - yzlen[isec-1]) / (ypt[ipt2] - ypt[ipt1])
            for ipt in ipt1:ipt2-1
                ypt[ipt] = yzlen[isec-1] + yscale * (ypt[ipt] - ypt1)
            end
            for ivs in ipt1:ipt2-1
                ycp[ivs] = yzlen[isec-1] + yscale * (ycp[ivs] - ypt1)
            end

            # Segment after: ISEC to ISEC+1
            ipt1 = iptloc[isec]
            ipt2 = iptloc[isec+1]
            if ipt1 == ipt2
                error("Cannot adjust spanwise spacing at section $isec on surface $(surfdef.name): " *
                      "insufficient number of spanwise vortices")
            end
            ypt1 = ypt[ipt1]
            yscale = (ypt[ipt2] - yzlen[isec]) / (ypt[ipt2] - ypt[ipt1])
            for ipt in ipt1:ipt2-1
                ypt[ipt] = yzlen[isec] + yscale * (ypt[ipt] - ypt1)
            end
            for ivs in ipt1:ipt2-1
                ycp[ivs] = yzlen[isec] + yscale * (ycp[ivs] - ypt1)
            end
        end

        # Extract per-interval fractions (matching amake.f lines 336-348)
        for isec in 1:nintervals
            iptl = iptloc[isec]
            iptr = iptloc[isec+1]
            nspan = iptr - iptl
            spans[isec] = nspan

            ypt_l = ypt[iptl]
            ypt_r = ypt[iptr]
            denom = ypt_r - ypt_l
            if denom < 1e-20
                denom = 1.0
            end

            sf = zeros(nspan + 1)
            for j in 1:nspan+1
                sf[j] = (ypt[iptl + j - 1] - ypt_l) / denom
            end
            sf[1] = 0.0
            sf[end] = 1.0

            sfm = zeros(nspan)
            for j in 1:nspan
                sfm[j] = (ycp[iptl + j - 1] - ypt_l) / denom
            end

            sfrac_all[isec] = sf
            sfrac_mid_all[isec] = sfm
        end
    else
        # Case A (AVL amake.f lines 112-149): Surface NVS = 0
        # Use per-section NSPAN with independent spacer calls per interval
        has_section_nspan = any(sections[i].nspan > 0 for i in 1:nintervals)
        for i in 1:nintervals
            if has_section_nspan && sections[i].nspan > 0
                spans[i] = sections[i].nspan
                ssp = sections[i].sspace
            else
                spans[i] = 6
                ssp = 1.0
            end
            all_frac = spacer(2*spans[i], ssp)
            sfrac_all[i] = all_frac[1:2:end]        # odd indices → edges
            sfrac_mid_all[i] = all_frac[2:2:end-1]  # even indices → centers
        end
    end

    return spans, sfrac_all, sfrac_mid_all
end

@inline function _lerp_pos(sec1::SectionDef, sec2::SectionDef, f::Float64)
    x = sec1.xle*(1-f) + sec2.xle*f
    y = sec1.yle*(1-f) + sec2.yle*f
    z = sec1.zle*(1-f) + sec2.zle*f
    return x, y, z
end

function _interp_camber_slope(sec::SectionDef, xc::Float64)
    sec.naf < 2 && return 0.0
    yy, _ = akima_interp(sec.xaf, sec.yaf, xc)
    return yy  # yaf stores pre-computed slopes; interpolated value IS the slope
end

function _fill_control_sensitivities!(vl::VortexLattice, config::AVLConfig)
    nv = vl.nvor
    nc = vl.ncontrol
    nc == 0 && return

    vl.dcontrol = zeros(nv, nc)
    vl.enc_d = zeros(3, nv, nc)

    # for each element, determine which controls affect it
    # this requires tracking which surface/section interval each element came from
    # For now, we'll use the strip info + surface definitions

    elem_idx = 0
    for (isurfdef, surfdef) in enumerate(config.surfaces)
        for is_dup in [false, surfdef.has_ydup]
            is_dup === false || continue  # handle dup below

            sections = _transform_sections(surfdef)
            nsec = length(sections)
            nsec < 2 && continue

            spans_per_interval, sfrac_per_interval, sfrac_mid_per_interval = _compute_spanwise_panels(surfdef, sections)
            nchord = surfdef.nchord

            for isec in 1:nsec-1
                sec1 = sections[isec]
                sec2 = sections[isec+1]
                nspan = spans_per_interval[isec]
                sfrac_mid_ctrl = sfrac_mid_per_interval[isec]

                for j in 1:nspan
                    fmid = sfrac_mid_ctrl[j]

                    for k in 1:nchord
                        elem_idx += 1
                        elem_idx > nv && return

                        # get chordwise position
                        claf_m = sec1.claf*(1-fmid) + sec2.claf*fmid
                        _, xvr_loc, _, xcp_loc = cspacer(nchord, surfdef.cspace, claf_m)

                        for ctrl1 in sec1.controls, ctrl2 in sec2.controls
                            if ctrl1.name == ctrl2.name
                                cidx = findfirst(==(ctrl1.name), vl.control_names)
                                cidx === nothing && continue

                                # interpolate hinge position and gain
                                gain = ctrl1.gain*(1-fmid) + ctrl2.gain*fmid
                                xhinge = ctrl1.xhinge*(1-fmid) + ctrl2.xhinge*fmid

                                # check if this element is on the control surface
                                if xhinge >= 0
                                    # TE control: active from xhinge to 1.0
                                    if xcp_loc[k] >= xhinge
                                        dgain = gain * deg2rad(1.0)  # per degree
                                        vl.dcontrol[elem_idx, cidx] = dgain

                                        # normal vector sensitivity (simplified)
                                        elem = vl.elements[elem_idx]
                                        eb = normalize3((elem.rv2[1]-elem.rv1[1],
                                                        elem.rv2[2]-elem.rv1[2],
                                                        elem.rv2[3]-elem.rv1[3]))
                                        # hinge axis
                                        hv = ctrl1.hvec
                                        if norm3(hv) < 1e-10
                                            hv = eb  # default: hinge along span
                                        end
                                        hv = normalize3(hv)

                                        # enc_d = d(enc)/d(control) ≈ hv × enc * gain
                                        enc = elem.enc
                                        enc_cross = cross3(hv, enc)
                                        vl.enc_d[1, elem_idx, cidx] = enc_cross[1] * dgain
                                        vl.enc_d[2, elem_idx, cidx] = enc_cross[2] * dgain
                                        vl.enc_d[3, elem_idx, cidx] = enc_cross[3] * dgain
                                    end
                                else
                                    # LE control: active from 0 to -xhinge
                                    if xcp_loc[k] <= -xhinge
                                        dgain = gain * deg2rad(1.0)
                                        vl.dcontrol[elem_idx, cidx] = dgain

                                        elem = vl.elements[elem_idx]
                                        eb = normalize3((elem.rv2[1]-elem.rv1[1],
                                                        elem.rv2[2]-elem.rv1[2],
                                                        elem.rv2[3]-elem.rv1[3]))
                                        hv = ctrl1.hvec
                                        if norm3(hv) < 1e-10
                                            hv = eb
                                        end
                                        hv = normalize3(hv)
                                        enc = elem.enc
                                        enc_cross = cross3(hv, enc)
                                        vl.enc_d[1, elem_idx, cidx] = enc_cross[1] * dgain
                                        vl.enc_d[2, elem_idx, cidx] = enc_cross[2] * dgain
                                        vl.enc_d[3, elem_idx, cidx] = enc_cross[3] * dgain
                                    end
                                end
                            end
                        end
                    end
                end
            end

            # handle YDUPLICATE surface (mirrored control gains)
            if surfdef.has_ydup
                nsec2 = length(sections)
                for isec in 1:nsec2-1
                    nspan = spans_per_interval[isec]
                    sfrac_mid_dup = sfrac_mid_per_interval[isec]
                    for j in 1:nspan
                        fmid = sfrac_mid_dup[j]
                        for k in 1:nchord
                            elem_idx += 1
                            elem_idx > nv && return
                            # mirror control sensitivities with sgndup
                            sec1 = sections[isec]
                            sec2 = sections[isec+1]
                            claf_m = sec1.claf*(1-fmid) + sec2.claf*fmid
                            _, xvr_loc, _, xcp_loc = cspacer(nchord, surfdef.cspace, claf_m)

                            for ctrl1 in sec1.controls, ctrl2 in sec2.controls
                                if ctrl1.name == ctrl2.name
                                    cidx = findfirst(==(ctrl1.name), vl.control_names)
                                    cidx === nothing && continue
                                    gain = ctrl1.gain*(1-fmid) + ctrl2.gain*fmid
                                    gain *= ctrl1.sgndup  # reflection sign
                                    xhinge = ctrl1.xhinge*(1-fmid) + ctrl2.xhinge*fmid

                                    active = xhinge >= 0 ? (xcp_loc[k] >= xhinge) : (xcp_loc[k] <= -xhinge)
                                    if active
                                        dgain = gain * deg2rad(1.0)
                                        vl.dcontrol[elem_idx, cidx] = dgain

                                        elem = vl.elements[elem_idx]
                                        eb = normalize3((elem.rv2[1]-elem.rv1[1],
                                                        elem.rv2[2]-elem.rv1[2],
                                                        elem.rv2[3]-elem.rv1[3]))
                                        hv = ctrl1.hvec
                                        if norm3(hv) < 1e-10
                                            hv = eb
                                        end
                                        hv = normalize3(hv)
                                        hv = (hv[1], -hv[2], hv[3])  # reflect y
                                        enc = elem.enc
                                        enc_cross = cross3(hv, enc)
                                        vl.enc_d[1, elem_idx, cidx] = enc_cross[1] * dgain
                                        vl.enc_d[2, elem_idx, cidx] = enc_cross[2] * dgain
                                        vl.enc_d[3, elem_idx, cidx] = enc_cross[3] * dgain
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
