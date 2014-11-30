local S = terralib.require("qs.lib.std")
local procmod = terralib.require("procmod")
local globals = terralib.require("globals")
local future = terralib.require("prob.future")


local program = terralib.require(globals.config.program)

future.setImpl(globals.config.futureImpl)

local smcopts = {
	nParticles = globals.config.smc_nParticles,

	-- doAnneal = true,
	-- nAnnealSteps = 20,
	-- annealStartTemp = 100,

	-- doFunnel = true,
	-- nFunnelSteps = 30,
	-- funnelStartNum = 5000,
	-- funnelEndNum = 200,
	
	recordHistory = globals.config.smc_recordHistory,
	verbose = globals.config.smc_verbose
}

local mhopts = {
	nSamples = globals.config.mh_nSamples,
	verbose = globals.config.mh_verbose
}

local function run(generations)
	local method = globals.config.method
	if method == "smc" then
		procmod.SIR(program, generations, smcopts)
	elseif method == "mh" then
		procmod.MH(program, generations, mhopts)
	elseif method == "reject" then
		procmod.RejectionSample(program, generations, 1)
	elseif method == "forward" then
		procmod.ForwardSample(program, generations, 1)
	else
		error(string.format("Unrecognized sampling method %s", method))
	end
end
local runterra = terralib.cast({&S.Vector(S.Vector(procmod.Sample))}->{}, run)
return terra(generations: &S.Vector(S.Vector(procmod.Sample)))
	generations:clear()
	runterra(generations)
end
