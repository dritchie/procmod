local S = terralib.require("qs.lib.std")
local LS = terralib.require("std")
local trace = terralib.require("prob.trace")
local distrib = terralib.require("prob.distrib")
local util = terralib.require("util")

---------------------------------------------------------------

-- Sync points use exception handling
-- 'Error code' that that indicates whether the exception is due to
--    a sync point.
local SMC_SYNC_ERROR = {}

-- Profiling how much time is spent in trace replay
local traceReplayTime = 0
local traceReplayStart = 0
local function clearTraceReplayTime()
	traceReplayTime = 0
end
local function getTraceReplayTime()
	return traceReplayTime
end
local function startTraceReplayTimer()
	traceReplayStart = terralib.currenttimeinseconds()
end
local function stopTraceReplayTimer()
	local t = terralib.currenttimeinseconds()
	traceReplayTime = traceReplayTime + (t - traceReplayStart)
end

---------------------------------------------------------------

-- A particle stores information about how far a partial run of a program
--    has gotten.
-- A particle is parameterized by the type of trace we're using
local globalParticle = nil
local Particle = S.memoize(function(Trace)
	local Particle = LS.LObject()

	function Particle:init(program, ...)
		self.trace = Trace.alloc():init(program, ...)
		self.finished = false
		self.currSyncIndex = 1
		self.stopSyncIndex = 0
		self.lastStopSyncIndex = 0
		return self
	end

	function Particle:copy(other)
		self.trace = Trace.alloc():copy(other.trace)
		self.finished = other.finished
		self.currSyncIndex = other.currSyncIndex
		self.stopSyncIndex = other.stopSyncIndex
		self.lastStopSyncIndex = other.lastStopSyncIndex
		return self
	end

	function Particle:freeMemory()
		self.trace:freeMemory()
	end

	function Particle:isReplaying()
		return self.currSyncIndex <= self.lastStopSyncIndex
	end

	function Particle:sync()
		if self.currSyncIndex == self.stopSyncIndex then
			error(SMC_SYNC_ERROR)
		else
			local wasReplaying = self:isReplaying()
			self.currSyncIndex = self.currSyncIndex + 1
			if wasReplaying and not self:isReplaying() then
				stopTraceReplayTimer()
			end
		end
	end

	function Particle:step(nSteps)
		nSteps = nSteps or 1
		if not self.finished then
			local prevGlobalParticle = globalParticle
			globalParticle = self
			self.stopSyncIndex = self.stopSyncIndex + nSteps
			self.currSyncIndex = 1
			if self:isReplaying() then startTraceReplayTimer() end
			local succ, err = pcall(function() self.trace:run() end)
			if succ then
				self.finished = true
			elseif err ~= SMC_SYNC_ERROR then
				-- Propagate error if it's not due to a sync point
				error(err)
			end
			self.lastStopSyncIndex = self.stopSyncIndex
			globalParticle = prevGlobalParticle
		end
	end

	return Particle
end)

---------------------------------------------------------------

-- Different importance resampling algorithms
-- TODO: Potentially replace these with Terra code, if it has better perf?

local Resample = {}

function Resample.multinomial(particles, weights, n)
	local newparticles = {}
	for i=1,n do
		local idx = distrib.multinomial.sample(weights)
		table.insert(newparticles, particles[idx]:newcopy())
	end
	return newparticles
end

local function resampleStratified(particles, weights, n, systematic)
	local N = #weights
	local newparticles = {}
	-- Compute CDF of weight distribution
	local weightCDF = {weights[1]}
	for i=2,N do
		local wprev = weightCDF[#weightCDF]
		table.insert(weightCDF, wprev + weights[i])
	end
	-- Resample
	local u, U
	if systematic then
		u = math.random()
	else
		U = {}
		for i=1,N do
			table.insert(U, math.random())
		end
	end
	local cumOffspring = 0
	local scale = n/N 	-- If we're requesting more/fewer particles than we started with
	for i=1,N do
		local ri = N * (weightCDF[i] / weightCDF[N])
		local ki = math.min(math.floor(ri) + 1, N)
		if not systematic then
			u = U[ki]
		end
		local oi = math.min(math.floor((ri + u)*scale), N)
		-- cumOffspring must be non-decreasing
		oi = math.max(oi, cumOffspring)
		local numOffspring = oi - cumOffspring
		cumOffspring = oi
		for j=1,numOffspring do
			local np = particles[i]:newcopy()
			table.insert(newparticles, np)
		end
	end
	return newparticles
end

function Resample.stratified(particles, weights, n)
	return resampleStratified(particles, weights, n, false)
end

function Resample.systematic(particles, weights, n)
	return resampleStratified(particles, weights, n, true)
end

---------------------------------------------------------------

-- Sequential importance resampling
-- Options are:
--    * nParticles: How many particles to run
--    * resample: Which resampling alg to use
--    * verbose: Verbose output?
--    * beforeResample: Callback that does something with particles before resampling
--    * afterResample: Callback that does something with particles after resampling
--    * exit: Callback that does something with particles when everything is finished
local function SIR(program, args, opts)
	local function nop() end

	-- Extract options
	local nParticles = opts.nParticles or 200
	local resample = opts.resample or Resample.systematic
	local verbose = opts.verbose
	local beforeResample = opts.beforeResample or nop
	local afterResample = opts.afterResample or nop
	local exit = opts.exit or nop

	clearTraceReplayTime()

	-- Only need the simplest trace to do SIR
	local Trace = trace.FlatValueTrace

	-- Init particles
	local particles = {}
	local weights = {}
	for i=1,nParticles do
		-- Each particle gets a copy of any input args
		local argscopy = {}
		for _,a in ipairs(args) do
			local newa = LS.newcopy(a)
			table.insert(argscopy, newa)
		end
		local p = Particle(Trace).alloc():init(program, unpack(argscopy))
		table.insert(particles, p)
	end

	-- Step all particles forward in lockstep until they are all finished
	local t0 = terralib.currenttimeinseconds()
	local generation = 1
	repeat
		local numfinished = 0
		-- Step
		for i,p in ipairs(particles) do
			p:step(1)
			if p.finished then
				numfinished = numfinished + 1
			end
			weights[i] = p.trace.loglikelihood
		end
		local allfinished = (numfinished == nParticles)
		if verbose then
			io.write(string.format("Generation %u: Finished %u/%u particles.        \r",
				generation, numfinished, nParticles))
			io.flush()
		end
		-- Exponentiate weights
		util.expNoUnderflow(weights)
		-- Resampling
		beforeResample(particles)
		local newparticles = resample(particles, weights, nParticles)
		for _,p in ipairs(particles) do p:freeMemory() end
		particles = newparticles
		weights = {}
		afterResample(particles)
		generation = generation + 1
	until allfinished

	if verbose then
		local t1 = terralib.currenttimeinseconds()
		io.write("\n")
		print("Time:", t1 - t0)
		local trp = getTraceReplayTime()
		print(string.format("Time spent on trace replay: %g (%g%%)",
			trp, 100*(trp/(t1-t0))))
	end
	exit(particles)
end

---------------------------------------------------------------

return
{
	Resample = Resample,
	SIR = SIR,
	isReplaying = function()
		return globalParticle and globalParticle:isReplaying()
	end,
	sync = function()
		if globalParticle then globalParticle:sync() end
	end
}




