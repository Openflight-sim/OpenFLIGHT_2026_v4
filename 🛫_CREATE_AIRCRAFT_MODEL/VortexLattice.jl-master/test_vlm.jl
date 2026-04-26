using Pkg
Pkg.activate(".")
using StaticArrays, LinearAlgebra, VortexLattice
xle = [0.0, 1.0]
yle = [0.0, 1.0]
zle = [0.0, 0.0]
chord = [1.0, 0.5]
theta = [0.0, 0.0]
phi = [0.0, 0.0]
grids, ratios = VortexLattice.wing_to_grid(xle, yle, zle, chord, theta, phi, 10, 5)
system = VortexLattice.System([grids]; ratios=[ratios])
ref = VortexLattice.Reference(1.0, 1.0, 1.0, [0.0, 0.0, 1.0], 1.0)
fs = VortexLattice.Freestream(1.0, 0.1, 0.0, zeros(3))
VortexLattice.steady_analysis!(system, ref, fs; symmetric=[false], surface_id=[1])
CF, CM = VortexLattice.body_forces(system; frame=VortexLattice.Wind())
dCF, dCM = VortexLattice.stability_derivatives(system)
println("Success!")
