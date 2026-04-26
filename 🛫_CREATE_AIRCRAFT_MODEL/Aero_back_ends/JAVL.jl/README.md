# JAVL.jl — Julia Athena Vortex Lattice

A pure Julia reimplementation of Mark Drela's [AVL (Athena Vortex Lattice)](https://web.mit.edu/drela/Public/web/avl/) 3.52 aerodynamic solver.

JAVL.jl implements the Vortex Lattice Method (VLM) for computing aerodynamic characteristics of arbitrary configurations of lifting surfaces and bodies. It reads the same `.avl` input files as the original Fortran code and produces matching results.

## Validation

Validated against Fortran AVL 3.52 across **all 55 test cases** from the AVL distribution at &alpha; = 5&deg;:

| Metric | Mean Error | Max Error | Median Error |
|--------|-----------|-----------|-------------|
| C<sub>L</sub> | 0.08% | 0.84% | 0.02% |
| C<sub>Dff</sub> | 0.10% | 0.87% | 0.00% |
| C<sub>m</sub> | 2.24% | 28.26%&dagger; | 0.18% |

**55/55 cases solved. 55/55 within 1% C<sub>L</sub> error.**

&dagger; **Important note on C<sub>m</sub> relative errors:** The maximum 28.26% relative error occurs in the `supra0` case, where the Fortran reference C<sub>m</sub> is only &minus;0.0202 and Julia computes &minus;0.0145 &mdash; an absolute difference of just **0.0057**. This tiny discrepancy is amplified by the near-zero denominator when computing relative error. All supra-family cases (supra, supra0, suprad, suprabad, supra-big) have total pitching moments close to zero (|C<sub>m</sub>| &lt; 0.04), so even absolute differences of O(10<sup>&minus;3</sup>) produce large-looking percentages. The median C<sub>m</sub> relative error across all 55 cases is just **0.18%**, and the absolute C<sub>m</sub> agreement is excellent throughout.

See [docs/validation_report.html](docs/validation_report.html) for the full comparison report.

## Features

- **Complete VLM solver** — horseshoe vortex kernel, AIC matrix assembly, LU factorization
- **Trefftz-plane analysis** — far-field induced drag and span efficiency
- **Body source/doublet model** — axisymmetric fuselage representation
- **Trim iteration** — Newton solver for constrained operating points (set alpha, CL, Cm, etc.)
- **Stability derivatives** — full set of force/moment sensitivities w.r.t. alpha, beta, p, q, r
- **Control surfaces** — deflection scheduling with hinge moment computation
- **Viscous drag polars** — piecewise parabolic CD(CL) via CDCL keyword
- **All symmetry options** — Y-symmetry, Z-symmetry, Z-image (ground effect)
- **Airfoil camber** — NACA 4-digit and arbitrary airfoil files (AFIL/AFILE)
- **Design variables** — parametric geometry variation
- **Zero dependencies** — only Julia standard library (LinearAlgebra, Printf)

## Quick Start

```julia
include("src/AVL.jl")
using .AVL

# Load an AVL configuration file
config = AVL.read_avl("validation/cases/vanilla.avl")

# Build the vortex lattice
vl = AVL.build_lattice(config)

# Set up body model (if bodies present)
src_u_kw = nothing; wcsrd_u = nothing
if !isempty(config.bodies)
    _s, _d, _wc, _wv = AVL.setup_body!(vl, config)
    src_u_kw = size(_s, 1) > 0 ? _s : nothing
    wcsrd_u  = size(_wc, 2) > 0 ? _wc : nothing
end

# Build and factorize AIC matrix
aic = AVL.setup_aic(vl, config)

# Solve unit-freestream circulations
gam_u0, gam_u_d = AVL.solve_unit_rhs(vl, config, aic; wcsrd_u=wcsrd_u)

# Define operating point: alpha = 5 degrees
sol = AVL.AVLSolution(vl.nvor, vl.ncontrol, vl.nstrip)
rc = AVL.RunCase(vl.ncontrol)
rc.icon[AVL.IVALFA] = AVL.ICALFA
rc.conval[AVL.ICALFA] = deg2rad(5.0)

# Solve
AVL.exec_case!(sol, vl, config, aic, gam_u0, gam_u_d, rc; src_u=src_u_kw)

# Results
println("CL   = $(round(sol.cl, digits=5))")
println("CDi  = $(round(sol.cdi, digits=6))")
println("CDff = $(round(sol.cdff, digits=6))")
println("Cm   = $(round(sol.cmy, digits=5))")
println("e    = $(round(sol.spanef, digits=4))")
```

### Trim to a target CL

```julia
# Find alpha for CL = 0.5
rc.icon[AVL.IVALFA] = AVL.ICCL      # alpha free, constrained to CL
rc.conval[AVL.ICCL] = 0.5            # target CL

AVL.exec_case!(sol, vl, config, aic, gam_u0, gam_u_d, rc; src_u=src_u_kw)
println("Alpha = $(round(rad2deg(sol.alpha), digits=3)) deg for CL = $(round(sol.cl, digits=4))")
```

## Repository Structure

```
JAVL.jl/
  src/                      Julia source code
    AVL.jl                    Main module
    types.jl                  Data structures
    input.jl                  .avl file parser
    geometry.jl               Vortex lattice construction
    aic.jl                    AIC matrix & vortex kernel
    solver.jl                 LU solve & unit solutions
    aero.jl                   Near-field forces (Kutta-Joukowski)
    trefftz.jl                Trefftz-plane drag integration
    trim.jl                   Newton trim iteration
    body.jl                   Body source/doublet model
    splines.jl                Cubic spline interpolation
    airfoil.jl                Airfoil camber extraction
    spacing.jl                Panel spacing (SPACER, CSPACER)
    math_utils.jl             Vector math helpers
    mass.jl, output.jl,       Stubs for future features
    driver.jl
  test/
    test_all_cases.jl         Full 55-case validation suite
    avl_reference.csv         Fortran AVL reference data
  validation/
    cases/                    All 55 .avl files + airfoil/body .dat files
    reference/
      avl3.51-32.exe          Fortran AVL 3.52 executable (Windows 32-bit)
      avl_reference.csv       Reference data
      generate_reference.sh   Script to regenerate reference data
  docs/
    validation_report.html    Detailed comparison report
    user_manual.html          Comprehensive user manual
```

## Input File Format

JAVL.jl reads standard AVL `.avl` files. The format includes:

- **Header** — title, Mach number, symmetry flags, reference quantities (Sref, Cref, Bref), moment reference point, CDo
- **SURFACE** blocks — lifting surfaces with chordwise/spanwise paneling
- **SECTION** entries — wing sections with position, chord, incidence, optional airfoil (AFIL/NACA)
- **BODY** blocks — axisymmetric bodies defined by source/doublet line models
- **CONTROL** — control surface definitions with hinge location and axis
- **Keywords** — YDUPLICATE, SCALE, TRANSLATE, ANGLE, NOWAKE, NOALBE, NOLOAD, CDCL, CLAF, DESIGN

See [docs/user_manual.html](docs/user_manual.html) for complete format documentation.

## Solution Outputs

The `AVLSolution` struct contains:

| Field | Description |
|-------|-------------|
| `sol.cl`, `sol.cd`, `sol.cy` | Stability-axis force coefficients |
| `sol.cfx`, `sol.cfy`, `sol.cfz` | Body-axis force coefficients |
| `sol.cmx`, `sol.cmy`, `sol.cmz` | Moment coefficients about reference point |
| `sol.cdi`, `sol.cdv` | Induced and viscous drag components |
| `sol.clff`, `sol.cdff` | Trefftz-plane (far-field) lift and drag |
| `sol.spanef` | Span efficiency factor (Oswald e) |
| `sol.gam[i]` | Circulation at each vortex element |
| `sol.dcp[i]` | Delta-Cp at each element |
| `sol.strip_cl[j]` | Lift coefficient per spanwise strip |
| `sol.cl_u[1:6]` | dCL/d(u,v,w,p,q,r) stability derivatives |
| `sol.cmy_u[1:6]` | dCm/d(u,v,w,p,q,r) stability derivatives |
| `sol.alpha`, `sol.beta` | Converged angle of attack and sideslip |

## Running the Validation Suite

```bash
cd JAVL.jl
julia test/test_all_cases.jl
```

This runs all 55 `.avl` cases from `validation/cases/`, compares against the Fortran reference in `avl_reference.csv`, and prints a detailed comparison table with error statistics.

To regenerate the Fortran reference data (requires Windows):

```bash
cd validation/reference
bash generate_reference.sh
```

## Technical Details

### Algorithms

JAVL.jl faithfully reproduces the numerical algorithms of Fortran AVL 3.52:

- **Horseshoe vortex kernel** with Biot-Savart law and Scully R^4 core regularization
- **Cubic spline interpolation** with natural, specified, and zero-3rd-derivative end conditions
- **Spanwise spacing** via AVL's SPACER function (2N+1 cosine distribution with fudging for multi-section surfaces)
- **Chordwise spacing** via CSPACER with DTH1 = &pi;/(4N+2) increment
- **Airfoil camber extraction** via NORMIT normalization (translate + scale, no rotation)
- **Trefftz-plane integration** at strip control points for induced drag
- **Body source/doublet** line model with Mach-corrected velocity kernel

### Architecture

- Julia structs replace Fortran COMMON blocks
- `NTuple{3,Float64}` for immutable 3-vectors (zero allocation)
- LU factorization via Julia's LinearAlgebra (LAPACK)
- Single-module design (`AVL`) with no external dependencies

## Acknowledgments

Based on [AVL 3.52](https://web.mit.edu/drela/Public/web/avl/) by Mark Drela and Harold Youngren, MIT.

## License

GNU Affero General Public License v3.0 (AGPL-3.0). See LICENSE file for details.

The included `avl3.51-32.exe` binary is from the AVL 3.52 distribution and is subject to its own license terms.
