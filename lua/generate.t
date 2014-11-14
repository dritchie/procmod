local S = terralib.require("qs.lib.std")
local procmod = terralib.require("lua.procmod")

---------------------------------------------------------------

-- local program = terralib.require("lua.spaceship")
local program = terralib.require("lua.spaceship_future")

---------------------------------------------------------------

local opts = {
	nParticles = 200,
	recordHistory = true,
	verbose = true
}
local function run(generations)
	procmod.SIR(program, generations, opts)
end
local runterra = terralib.cast({&S.Vector(S.Vector(procmod.Sample))}->{}, run)
return terra(generations: &S.Vector(S.Vector(procmod.Sample)))
	generations:clear()
	runterra(generations)
end