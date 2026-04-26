"""
    AVL.jl — Julia reimplementation of AVL (Athena Vortex Lattice) 3.52

A vortex-lattice aerodynamic solver for thin lifting surfaces.
Reads standard AVL input files (.avl, .mass, .run) and produces
equivalent solutions to the original Fortran code.
"""
module AVL

using LinearAlgebra
using Printf

# ── Utility modules ─────────────────────────────────────────────
include("math_utils.jl")
include("splines.jl")
include("airfoil.jl")
include("spacing.jl")

# ── Data structures ─────────────────────────────────────────────
include("types.jl")

# ── Input parsing ───────────────────────────────────────────────
include("input.jl")
include("mass.jl")

# ── Geometry construction ───────────────────────────────────────
include("geometry.jl")

# ── Body source/doublet model ──────────────────────────────────
include("body.jl")

# ── Aerodynamic influence coefficients ──────────────────────────
include("aic.jl")

# ── Solver setup and solution ───────────────────────────────────
include("solver.jl")

# ── Force and moment calculations ───────────────────────────────
include("aero.jl")
include("trefftz.jl")

# ── Trim iteration ─────────────────────────────────────────────
include("trim.jl")

# ── Output routines ─────────────────────────────────────────────
include("output.jl")

# ── Main driver ─────────────────────────────────────────────────
include("driver.jl")

export solve_case, read_avl, read_mass, read_runfile
export AVLConfig, RunCase, AVLSolution

end # module
