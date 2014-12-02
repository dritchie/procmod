local S = terralib.require("qs.lib.std")
local LS = terralib.require("std")
local generate = terralib.require("generate")
local globals = terralib.require("globals")
local procmod = terralib.require("procmod")

local time = terralib.currenttimeinseconds


-- Get the 'base' name of the program (minus _future, if it was provided)
local progmodule = globals.config.program
local fi = string.find(progmodule, "_future")
if fi then
	progmodule = string.sub(progmodule, 1, fi-1)
end

-- TODO: Move these to config file?
local outfilename = "experiments/smc_vs_mh.csv"
local startNumSamps = 100
local endNumSamps = 3000
local stepNumSamps = 100

-- Set up persistent variables we'll need
local methods = {"smc", "smc_fixedOrder", "mh"}
local iters = (endNumSamps - startNumSamps)/stepNumSamps
local generations = global(S.Vector(S.Vector(procmod.Sample)))
LS.luainit(generations:get())
local f = io.open(outfilename, "w")
f:write("method,numSamps,time,avgScore,maxScore\n")

-- Handling one method
local function doMethod(method, numSamps, record)
	print(string.format("=== method: %s, numSamps: %u ===", method, numSamps))
	-- Set up config
	if string.find(method, "smc") then
		globals.config.method = "smc"
		globals.config.program = string.format("%s_future", progmodule)
		globals.config.smc_nParticles = numSamps
		if method == "smc_fixedOrder" then
			globals.config.futureImpl = "eager"
		else
			globals.config.futureImpl = "stochastic"
		end
	else
		globals.config.method = "mh"
		globals.config.program = progmodule
		globals.config.mh_nSamples = numSamps
	end
	-- Run it and collect timing and score info
	local g = generations:getpointer()
	local t0 = time()
	generate(g)
	local t1 = time()
	if record then
		local avgscore = 0
		local maxscore = -math.huge
		local s = g:get(g:size()-1)
		local n = tonumber(s:size())
		for i=0,n-1 do
			local score = s:get(i).logprob
			avgscore = avgscore + score
			maxscore = math.max(maxscore, score)
		end
		avgscore = avgscore / n
		f:write(string.format("%s,%u,%g,%g,%g\n",
			method, numSamps, t1-t0, avgscore, maxscore))
	end
end

-- Run one iteration of all methods to make sure everything is compiled
-- (This is so our timings don't include JIT time)
print("===== Preliminary runs to JIT everything =====")
for _,method in ipairs(methods) do
	doMethod(method, 1, false)
end

-- Now actually run stuff for reals
print()
print("===== Data collection runs =====")
for numSamps=startNumSamps,endNumSamps,stepNumSamps do
	for _,method in ipairs(methods) do
		doMethod(method, numSamps, true)
	end
end

-- TODO: I should do multiple runs of each one and plot the mean/variance...
-- TODO: Adjust the factor weights for MH, but correct the score to be comparable with smc?


f:close()
