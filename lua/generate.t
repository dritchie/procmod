local S = terralib.require("qs.lib.std")
local procmod = terralib.require("lua.procmod")

---------------------------------------------------------------

-- local program = terralib.require("lua.models.spaceship")
-- local program = terralib.require("lua.models.spaceship_future")
-- local program = terralib.require("lua.models.weird_building")
local program = terralib.require("lua.models.weird_building_future")
-- local program = terralib.require("lua.models.random_walk")
-- local program = terralib.require("lua.models.cube_fractal")

---------------------------------------------------------------

local smcopts = {
	nParticles = 300,

	-- doAnneal = true,
	-- nAnnealSteps = 20,
	-- annealStartTemp = 100,

	-- doFunnel = true,
	-- nFunnelSteps = 30,
	-- funnelStartNum = 5000,
	-- funnelEndNum = 200,
	
	recordHistory = true,
	verbose = true
}

local mhopts = {
	nSamples = 3000,
	verbose = true
}

local function run(generations)
	procmod.SIR(program, generations, smcopts)
	-- procmod.MH(program, generations, mhopts)
	-- procmod.RejectionSample(program, generations, 1)
	-- procmod.ForwardSample(program, generations, 1)
end
local runterra = terralib.cast({&S.Vector(S.Vector(procmod.Sample))}->{}, run)
return terra(generations: &S.Vector(S.Vector(procmod.Sample)))
	generations:clear()
	runterra(generations)
end
