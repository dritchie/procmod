local S = terralib.require("qs.lib.std")
local LS = terralib.require("std")
local generate = terralib.require("generate").generate
local globals = terralib.require("globals")
local procmod = terralib.require("procmod")

local time = terralib.currenttimeinseconds

-- Constants
local outfilename = arg[2] or "experiments/pcascadePipeSizes.csv"
local pipeSizes = {}
for n=50,1000,50 do table.insert(pipeSizes, n) end
local numRuns = 20

-- Set up persistent variables we'll need
local generations = global(S.Vector(S.Vector(procmod.Sample)))
LS.luainit(generations:getpointer())
local filemode = "w"
-- local filemode = "a"
local f = io.open(outfilename, filemode)
if filemode == "w" then
	f:write("nMax,time,avgScore,varScore,maxScore\n")
end

-- We don't save sample values when we're recording this data
globals.config.saveSampleValues = false

-- Need to boot up an OpenGL window, in case our score function needs
--    an OpenGL context.
local gl = terralib.require("gl.gl")
local terra ogl_main()
	var argc = 0
	gl.safeGlutInit(&argc, nil)
	gl.glutInitWindowSize(1, 1)
	gl.glutInitDisplayMode(gl.GLUT_RGB or gl.GLUT_DOUBLE or gl.GLUT_DEPTH)
	gl.glutCreateWindow("Particle Cascade Pipe Sizes Experiment")
end
ogl_main()

-- Where the work happens: run for a given pipe size, record timing and score info
local function dowork(nMax, record)
	print(string.format("   nMax = %d", nMax))
	globals.config.pcascade_nMax = nMax
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
		local varscore = 0
		for i=0,n-1 do
			local score = s:get(i).logprob
			varscore = varscore + (score-avgscore)*(score-avgscore)
		end
		varscore = varscore / n
		f:write(string.format("%d,%g,%g,%g,%g\n",
			nMax, t1-t0, avgscore, varscore, maxscore))
		f:flush()
	end
end

-- Run one iteration to make sure everything is JIT compiled
print("===== Preliminary run to JIT everything =====")
dowork(1, false)

-- Now run the actual experiment
print()
print("===== Data collection runs =====")
for _,nMax in ipairs(pipeSizes) do
	for i=1,numRuns do
		dowork(nMax, true)
	end
end