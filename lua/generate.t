local S = terralib.require("qs.lib.std")
local procmod = terralib.require("lua.procmod")

---------------------------------------------------------------

-- local program = terralib.require("lua.spaceship")
local program = terralib.require("lua.spaceship_future")

---------------------------------------------------------------

local opts = {
	nParticles = 2000,

	-- doAnneal = true,
	-- nAnnealSteps = 20,
	-- annealStartTemp = 100,

	-- doFunnel = true,
	-- nFunnelSteps = 20,
	-- funnelStartNum = 10000,
	-- funnelEndNum = 100,
	
	recordHistory = true,
	verbose = true
}
local function run(generations)
	procmod.SIR(program, generations, opts)
	-- procmod.RejectionSample(program, generations, opts.nParticles)
end
local runterra = terralib.cast({&S.Vector(S.Vector(procmod.Sample))}->{}, run)
return terra(generations: &S.Vector(S.Vector(procmod.Sample)))
	generations:clear()
	runterra(generations)
end
