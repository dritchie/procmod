local S = require("qs.lib.std")
local LS = require("std")
local generate = require("generate").generate
local globals = require("globals")
local procmod = require("procmod")

local time = terralib.currenttimeinseconds

-- Seed the random number generator so we get different results per run
math.randomseed( time() )

-- Constants
local outfilename = arg[2] or "experiments/smc_vs_mh.csv"
local sampNums = {10, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000}
-- local sampNums = {700, 800, 900, 1000}
-- local numRuns = 10
local numRuns = 20

-- Set up persistent variables we'll need
local methods = {"smc", "smc_fixedOrder", "mh"}
local generations = global(S.Vector(S.Vector(procmod.Sample)))
LS.luainit(generations:getpointer())
local filemode = "w"
-- local filemode = "a"
local f = io.open(outfilename, filemode)
if filemode == "w" then
	f:write("method,numSamps,time,avgScore,maxScore\n")
end

-- We don't save sample values when we're recording this data
globals.config.saveSampleValues = false

-- Handling one method
-- Returns the time taken
local function doMethod(method, numSamps, record, timeBudget)
	print(string.format("=== method: %s, numSamps: %u ===", method, numSamps))
	-- Set up config
	if string.find(method, "smc") then
		globals.config.method = "smc"
		globals.config.nSamples = numSamps
		if method == "smc_fixedOrder" then
			globals.config.futureImpl = "eager"
		else
			globals.config.futureImpl = "stochastic"
		end
	else
		globals.config.method = "mh"
		if timeBudget then
			globals.config.nSamples = 1000000000000000
			globals.config.mh_timeBudget = timeBudget
		else
			globals.config.nSamples = numSamps
		end
		if method == "mhpt" then
			globals.config.parallelTempering = true
		end
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
		f:flush()
	end
	return t1 - t0
end

-- Need to boot up an OpenGL window, in case our score function needs
--    an OpenGL context.
local gl = require("gl.gl")
local terra ogl_main()
	var argc = 0
	gl.safeGlutInit(&argc, nil)
	gl.glutInitWindowSize(1, 1)
	gl.glutInitDisplayMode(gl.GLUT_RGB or gl.GLUT_DOUBLE or gl.GLUT_DEPTH)
	gl.glutCreateWindow("SMC vs. MH")
end
ogl_main()

-- Run one iteration of all methods to make sure everything is compiled
-- (This is so our timings don't include JIT time)
print("===== Preliminary runs to JIT everything =====")
for _,method in ipairs(methods) do
	doMethod(method, 1, false)
end

-- Now actually run stuff for reals
print()
print("===== Data collection runs =====")
for _,numSamps in ipairs(sampNums) do
	local timeBudget
	for _,method in ipairs(methods) do
		-- We drive MH's time budget by the average time taken by SMC
		if method == "smc" then
			local t = 0
			for i=1,numRuns do
				t = t + doMethod(method, numSamps, true)
			end
			timeBudget = t/numRuns
		else
			for i=1,numRuns do
				doMethod(method, numSamps, true, timeBudget)
			end
		end
	end
end


f:close()




