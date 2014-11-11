local S = terralib.require("qs.lib.std")
local procmod = terralib.require("lua.procmod")

---------------------------------------------------------------

local program = terralib.require("lua.spaceship")

---------------------------------------------------------------

local N_PARTICLES = 200
local RECORD_HISTORY = true
local function run(generations)
	procmod.SIR(program, N_PARTICLES, generations, RECORD_HISTORY, true)
end
local runterra = terralib.cast({&S.Vector(S.Vector(procmod.Sample))}->{}, run)
return terra(generations: &S.Vector(S.Vector(procmod.Sample)))
	generations:clear()
	runterra(generations)
end