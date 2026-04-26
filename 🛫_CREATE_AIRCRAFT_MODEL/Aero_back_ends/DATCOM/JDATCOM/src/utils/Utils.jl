module Utils

include("Constants.jl")
include("MathUtils.jl")
include("Interpolation.jl")
include("TableLookup.jl")
include("Atmosphere.jl")

using .Constants
using .MathUtils
using .Interpolation
using .TableLookup
using .Atmosphere

export PI
export DEG
export RAD
export UNUSED
export KAND
export get_constants_dict

export arcsin
export arccos
export area1
export area2
export det4
export solve_linear
export trapz_integrate
export linear_interp
export sign

export asmint
export bilinear_interp
export TableInterpolator
export lookup

export fig26
export fig53a
export fig60b
export fig68
export DatcomTableManager
export load_table!
export get_table_manager

export AtmosphereModel
export calculate
export get_properties

const PI = Constants.PI
const DEG = Constants.DEG
const RAD = Constants.RAD
const UNUSED = Constants.UNUSED
const KAND = Constants.KAND

const get_constants_dict = Constants.get_constants_dict

const arcsin = MathUtils.arcsin
const arccos = MathUtils.arccos
const area1 = MathUtils.area1
const area2 = MathUtils.area2
const det4 = MathUtils.det4
const solve_linear = MathUtils.solve_linear
const trapz_integrate = MathUtils.trapz_integrate
const linear_interp = MathUtils.linear_interp
const sign = MathUtils.sign

const asmint = Interpolation.asmint
const bilinear_interp = Interpolation.bilinear_interp
const TableInterpolator = Interpolation.TableInterpolator
const lookup = Interpolation.lookup

const fig26 = TableLookup.fig26
const fig53a = TableLookup.fig53a
const fig60b = TableLookup.fig60b
const fig68 = TableLookup.fig68
const DatcomTableManager = TableLookup.DatcomTableManager
const load_table! = TableLookup.load_table!
const get_table_manager = TableLookup.get_table_manager

const AtmosphereModel = Atmosphere.AtmosphereModel
const calculate = Atmosphere.calculate
const get_properties = Atmosphere.get_properties

end
