local S = terralib.require("qs.lib.std")
local procmod = terralib.require("procmod")
local globals = terralib.require("globals")
local future = terralib.require("prob.future")


local function run(generations)

	local progname = globals.config.program
	assert(not string.find(progname, "_future"),
		string.format("Config file should specify the *base* name of the model program; given name was %s", progname))
	if globals.config.method == "smc" then
		progname = progname .. "_future"
	end
	local program = terralib.require(progname)

	future.setImpl(globals.config.futureImpl)

	local smcopts = {
		nParticles = globals.config.nSamples,		
		recordHistory = globals.config.smc_recordHistory,
		saveSampleValues = globals.config.saveSampleValues,
		verbose = globals.config.verbose
	}

	local mhopts = {
		nSamples = globals.config.nSamples,
		timeBudget = globals.config.mh_timeBudget,
		saveSampleValues = globals.config.saveSampleValues,
		verbose = globals.config.verbose
	}

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

local function rerun(generations, index)
	procmod.HighResRerunRecordedTrace(generations, index)
end
local rerunterra = terralib.cast({&S.Vector(S.Vector(procmod.Sample)), uint}->{}, rerun)

return
{
	generate = terra(generations: &S.Vector(S.Vector(procmod.Sample)))
		generations:clear()
		runterra(generations)
	end,
	highResRerun = terra(generations: &S.Vector(S.Vector(procmod.Sample)), index: uint)
		rerunterra(generations, index)
	end
}



