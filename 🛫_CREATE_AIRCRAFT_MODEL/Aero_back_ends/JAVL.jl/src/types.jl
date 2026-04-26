# ──────────────────────────────────────────────────────────────
# types.jl — Data structures for the AVL solver
# ──────────────────────────────────────────────────────────────

# ── Index constants (matching AINDEX.INC) ────────────────────
# Variable indices (operating variables)
const IVALFA = 1   # angle of attack
const IVBETA = 2   # sideslip angle
const IVROTX = 3   # roll rate p
const IVROTY = 4   # pitch rate q
const IVROTZ = 5   # yaw rate r
const IVTOT  = 5   # number of base variables

# Constraint indices
const ICALFA = 1   # alpha value
const ICBETA = 2   # beta value
const ICROTX = 3   # roll rate
const ICROTY = 4   # pitch rate
const ICROTZ = 5   # yaw rate
const ICCL   = 6   # CL
const ICCY   = 7   # CY
const ICMOMX = 8   # roll moment
const ICMOMY = 9   # pitch moment
const ICMOMZ = 10  # yaw moment
const ICTOT  = 10

# Parameter indices for run cases
const IPALFA  = 1
const IPBETA  = 2
const IPROTX  = 3
const IPROTY  = 4
const IPROTZ  = 5
const IPCL    = 6
const IPCD0   = 7
const IPPHI   = 8   # bank angle
const IPTHE   = 9   # elevation angle
const IPPSI   = 10  # heading angle
const IPMACH  = 11
const IPVEL   = 12
const IPRHO   = 13
const IPGEE   = 14
const IPTURN  = 15  # turn radius
const IPLOAD  = 16  # load factor
const IPXCG   = 17
const IPYCG   = 18
const IPZCG   = 19
const IPMASS  = 20
const IPIXX   = 21
const IPIYY   = 22
const IPIZZ   = 23
const IPIXY   = 24
const IPIYZ   = 25
const IPIZX   = 26
const IPCLA   = 27  # visc CL_a
const IPCLU   = 28  # visc CL_u
const IPCMA   = 29  # visc CM_a
const IPCMU   = 30  # visc CM_u
const IPTOT   = 30

# Number of freestream unit components: u, v, w, p, q, r
const NUMAX = 6

# ── Control surface definition ──────────────────────────────
mutable struct ControlDef
    name::String
    gain::Float64
    xhinge::Float64       # x/c hinge location (positive=TE, negative=LE)
    hvec::NTuple{3,Float64}  # hinge axis direction
    sgndup::Float64       # sign for YDUPLICATE'd surface
end

# ── Section definition (within a surface) ────────────────────
mutable struct SectionDef
    xle::Float64; yle::Float64; zle::Float64
    chord::Float64
    ainc::Float64          # incidence (degrees)
    nspan::Int             # override spanwise panels for this interval
    sspace::Float64        # override spanwise spacing

    # airfoil camber data
    xaf::Vector{Float64}   # x/c stations for camber
    yaf::Vector{Float64}   # camber y/c
    taf::Vector{Float64}   # thickness t/c
    naf::Int               # number of airfoil stations

    # control surfaces at this section
    controls::Vector{ControlDef}

    # design variables at this section
    design_names::Vector{String}
    design_gains::Vector{Float64}

    # lift curve slope factor
    claf::Float64

    # viscous polar (piecewise parabolic)
    cdcl::Vector{Float64}  # [CL1, CD1, CL2, CD2, CL3, CD3]
    has_cdcl::Bool
end

function SectionDef()
    SectionDef(0,0,0, 1,0, 0,0.0,
               Float64[], Float64[], Float64[], 0,
               ControlDef[], String[], Float64[],
               1.0, Float64[], false)
end

# ── Surface definition ──────────────────────────────────────
mutable struct SurfaceDef
    name::String
    component::Int         # component index
    nchord::Int            # chordwise panels
    cspace::Float64        # chordwise spacing parameter
    nspan::Int             # spanwise panels (0 = section-defined)
    sspace::Float64        # spanwise spacing parameter

    sections::Vector{SectionDef}

    yduplicate::Float64    # NaN if no duplication
    has_ydup::Bool

    scale::NTuple{3,Float64}
    translate::NTuple{3,Float64}
    angle_offset::Float64  # additional incidence (degrees)

    nowake::Bool           # no wake shedding
    noalbe::Bool           # no freestream alpha/beta effect
    noload::Bool           # exclude from load totals

    # surface-level CDCL (applied to all sections without their own)
    cdcl::Vector{Float64}
    has_cdcl::Bool

    # vortex core radius overrides
    vrcorec::Float64       # chord-based core fraction
    vrcorew::Float64       # width-based core fraction
end

function SurfaceDef(name::AbstractString="")
    SurfaceDef(String(name), 0, 8, 1.0, 0, 1.0,
               SectionDef[], NaN, false,
               (1.0, 1.0, 1.0), (0.0, 0.0, 0.0), 0.0,
               false, false, false,
               Float64[], false, -1.0, -1.0)
end

# ── Body definition ─────────────────────────────────────────
mutable struct BodyDef
    name::String
    nbody::Int
    bspace::Float64
    yduplicate::Float64
    has_ydup::Bool
    scale::NTuple{3,Float64}
    translate::NTuple{3,Float64}

    # body shape: centerline positions and radii
    xb::Vector{Float64}
    yb::Vector{Float64}   # usually 0
    zb::Vector{Float64}   # usually 0
    rb::Vector{Float64}   # radius at each node
end

function BodyDef(name::AbstractString="")
    BodyDef(String(name), 20, 1.0, NaN, false,
            (1.0,1.0,1.0), (0.0,0.0,0.0),
            Float64[], Float64[], Float64[], Float64[])
end

# ── Horseshoe vortex element ────────────────────────────────
struct VortexElement
    rv1::NTuple{3,Float64}  # left bound vortex endpoint
    rv2::NTuple{3,Float64}  # right bound vortex endpoint
    rv::NTuple{3,Float64}   # bound vortex midpoint
    rc::NTuple{3,Float64}   # control point (3/4 chord)
    enc::NTuple{3,Float64}  # normal vector at control point
    env::NTuple{3,Float64}  # normal vector at bound vortex
    dxv::Float64            # chordwise panel extent
    chord::Float64          # local chord
    slopec::Float64         # camber slope at control point
    slopev::Float64         # camber slope at bound vortex
    isurf::Int              # surface index
    istrip::Int             # strip index
    icomp::Int              # component index
end

# ── Strip (spanwise station) ────────────────────────────────
mutable struct Strip
    rle::NTuple{3,Float64}    # LE at strip center
    rle1::NTuple{3,Float64}   # LE at left edge
    rle2::NTuple{3,Float64}   # LE at right edge
    chord::Float64
    wstrip::Float64           # strip width (in y-z plane)
    ainc::Float64             # incidence (radians)
    ensy::Float64             # strip normal y-component in Trefftz plane
    ensz::Float64             # strip normal z-component in Trefftz plane
    isurf::Int                # surface index
    ifirst::Int               # first vortex element index in this strip
    nelem::Int                # number of chordwise elements
    has_wake::Bool            # whether this strip sheds a wake
    sees_freestream::Bool     # whether affected by alpha/beta
    contributes_load::Bool    # whether included in total loads

    # viscous polar
    cdcl::Vector{Float64}
    has_cdcl::Bool

    # results
    cnc::Float64              # c*Cn spanloading
    clstrip::Float64          # strip Cl
    cdstrip::Float64          # strip Cd (induced)
    cdvstrip::Float64         # strip Cd (viscous)
    cmstrip::Float64          # strip Cm about c/4
    cmle::Float64             # strip Cm about LE
    cp_xc::Float64            # center of pressure x/c
    dwwake::Float64           # wake downwash
end

function Strip()
    Strip((0,0,0),(0,0,0),(0,0,0), 1.0, 0.0, 0.0, 0.0, 1.0,
          0, 0, 0, true, true, true,
          Float64[], false,
          0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
end

# ── Body line element ───────────────────────────────────────
struct BodyNode
    pos::NTuple{3,Float64}  # position
    radius::Float64         # body radius
end

# ── Complete configuration ──────────────────────────────────
mutable struct AVLConfig
    title::String
    mach::Float64

    iysym::Int              # y-symmetry flag
    izsym::Int              # z-symmetry flag
    ysym::Float64           # y-symmetry plane
    zsym::Float64           # z-symmetry plane

    sref::Float64           # reference area
    cref::Float64           # reference chord
    bref::Float64           # reference span
    xyzref::NTuple{3,Float64}  # moment reference point

    cdref::Float64          # baseline profile drag

    surfaces::Vector{SurfaceDef}
    bodies::Vector{BodyDef}

    # global vortex core parameters
    vrcorec::Float64        # chord-based core fraction
    vrcorew::Float64        # width-based core fraction
    srcore::Float64         # source/doublet core

    # base directory for relative file paths
    basedir::String
end

function AVLConfig()
    AVLConfig("", 0.0, 0, 0, 0.0, 0.0,
              1.0, 1.0, 1.0, (0.0, 0.0, 0.0), 0.0,
              SurfaceDef[], BodyDef[],
              0.0, 2.0, 1.0, ".")
end

# ── Discretized geometry (built from AVLConfig) ─────────────
mutable struct VortexLattice
    nvor::Int               # total vortex elements
    nstrip::Int             # total strips
    nsurf::Int              # total surfaces (after duplication)

    elements::Vector{VortexElement}
    strips::Vector{Strip}

    # control surface data
    ncontrol::Int
    control_names::Vector{String}
    dcontrol::Matrix{Float64}   # (nvor, ncontrol) d(angle)/d(control)
    enc_d::Array{Float64,3}     # (3, nvor, ncontrol) normal vector sensitivity

    # design variable data
    ndesign::Int
    design_names::Vector{String}

    # surface info
    surf_ifrst::Vector{Int}     # first element in each surface
    surf_jfrst::Vector{Int}     # first strip in each surface
    surf_nj::Vector{Int}        # strips per surface
    surf_nk::Vector{Int}        # chordwise elements per surface
    surf_names::Vector{String}
    surf_comp::Vector{Int}      # component index per surface

    # body data
    nbody::Int
    body_nodes::Vector{Vector{BodyNode}}
    body_names::Vector{String}
end

function VortexLattice()
    VortexLattice(0, 0, 0,
                  VortexElement[], Strip[],
                  0, String[], zeros(0,0), zeros(0,0,0),
                  0, String[],
                  Int[], Int[], Int[], Int[], String[], Int[],
                  0, Vector{BodyNode}[], String[])
end

# ── Run case specification ──────────────────────────────────
mutable struct RunCase
    name::String
    number::Int

    # variable → constraint mapping: icon[iv] = constraint index
    icon::Vector{Int}       # length = IVTOT + ncontrol
    conval::Vector{Float64} # constraint target values (length = ICTOT + ncontrol)

    # all parameters
    parval::Vector{Float64} # length = IPTOT
end

function RunCase(ncontrol::Int=0)
    nvtot = IVTOT + ncontrol
    nctot = ICTOT + ncontrol
    rc = RunCase("", 1,
                 fill(0, nvtot),
                 zeros(nctot),
                 zeros(IPTOT))
    # defaults: each base variable constrained to its own value
    for iv in 1:IVTOT
        rc.icon[iv] = iv  # alpha→alpha, beta→beta, etc.
    end
    # control variables constrained to their deflection value
    for n in 1:ncontrol
        rc.icon[IVTOT+n] = ICTOT + n
    end
    # default parameters
    rc.parval[IPMACH] = 0.0
    rc.parval[IPVEL]  = 1.0
    rc.parval[IPRHO]  = 1.225
    rc.parval[IPGEE]  = 9.81
    rc.parval[IPMASS] = 1.0
    rc.parval[IPIXX]  = 1.0
    rc.parval[IPIYY]  = 1.0
    rc.parval[IPIZZ]  = 1.0
    return rc
end

# ── Solution data ───────────────────────────────────────────
mutable struct AVLSolution
    converged::Bool
    iterations::Int

    # operating point
    alpha::Float64          # angle of attack (rad)
    beta::Float64           # sideslip (rad)
    vinf::NTuple{3,Float64} # freestream velocity vector
    wrot::NTuple{3,Float64} # rotation rate (p, q, r)
    mach::Float64
    delcon::Vector{Float64} # control deflections (rad)

    # circulations
    gam::Vector{Float64}           # circulation per element
    gam_u::Matrix{Float64}         # (nvor, 6) unit circulations
    gam_d::Matrix{Float64}         # (nvor, ncontrol) control circulations

    # induced velocities at vortex midpoints
    wv::Matrix{Float64}            # (3, nvor) total velocity at vortex points

    # element delta-Cp
    dcp::Vector{Float64}

    # total forces (stability axes)
    cl::Float64; cd::Float64; cy::Float64
    cdi::Float64; cdv::Float64      # induced and viscous drag
    # total forces (body axes)
    cfx::Float64; cfy::Float64; cfz::Float64
    # total moments (body axes, about xyzref)
    cmx::Float64; cmy::Float64; cmz::Float64
    # stability-axis moments
    cmx_s::Float64; cmz_s::Float64  # Cl', Cn' (stability axes)

    # Trefftz plane
    clff::Float64; cdff::Float64; cyff::Float64
    spanef::Float64                 # span efficiency

    # hinge moments
    chinge::Vector{Float64}

    # sensitivity arrays (stability derivatives)
    cl_u::Vector{Float64}           # d(CL)/d(u,v,w,p,q,r)
    cd_u::Vector{Float64}
    cy_u::Vector{Float64}
    cmx_u::Vector{Float64}          # d(Cl)/d(...)
    cmy_u::Vector{Float64}          # d(Cm)/d(...)
    cmz_u::Vector{Float64}          # d(Cn)/d(...)

    cl_d::Vector{Float64}           # d(CL)/d(control)
    cd_d::Vector{Float64}
    cy_d::Vector{Float64}
    cmx_d::Vector{Float64}
    cmy_d::Vector{Float64}
    cmz_d::Vector{Float64}

    chinge_d::Matrix{Float64}       # (ncontrol, ncontrol) hinge moment sensitivities

    # per-strip results
    strip_cl::Vector{Float64}
    strip_cd::Vector{Float64}
    strip_cnc::Vector{Float64}      # c*Cn
    strip_dwwake::Vector{Float64}   # wake downwash
end

function AVLSolution(nvor::Int=0, ncontrol::Int=0, nstrip::Int=0)
    AVLSolution(false, 0,
                0.0, 0.0, (1.0,0.0,0.0), (0.0,0.0,0.0), 0.0,
                zeros(ncontrol),
                zeros(nvor), zeros(nvor, NUMAX), zeros(nvor, ncontrol),
                zeros(3, nvor), zeros(nvor),
                0,0,0, 0,0,  0,0,0,  0,0,0,  0,0,
                0,0,0, 0,
                zeros(ncontrol),
                zeros(NUMAX), zeros(NUMAX), zeros(NUMAX),
                zeros(NUMAX), zeros(NUMAX), zeros(NUMAX),
                zeros(ncontrol), zeros(ncontrol), zeros(ncontrol),
                zeros(ncontrol), zeros(ncontrol), zeros(ncontrol),
                zeros(ncontrol, ncontrol),
                zeros(nstrip), zeros(nstrip), zeros(nstrip), zeros(nstrip))
end
