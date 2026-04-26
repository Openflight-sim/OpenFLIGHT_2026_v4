# ──────────────────────────────────────────────────────────────
# body.jl — Body source/doublet line model
#            (matching AVL's SRDSET, VSRD, SRDVELC, BDFORC)
# ──────────────────────────────────────────────────────────────

"""
    makebody!(vl, config)

Build body node geometry from BodyDef data. Creates source-line nodes
via spacing distribution + Akima interpolation, matching Fortran MAKEBODY.
"""
function makebody!(vl::VortexLattice, config::AVLConfig)
    vl.nbody = 0
    vl.body_nodes = Vector{BodyNode}[]
    vl.body_names = String[]

    for (ibody, bdef) in enumerate(config.bodies)
        nodes = _make_one_body(bdef, config)
        if !isempty(nodes)
            push!(vl.body_nodes, nodes)
            push!(vl.body_names, bdef.name)
            vl.nbody += 1
        end

        # handle YDUPLICATE
        if bdef.has_ydup
            dup_nodes = _duplicate_body(nodes, bdef.yduplicate)
            push!(vl.body_nodes, dup_nodes)
            push!(vl.body_names, bdef.name * " (YDUP)")
            vl.nbody += 1
        end
    end
end

function _make_one_body(bdef::BodyDef, config::AVLConfig)
    nvb = bdef.nbody
    (isempty(bdef.xb) || length(bdef.xb) < 2) && return BodyNode[]

    # spacing fractions along body axis
    # Fortran SPACER(NVB,...) generates NVB points (NVB-1 intervals).
    # Julia spacer(n,...) generates n+1 points (n intervals).
    # So we call spacer(nvb-1,...) to get nvb points matching Fortran.
    frac = spacer(nvb - 1, bdef.bspace)
    frac[1] = 0.0
    frac[end] = 1.0

    xbod = bdef.xb
    nbod = length(xbod)

    # Fortran stores YBOD (centerline) and TBOD (thickness=2*radius)
    # We store bdef.yb (centerline offsets) and bdef.rb (radius)
    ybod = length(bdef.yb) == nbod ? bdef.yb : zeros(nbod)

    nodes = BodyNode[]

    for ivb in 1:nvb
        xvb = xbod[1] + (xbod[end] - xbod[1]) * frac[ivb]

        # Akima interpolation for centerline y and radius (matching Fortran MAKEBODY)
        yvb, _ = akima_interp(xbod, ybod, xvb)   # centerline y offset
        rvb, _ = akima_interp(xbod, bdef.rb, xvb)  # radius
        rvb = max(rvb, 0.0)

        # apply scale and translate (matching Fortran amake.f MAKEBODY):
        # RL(1) = XYZTRAN(1) + XYZSCAL(1)*XVB
        # RL(2) = XYZTRAN(2)
        # RL(3) = XYZTRAN(3) + XYZSCAL(3)*YVB
        # RADL  = SQRT(XYZSCAL(2)*XYZSCAL(3)) * 0.5*TVB  [TVB = 2*radius]
        px = bdef.translate[1] + bdef.scale[1] * xvb
        py = bdef.translate[2]
        pz = bdef.translate[3] + bdef.scale[3] * yvb
        r  = sqrt(abs(bdef.scale[2] * bdef.scale[3])) * rvb

        push!(nodes, BodyNode((px, py, pz), r))
    end
    return nodes
end

function _duplicate_body(nodes::Vector{BodyNode}, ydup::Float64)
    yoff = 2.0 * ydup
    dup = BodyNode[]
    for n in nodes
        push!(dup, BodyNode((n.pos[1], yoff - n.pos[2], n.pos[3]), n.radius))
    end
    return dup
end

# ──────────────────────────────────────────────────────────────
# SRDSET — Source/doublet unit strengths
# ──────────────────────────────────────────────────────────────

"""
    srdset(vl, config) → (src_u, dbl_u)

Compute unit source and doublet strengths for all body segments
under 6 unit freestream components (u,v,w,p,q,r).
Matching Fortran SRDSET in aic.f.
"""
function srdset(vl::VortexLattice, config::AVLConfig)
    betm = sqrt(max(1.0 - config.mach^2, 0.01))

    # count total body segments
    nlnode_total = 0
    for nodes in vl.body_nodes
        nlnode_total += length(nodes)
    end
    nlnode_total == 0 && return zeros(0, 6), zeros(3, 0, 6)

    src_u = zeros(nlnode_total, 6)
    dbl_u = zeros(3, nlnode_total, 6)

    xyzref = config.xyzref
    l_offset = 0

    for (ibody, nodes) in enumerate(vl.body_nodes)
        nvb = length(nodes)
        nvb < 2 && continue

        # check if body on y-symmetry plane → halve area
        blen = abs(nodes[end].pos[1] - nodes[1].pos[1])
        sdfac = 1.0
        if config.iysym == 1 && abs(nodes[1].pos[2]) <= 0.001 * max(blen, 1e-10)
            sdfac = 0.5
        end

        for ilseg in 1:nvb-1
            l1 = l_offset + ilseg
            l2 = l_offset + ilseg + 1
            l  = l1  # store at first node index

            n1 = nodes[ilseg]
            n2 = nodes[ilseg + 1]

            # segment vector (Mach-corrected x)
            drl = ((n2.pos[1] - n1.pos[1]) / betm,
                    n2.pos[2] - n1.pos[2],
                    n2.pos[3] - n1.pos[3])
            drlmag = sqrt(drl[1]^2 + drl[2]^2 + drl[3]^2)
            drlmi = drlmag > 0.0 ? 1.0 / drlmag : 0.0

            # unit vector along segment
            esl = (drl[1] * drlmi, drl[2] * drlmi, drl[3] * drlmi)

            # area change and average area
            adel = π * (n2.radius^2 - n1.radius^2) * sdfac
            aavg = π * 0.5 * (n2.radius^2 + n1.radius^2) * sdfac

            # segment midpoint relative to reference
            rlref = (0.5*(n2.pos[1]+n1.pos[1]) - xyzref[1],
                     0.5*(n2.pos[2]+n1.pos[2]) - xyzref[2],
                     0.5*(n2.pos[3]+n1.pos[3]) - xyzref[3])

            for iu in 1:6
                # unit velocity at segment midpoint
                if iu <= 3
                    urel = [0.0, 0.0, 0.0]
                    urel[iu] = 1.0
                else
                    wrot_u = [0.0, 0.0, 0.0]
                    wrot_u[iu-3] = 1.0
                    urel = [rlref[2]*wrot_u[3] - rlref[3]*wrot_u[2],
                            rlref[3]*wrot_u[1] - rlref[1]*wrot_u[3],
                            rlref[1]*wrot_u[2] - rlref[2]*wrot_u[1]]
                end
                urel[1] /= betm  # Mach correction

                # axial velocity component
                us = urel[1]*esl[1] + urel[2]*esl[2] + urel[3]*esl[3]

                # normal velocity = urel - us*esl
                un1 = urel[1] - us*esl[1]
                un2 = urel[2] - us*esl[2]
                un3 = urel[3] - us*esl[3]

                src_u[l, iu] = adel * us
                dbl_u[1, l, iu] = aavg * un1 * drlmag * 2.0
                dbl_u[2, l, iu] = aavg * un2 * drlmag * 2.0
                dbl_u[3, l, iu] = aavg * un3 * drlmag * 2.0
            end
        end
        l_offset += nvb
    end

    return src_u, dbl_u
end

# ──────────────────────────────────────────────────────────────
# SRDVELC — Velocity from a single source/doublet line segment
# ──────────────────────────────────────────────────────────────

"""
    srdvelc(x, y, z, x1, y1, z1, x2, y2, z2, beta, rcore) → (uvws, uvwd)

Velocity from a source/doublet line segment at a field point.
uvws[3] = velocity per unit source strength
uvwd[3,3] = velocity per unit doublet component (k=vel, j=doublet dir)
Matching Fortran SRDVELC in aic.f.
"""
function srdvelc(x, y, z, x1, y1, z1, x2, y2, z2, beta, rcore)
    PI4INV = 0.079577472  # 1/(4π)

    r1 = ((x1-x)/beta, y1-y, z1-z)
    r2 = ((x2-x)/beta, y2-y, z2-z)

    rcsq = rcore^2

    r1sq = r1[1]^2 + r1[2]^2 + r1[3]^2
    r2sq = r2[1]^2 + r2[2]^2 + r2[3]^2

    r1sqeps = r1sq + rcsq
    r2sqeps = r2sq + rcsq

    r1eps = sqrt(r1sqeps)
    r2eps = sqrt(r2sqeps)

    rdr = r1[1]*r2[1] + r1[2]*r2[2] + r1[3]*r2[3]
    rxr = (r1[2]*r2[3] - r1[3]*r2[2],
           r1[3]*r2[1] - r1[1]*r2[3],
           r1[1]*r2[2] - r1[2]*r2[1])

    xdx = rxr[1]^2 + rxr[2]^2 + rxr[3]^2
    all_ = r1sq + r2sq - 2.0*rdr
    den = rcsq * all_ + xdx

    if abs(den) < 1e-30
        return zeros(3), zeros(3, 3)
    end

    ai1 = ((rdr + rcsq) / r1eps - r2eps) / den
    ai2 = ((rdr + rcsq) / r2eps - r1eps) / den

    uvws = zeros(3)
    uvwd = zeros(3, 3)

    for k in 1:3
        uvws[k] = r1[k]*ai1 + r2[k]*ai2

        rr1 = (r1[k]+r2[k])/r1eps - r1[k]*(rdr+rcsq)/r1eps^3 - r2[k]/r2eps
        rr2 = (r1[k]+r2[k])/r2eps - r2[k]*(rdr+rcsq)/r2eps^3 - r1[k]/r1eps

        rrt = 2.0*r1[k]*(r2sq - rdr) + 2.0*r2[k]*(r1sq - rdr)

        aj1 = (rr1 - ai1*rrt) / den
        aj2 = (rr2 - ai2*rrt) / den

        for j in 1:3
            uvwd[k, j] = -aj1*r1[j] - aj2*r2[j]
        end
        uvwd[k, k] -= ai1 + ai2
    end

    # scale by 1/(4π) with Mach correction on x-component
    uvws[1] *= PI4INV / beta
    uvws[2] *= PI4INV
    uvws[3] *= PI4INV
    for l in 1:3
        uvwd[1, l] *= PI4INV / beta
        uvwd[2, l] *= PI4INV
        uvwd[3, l] *= PI4INV
    end

    return uvws, uvwd
end

# ──────────────────────────────────────────────────────────────
# VSRD — Velocity influence matrix from body sources
# ──────────────────────────────────────────────────────────────

"""
    vsrd(vl, config, src_u, dbl_u, points) → wc_u

Compute body-source/doublet velocity at a set of control points.
Returns wc_u[3, npoints, 6] velocity per unit freestream component.
Matching Fortran VSRD in aic.f.
"""
function vsrd(vl::VortexLattice, config::AVLConfig,
              src_u::Matrix{Float64}, dbl_u::Array{Float64,3},
              points::Vector{NTuple{3,Float64}})
    nc = length(points)
    nu = 6
    betm = sqrt(max(1.0 - config.mach^2, 0.01))

    wc_u = zeros(3, nc, nu)

    iysym = config.iysym
    izsym = config.izsym
    fysym = Float64(iysym)
    fzsym = Float64(izsym)
    yoff = 2.0 * config.ysym
    zoff = 2.0 * config.zsym

    l_offset = 0
    for (ibody, nodes) in enumerate(vl.body_nodes)
        nvb = length(nodes)
        nvb < 2 && (l_offset += nvb; continue)

        for ilseg in 1:nvb-1
            l = l_offset + ilseg  # segment index in src_u
            n1 = nodes[ilseg]
            n2 = nodes[ilseg + 1]

            # core radius
            ravg = sqrt(0.5*(n2.radius^2 + n1.radius^2))
            rlavg = sqrt((n2.pos[1]-n1.pos[1])^2 +
                         (n2.pos[2]-n1.pos[2])^2 +
                         (n2.pos[3]-n1.pos[3])^2)
            if config.srcore > 0
                rcore = config.srcore * ravg
            else
                rcore = abs(config.srcore) * rlavg
            end

            for i in 1:nc
                rc = points[i]

                # ── Real segment ──
                vsrc, vdbl = srdvelc(rc[1], rc[2], rc[3],
                                     n1.pos[1], n1.pos[2], n1.pos[3],
                                     n2.pos[1], n2.pos[2], n2.pos[3],
                                     betm, rcore)
                for iu in 1:nu
                    for k in 1:3
                        wc_u[k,i,iu] += vsrc[k]*src_u[l,iu] +
                                         vdbl[k,1]*dbl_u[1,l,iu] +
                                         vdbl[k,2]*dbl_u[2,l,iu] +
                                         vdbl[k,3]*dbl_u[3,l,iu]
                    end
                end

                # ── Y-symmetry image ──
                if iysym != 0
                    vsrc_y, vdbl_y = srdvelc(rc[1], rc[2], rc[3],
                                             n1.pos[1], yoff-n1.pos[2], n1.pos[3],
                                             n2.pos[1], yoff-n2.pos[2], n2.pos[3],
                                             betm, rcore)
                    for iu in 1:nu
                        for k in 1:3
                            wc_u[k,i,iu] += (vsrc_y[k]*src_u[l,iu] +
                                              vdbl_y[k,1]*dbl_u[1,l,iu] -
                                              vdbl_y[k,2]*dbl_u[2,l,iu] +
                                              vdbl_y[k,3]*dbl_u[3,l,iu]) * fysym
                        end
                    end
                end

                # ── Z-symmetry image ──
                if izsym != 0
                    vsrc_z, vdbl_z = srdvelc(rc[1], rc[2], rc[3],
                                             n1.pos[1], n1.pos[2], zoff-n1.pos[3],
                                             n2.pos[1], n2.pos[2], zoff-n2.pos[3],
                                             betm, rcore)
                    for iu in 1:nu
                        for k in 1:3
                            wc_u[k,i,iu] += (vsrc_z[k]*src_u[l,iu] +
                                              vdbl_z[k,1]*dbl_u[1,l,iu] +
                                              vdbl_z[k,2]*dbl_u[2,l,iu] -
                                              vdbl_z[k,3]*dbl_u[3,l,iu]) * fzsym
                        end
                    end

                    # ── YZ combined image ──
                    if iysym != 0
                        vsrc_yz, vdbl_yz = srdvelc(rc[1], rc[2], rc[3],
                                                    n1.pos[1], yoff-n1.pos[2], zoff-n1.pos[3],
                                                    n2.pos[1], yoff-n2.pos[2], zoff-n2.pos[3],
                                                    betm, rcore)
                        for iu in 1:nu
                            for k in 1:3
                                wc_u[k,i,iu] += (vsrc_yz[k]*src_u[l,iu] +
                                                  vdbl_yz[k,1]*dbl_u[1,l,iu] -
                                                  vdbl_yz[k,2]*dbl_u[2,l,iu] -
                                                  vdbl_yz[k,3]*dbl_u[3,l,iu]) * fysym * fzsym
                            end
                        end
                    end
                end
            end
        end
        l_offset += nvb
    end

    return wc_u
end

# ──────────────────────────────────────────────────────────────
# BDFORC — Body force computation
# ──────────────────────────────────────────────────────────────

"""
    body_forces!(sol, vl, config, src, src_u)

Compute forces on body source-line segments and add to solution totals.
Matching Fortran BDFORC in aero.f.
"""
function body_forces!(sol::AVLSolution, vl::VortexLattice, config::AVLConfig,
                      src::Vector{Float64}, src_u::Matrix{Float64})
    betm = sqrt(max(1.0 - config.mach^2, 0.01))
    sina = sin(sol.alpha)
    cosa = cos(sol.alpha)
    sref = config.sref
    bref = config.bref
    cref = config.cref
    xyzref = config.xyzref
    vinf = sol.vinf
    wrot = sol.wrot

    l_offset = 0
    for (ibody, nodes) in enumerate(vl.body_nodes)
        nvb = length(nodes)
        nvb < 2 && (l_offset += nvb; continue)

        cdbdy = 0.0; cybdy = 0.0; clbdy = 0.0
        cfbdy = [0.0, 0.0, 0.0]
        cmbdy = [0.0, 0.0, 0.0]
        cdbdy_u = zeros(6); cybdy_u = zeros(6); clbdy_u = zeros(6)
        cfbdy_u = zeros(3, 6); cmbdy_u = zeros(3, 6)

        for ilseg in 1:nvb-1
            l = l_offset + ilseg
            n1 = nodes[ilseg]
            n2 = nodes[ilseg + 1]

            # segment vector (Mach-corrected x)
            drl = ((n2.pos[1]-n1.pos[1])/betm,
                    n2.pos[2]-n1.pos[2],
                    n2.pos[3]-n1.pos[3])
            drlmag = sqrt(drl[1]^2 + drl[2]^2 + drl[3]^2)
            drlmi = drlmag > 0.0 ? 1.0/drlmag : 0.0

            esl = (drl[1]*drlmi, drl[2]*drlmi, drl[3]*drlmi)

            # segment midpoint relative to reference
            rrot = (0.5*(n2.pos[1]+n1.pos[1]) - xyzref[1],
                    0.5*(n2.pos[2]+n1.pos[2]) - xyzref[2],
                    0.5*(n2.pos[3]+n1.pos[3]) - xyzref[3])

            # rotation velocity at midpoint
            vrot = cross3(rrot, wrot)

            # effective velocity
            veff = ((vinf[1] + vrot[1])/betm,
                     vinf[2] + vrot[2],
                     vinf[3] + vrot[3])

            # veff sensitivity to freestream components
            veff_u = zeros(3, 6)
            veff_u[1,1] = 1.0/betm; veff_u[2,2] = 1.0; veff_u[3,3] = 1.0
            for iu in 4:6
                wrot_u = [0.0, 0.0, 0.0]
                wrot_u[iu-3] = 1.0
                vrot_u = cross3(rrot, (wrot_u[1], wrot_u[2], wrot_u[3]))
                veff_u[1,iu] = vrot_u[1]/betm
                veff_u[2,iu] = vrot_u[2]
                veff_u[3,iu] = vrot_u[3]
            end

            # axial component
            us = veff[1]*esl[1] + veff[2]*esl[2] + veff[3]*esl[3]

            # force from normal velocity × source strength
            fb = zeros(3)
            fb_u = zeros(3, 6)
            for k in 1:3
                un = veff[k] - us*esl[k]
                fb[k] = un * src[l]

                for iu in 1:6
                    us_u = veff_u[1,iu]*esl[1] + veff_u[2,iu]*esl[2] + veff_u[3,iu]*esl[3]
                    un_u = veff_u[k,iu] - us_u*esl[k]
                    fb_u[k,iu] = un*src_u[l,iu] + un_u*src[l]
                end
            end

            # moments about reference point
            mb = cross3(rrot, (fb[1], fb[2], fb[3]))

            # accumulate body forces/moments
            cdbdy += ( fb[1]*cosa + fb[3]*sina) * 2.0/sref
            cybdy +=   fb[2] * 2.0/sref
            clbdy += (-fb[1]*sina + fb[3]*cosa) * 2.0/sref

            for k in 1:3
                cfbdy[k] += fb[k] * 2.0/sref
            end
            cmbdy[1] += mb[1] * 2.0/sref / bref
            cmbdy[2] += mb[2] * 2.0/sref / cref
            cmbdy[3] += mb[3] * 2.0/sref / bref

            for iu in 1:6
                cdbdy_u[iu] += ( fb_u[1,iu]*cosa + fb_u[3,iu]*sina) * 2.0/sref
                cybdy_u[iu] +=   fb_u[2,iu] * 2.0/sref
                clbdy_u[iu] += (-fb_u[1,iu]*sina + fb_u[3,iu]*cosa) * 2.0/sref
                mb_u = cross3(rrot, (fb_u[1,iu], fb_u[2,iu], fb_u[3,iu]))
                for k in 1:3
                    cfbdy_u[k,iu] += fb_u[k,iu] * 2.0/sref
                end
                cmbdy_u[1,iu] += mb_u[1] * 2.0/sref / bref
                cmbdy_u[2,iu] += mb_u[2] * 2.0/sref / cref
                cmbdy_u[3,iu] += mb_u[3] * 2.0/sref / bref
            end
        end

        # add body forces to solution totals
        ca = cosa; sa = sina
        sol.cl  += clbdy
        sol.cd  += cdbdy
        sol.cy  += cybdy
        sol.cdi += cdbdy
        sol.cfx += cfbdy[1]; sol.cfy += cfbdy[2]; sol.cfz += cfbdy[3]
        sol.cmx += cmbdy[1]; sol.cmy += cmbdy[2]; sol.cmz += cmbdy[3]

        # add body force sensitivities
        for iu in 1:6
            sol.cl_u[iu] += clbdy_u[iu]
            sol.cd_u[iu] += cdbdy_u[iu]
            sol.cy_u[iu] += cybdy_u[iu]
            sol.cmx_u[iu] += cmbdy_u[1,iu]
            sol.cmy_u[iu] += cmbdy_u[2,iu]
            sol.cmz_u[iu] += cmbdy_u[3,iu]
        end

        l_offset += nvb
    end
end

"""
    setup_body!(vl, config) → (src_u, dbl_u, wcsrd_u, wvsrd_u)

Complete body setup: build nodes, compute source/doublet strengths,
compute velocity influence at control points (wcsrd_u) and vortex midpoints (wvsrd_u).
Matching Fortran's two VSRD calls in asetup.f SETUP.
"""
function setup_body!(vl::VortexLattice, config::AVLConfig)
    makebody!(vl, config)

    vl.nbody == 0 && return zeros(0,6), zeros(3,0,6), zeros(3,0,6), zeros(3,0,6)

    # compute unit source/doublet strengths
    src_u, dbl_u = srdset(vl, config)

    nv = vl.nvor

    # control points from vortex lattice (for BC RHS)
    cpoints = NTuple{3,Float64}[]
    for i in 1:nv
        push!(cpoints, vl.elements[i].rc)
    end
    wcsrd_u = vsrd(vl, config, src_u, dbl_u, cpoints)

    # vortex midpoints from vortex lattice (for force computation)
    vpoints = NTuple{3,Float64}[]
    for i in 1:nv
        push!(vpoints, vl.elements[i].rv)
    end
    wvsrd_u = vsrd(vl, config, src_u, dbl_u, vpoints)

    return src_u, dbl_u, wcsrd_u, wvsrd_u
end

"""
    compute_body_src(src_u, vinf, wrot) → src

Compute actual source strengths from unit solutions and actual freestream.
"""
function compute_body_src(src_u::Matrix{Float64},
                          vinf::NTuple{3,Float64}, wrot::NTuple{3,Float64})
    nl = size(src_u, 1)
    nl == 0 && return Float64[]
    q = [vinf[1], vinf[2], vinf[3], wrot[1], wrot[2], wrot[3]]
    return src_u * q
end
