local S = require("qs.lib.std")
local LS = require("std")
local trace = require("prob.trace")
local distrib = require("prob.distrib")
local util = require("util")

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


-- Specialized type of particle that snapshots partial traces at resampling points
--   and can be used as a retained particle for Particle Gibbs
local RetainableParticle = S.memoize(function(Trace)
	local RetainableParticle = LS.LObject()

	-- TODO: We could probably implement MH in terms of an object like this one,
	--    and then remove the need for the special 'MHState' in procmod.t ...

	function RetainableParticle:init(program, ...)
		self.inittrace = Trace.alloc():init(program, ...)
		self.traces = {}
		self.finished = false
		self.currSyncIndex = 1
		self.stopSyncIndex = 0
		self.lastStopSyncIndex = 0
		return self
	end

	function RetainableParticle:copy(other)
		self.finished = other.finished
		self.currSyncIndex = other.currSyncIndex
		self.stopSyncIndex = other.stopSyncIndex
		self.lastStopSyncIndex = other.lastStopSyncIndex
		-- Copy traces up to the stop sync index (any traces beyond
		--    this correspond to the tail end of a copy of a retained
		--     particle that should be re-simulated)
		self.traces = {}
		for i=1,self.stopSyncIndex do
			table.insert(self.traces, other.traces[i]:newcopy())
		end
		return self
	end

	function RetainableParticle:freeMemory()
		for _,t in ipairs(self.traces) do t:freeMemory() end
	end

	function RetainableParticle:isReplaying()
		return self.currSyncIndex <= self.lastStopSyncIndex
	end

	function RetainableParticle:sync()
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

	function RetainableParticle:currTrace()
		return self.traces[self.stopSyncIndex]
	end

	function RetainableParticle:currLogWeight()
		return self.traces[self.stopSyncIndex].loglikelihood
	end

	function RetainableParticle:step()
		if not self.finished then
			self.stopSyncIndex = self.stopSyncIndex + 1
			-- We only need to simulate forward if we don't already have a 
			--    trace recorded for the next sync point
			if #self.traces < self.stopSyncIndex then
				if #self.traces == 0 then
					assert(self.inittrace)
					table.insert(self.traces, self.inittrace)
				else
					table.insert(self.traces, Trace.alloc():copy(self.traces[#self.traces]))
				end
				local prevGlobalParticle = globalParticle
				globalParticle = self
				self.currSyncIndex = 1
				if self:isReplaying() then startTraceReplayTimer() end
				local runtrace = self.traces[#self.traces]
				local succ, err = pcall(function() runtrace:run() end)
				if succ then
					self.finished = true
				elseif err ~= SMC_SYNC_ERROR then
					error(err)
				end
				self.lastStopSyncIndex = self.stopSyncIndex
				globalParticle = prevGlobalParticle
			else
				self.finished = (#self.traces == self.stopSyncIndex)
			end
		end
	end

	-- Reset sync index so that this particle will start 'running' again from the beginning
	function RetainableParticle:reset()
		self.finished = false
		self.stopSyncIndex = 0
		self.lastStopSyncIndex = 0
	end

	return RetainableParticle
end)


---------------------------------------------------------------

-- Different importance resampling algorithms

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

function Resample.residual(particles, weights, n)
	local sum = 0
	for _,w in ipairs(weights) do
		sum = sum + w
	end
	local newparticles = {}
	-- Deterministically copy in proportion to weight, keep
	--    track of residual weight
	local m = n
	local mr = m
	for i,p in ipairs(particles) do
		local w = weights[i]/sum
		local mw = m*w
		local k = math.floor(mw)
		weights[i] = mw - k
		mr = mr - k
		for j=1,k do
			table.insert(newparticles, p:newcopy())
		end
	end
	-- Sample from residual weights
	for i=1,mr do
		local idx = distrib.multinomial.sample(weights)
		table.insert(newparticles, particles[idx]:newcopy())
	end
	return newparticles
end


-- Experimental log-space version of multinomial resampler.
local function logAdd(logx, logy)
	-- Make logx the bigger of the two
	if logy > logx then
		local tmp = logx
		logx = logy
		logy = tmp
	end
	-- If the bigger of the two is log(0), then
	--    they both must be log(0) and so the sum is log(0)
	if logx == -math.huge then
		return -math.huge
	-- If the smaller is log(0), then the sum is equal to the
	--    bigger
	elseif logy == -math.huge then
		return logx
	end
	-- Do neat algebra
	return logx + math.log(1 + math.exp(logy-logx))
end
function multinomialSampleLogSpace(logweights, logsum)
	local result = 1
	local logx = math.log(math.random()) + logsum
	local logprobAccum = -math.huge
	repeat
		logprobAccum = logAdd(logprobAccum, logweights[result])
		result = result + 1
	until logprobAccum > logx or result > #logweights
	return result - 1
end
function Resample.multinomialLogSpace(particles, logweights, n)
	local logsum = logweights[1]
	for i=2,#logweights do
		logsum = logAdd(logsum, logweights[i])
	end
	local newparticles = {}
	for i=1,n do
		local idx = multinomialSampleLogSpace(logweights, logsum)
		table.insert(newparticles, particles[idx]:newcopy())
	end
	return newparticles
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
			io.write(string.format(" Generation %u: Finished %u/%u particles.        \r",
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

-- Particle Gibbs sampling
-- Options are:
--    * nParticles: How many particles to run per sweep
--    * nSweeps: Number of sweeps to run
--    * resample: Which resampling alg to use
--    * verbose: Verbose output?
--    * onSweep: Callback that does something with particles when a sweep has finished
local function ParticleGibbs(program, args, opts)
	local function nop() end

	-- Extract options
	local nSweeps = opts.nSweeps or 100
	local nParticles = opts.nParticles or 20
	local resample = opts.resample or Resample.systematic
	local verbose = opts.verbose
	local onSweep = opts.onSweep or nop

	clearTraceReplayTime()

	-- Only need the simplest trace
	local Trace = trace.FlatValueTrace

	-- Subroutine that performs an SMC sweep, potentially with a retained particle
	-- Returns a list of particles and a list of weights
	local function smcSweep(sweepNum, retainedParticle)
		local nUncondtionedParticles = retainedParticle and nParticles - 1 or nParticles
		-- Init particles
		local particles = {}
		local weights = {}
		for i=1,nUncondtionedParticles do
			local argscopy = {}
			for _,a in ipairs(args) do
				local newa = LS.newcopy(a)
				table.insert(argscopy, newa)
			end
			local p = RetainableParticle(Trace).alloc():init(program, unpack(argscopy))
			table.insert(particles, p)
		end
		if retainedParticle then
			table.insert(particles, retainedParticle)
		end
		-- Run sweep
		local generation = 1
		repeat
			local numfinished = 0
			-- Sample
			weights = {}
			for i,p in ipairs(particles) do
				p:step()
				if p.finished then numfinished = numfinished + 1 end
				weights[i] = p:currLogWeight()
			end
			local allfinished = (numfinished == nParticles)
			if verbose then
				io.write(string.format(" Sweep %u, Generation %u (finished %u/%u particles)              \r",
					sweepNum, generation, numfinished, nParticles))
				io.flush()
			end
			-- Resample
			util.expNoUnderflow(weights)
			local newparticles = resample(particles, weights, nUncondtionedParticles)
			if retainedParticle then
				table.remove(particles, #particles)
				table.insert(newparticles, retainedParticle)
			end
			for _,p in ipairs(particles) do p:freeMemory() end
			particles = newparticles
			generation = generation + 1
		until allfinished
		return particles, weights
	end

	-- Run sweeps
	local t0 = terralib.currenttimeinseconds()
	local retainedParticle = nil
	for i=1,nSweeps do
		local P, W
		if retainedParticle then
			-- 'Reset' the retained particle to run from the beginning
			retainedParticle:reset()
			P, W = smcSweep(i, retainedParticle)
		else
			P, W = smcSweep(i)
		end
		onSweep(P)
		-- Sample the next retained particle
		local idx = distrib.multinomial.sample(W)
		retainedParticle = P[idx]
		-- Free memory for all other particles (rather than wait for GC)
		for i,p in ipairs(P) do
			if i ~= idx then p:freeMemory() end
		end
	end
	if verbose then
		local t1 = terralib.currenttimeinseconds()
		io.write("\n")
		print("Time:", t1 - t0)
		local trp = getTraceReplayTime()
		print(string.format("Time spent on trace replay: %g (%g%%)",
			trp, 100*(trp/(t1-t0))))
	end
end

---------------------------------------------------------------

-- Asynchronous SMC with the Particle Cascade algorithm
-- http://arxiv.org/abs/1407.2864
-- (This is a single-threaded implementation)
-- Options are:
--    * nParticles: How many particles to run
--    * nMax: Maximum number of simultaneous particles (0 means no limit)
--    * verbose: Verbose output?
--    * onParticleFinish: Callback that does something to a finished particle
local function ParticleCascade(program, args, opts)

	-- Extract options
	local nParticles = opts.nParticles or 200
	local nMax = opts.nMax or 0
	if nMax == 0 then nMax = 1000000000 end
	local verbose = opts.verbose
	local onParticleFinish = opts.onParticleFinish or function(p) end

	clearTraceReplayTime()

	-- Only need the simplest trace type
	local Trace = trace.FlatValueTrace

	-- Process queue, stats for resampling points
	local pqueue = {}
	local resamplePoints = {}

	-- Resampling point statistics
	local ResamplingPoint = LS.LObject()
	function ResamplingPoint:init(n)
		self.k = 0
		self.kFinished = 0
		self.logWeightAvg = 0
		self.logWeightAvgFinished = 0
		self.childCount = 0
		self.n = n
		-- -- If there are resampling points before this one, then inherit initial 
		-- --    weight stats from particles that finished by the immediately
		-- --    preceding resampling point.
		-- if n > 1 then
		-- 	self.k = resamplePoints[n-1].kFinished
		-- 	self.logWeightAvg = resamplePoints[n-1].logWeightAvgFinished
		-- end
		return self
	end
	function ResamplingPoint:updateWeightAvg(particleProcess)
		local logWeight = particleProcess.logWeight
		local multiplicity = particleProcess.multiplicity
		-- Slice out zero-probability states
		if logWeight == -math.huge then return end
		self.k = self.k + 1
		local logx = math.log((self.k-1)/(self.k+multiplicity-1)) + self.logWeightAvg
		local logy = math.log(multiplicity/(self.k+multiplicity-1)) + logWeight
		self.logWeightAvg = logAdd(logx, logy)
	end
	function ResamplingPoint:updateFinishedWeightAvg(particleProcess)
		local logWeight = particleProcess.logWeight
		local multiplicity = particleProcess.multiplicity
		-- Slice out zero-probability states
		if logWeight == -math.huge then return end
		self.kFinished = self.kFinished + 1
		local logx = math.log((self.kFinished-1)/(self.kFinished+multiplicity-1)) + self.logWeightAvgFinished
		local logy = math.log(multiplicity/(self.kFinished+multiplicity-1)) + logWeight
		self.logWeightAvgFinished = logAdd(logx, logy)
	end
	function ResamplingPoint:computeNumChildrenAndWeight(particleProcess)
		local logWeight = particleProcess.logWeight
		-- Slice out zero-probability states
		if logWeight == -math.huge then
			return 0, -math.huge
		end
		self:updateWeightAvg(particleProcess)
		local logRatio = logWeight - self.logWeightAvg
		local numChildren
		local childLogWeight
		if logRatio < 0 then
			if logRatio < math.log(math.random()) then
				numChildren = 0
				childLogWeight = -math.huge
			else
				numChildren = 1
				childLogWeight = self.logWeightAvg
			end
		else
			local thresh = math.min(nParticles, self.k - 1)
			local ratio = math.exp(logRatio)
			if self.childCount > thresh then
				local rfloor = math.floor(ratio)
				numChildren = rfloor
				childLogWeight = logWeight - math.log(rfloor)
			else
				local rceil = math.ceil(ratio)
				numChildren = rceil
				childLogWeight = logWeight - math.log(rceil)
			end
		end
		self.childCount = self.childCount + numChildren
		return numChildren, childLogWeight
	end

	local ProcessState = { Running = 0, Killed = 1, Finished = 2 }

	-- A particle process
	local ParticleProcess = LS.LObject()
	function ParticleProcess:init(particle)
		self.particle = particle
		self.state = ProcessState.Running
		self.logWeight = 0
		self.numChildrenToSpawn = 0
		self.multiplicity = 1
		return self
	end
	function ParticleProcess:copy(other)
		self.particle = other.particle:newcopy()
		self.state = other.state
		self.logWeight = other.logWeight
		self.numChildrenToSpawn = 0
		self.multiplicity = other.multiplicity
		return self
	end
	function ParticleProcess:freeMemory()
		self.particle:freeMemory()
	end
	function ParticleProcess:run()
		-- We shouldn't ever attempt to run a dead process
		assert(self.state == ProcessState.Running)
		-- If this particle is still spawning children, continue doing that
		if self.numChildrenToSpawn > 0 then
			-- Only insert new child particles if the process queue has space
			if #pqueue < nMax then
				table.insert(pqueue, ParticleProcess.alloc():copy(self))
				self.numChildrenToSpawn = self.numChildrenToSpawn - 1
			else
				-- Collapse all child particles into this one and increase its multiplicity
				self.multiplicity = self.multiplicity * self.numChildrenToSpawn
				self.numChildrenToSpawn = 0
			end
			return
		end
		-- Otherwise, advance to the next resample point
		self.particle:step(1)
		if self.particle.finished then
			self.state = ProcessState.Finished
			-- -- Update finished weight averages
			-- local n = self.particle.stopSyncIndex-1
			-- resamplePoints[n]:updateFinishedWeightAvg(self)
			-- for i=n+1,#resamplePoints do
			-- 	resamplePoints[i]:updateWeightAvg(self)
			-- 	resamplePoints[i]:updateFinishedWeightAvg(self)
			-- end
			return 
		end
		self.logWeight = self.logWeight + self.particle.trace.loglikelihood
		local n = self.particle.stopSyncIndex
		if n > #resamplePoints then
			table.insert(resamplePoints, ResamplingPoint.alloc():init(n))
		end
		local rsp = resamplePoints[n]
		local numChildren, childWeight = rsp:computeNumChildrenAndWeight(self)
		if numChildren == 0 then
			self.state = ProcessState.Killed
		else
			self.logWeight = childWeight
			numChildren = numChildren - 1 	-- Continue self as one child
			if numChildren > 0 then
				self.numChildrenToSpawn = numChildren
			end
		end
	end


	-- The control process which spawns new particles
	local ControlProcess = LS.LObject()
	function ControlProcess:init()
		self.state = ProcessState.Running
		self.nStarted = 0
		self.logWeight = math.huge  	-- For greedy dequeue
		return self
	end
	function ControlProcess:run()
		-- Each particle gets a copy of any input args
		local argscopy = {}
		for _,a in ipairs(args) do
			local newa = LS.newcopy(a)
			table.insert(argscopy, newa)
		end
		local p = Particle(Trace).alloc():init(program, unpack(argscopy))
		table.insert(pqueue, ParticleProcess.alloc():init(p))
		self.nStarted = self.nStarted + 1
		-- Terminate the control process if we've started all the
		--    initial particles
		if self.nStarted == nParticles then
			self.state = ProcessState.Finished
		end
	end


	-- Different ordering schemes for process dequeueing
	local function dequeueProcessRand()
		local idx = math.ceil(math.random() * #pqueue)
		return idx, pqueue[idx]
	end
	local function dequeueProcessRandPriority()
		local spawnChance = 0.1
		local function priosample(istart)
			local weights = {}
			for i=istart,#pqueue do
				table.insert(weights, pqueue[i].logWeight)
			end
			util.expNoUnderflow(weights)
			local idx = distrib.multinomial.sample(weights)
			return idx, pqueue[idx]
		end
		if getmetatable(pqueue[1]) == ControlProcess then
			if (#pqueue == 1) or (math.random() < spawnChance) then
				return 1, pqueue[1]
			else
				return priosample(2)
			end
		else
			return priosample(1)
		end
	end
	local function dequeueProcessGreedy()
		local maxweight = -math.huge
		local idx = 0
		for i=1,#pqueue do
			local p = pqueue[i]
			if p.logWeight >= maxweight then
				maxweight = p.logWeight
				idx = i
			end
		end
		return idx, pqueue[idx]
	end
	local function dequeueProcessRandGreedyMix()
		local mixparam = 0.1
		if math.random() < mixparam then
			return dequeueProcessRand()
		else
			return dequeueProcessGreedy()
		end
	end

	-- Choose dequeue method and initialize process queue
	local dequeueProcess = dequeueProcessRandPriority
	table.insert(pqueue, ControlProcess.alloc():init())
	-- local dequeueProcess = dequeueProcessGreedy
	-- local spawner = ControlProcess.alloc():init()
	-- while spawner.state ~= ProcessState.Finished do
	-- 	spawner:run()
	-- end

	-- Go! (main loop)
	local iters = 0
	local nFinished = 0
	local nKilled = 0
	local t0 = terralib.currenttimeinseconds()
	while nFinished < nParticles and #pqueue > 0 do
		local idx, proc = dequeueProcess()
		proc:run()
		if proc.state == ProcessState.Killed then
			if proc.particle then
				proc:freeMemory()
				nKilled = nKilled + 1
			end
			table.remove(pqueue, idx)
		elseif proc.state == ProcessState.Finished then
			if proc.particle then
				onParticleFinish(proc.particle)
				proc:freeMemory()
				nFinished = nFinished + 1
			end
			table.remove(pqueue, idx)
		end
		if verbose then
			io.write(string.format(" Iteration %d: Finished %d/%d particles (%d in flight, %d terminated).                \r",
				iters, nFinished, nParticles, #pqueue, nKilled))
			io.flush()
		end
		iters = iters + 1
		-- -- TEST: Keep pipe full
		-- if #pqueue < nParticles then
		-- 	local gap = nParticles - #pqueue
		-- 	for i=1,gap do
		-- 		spawner:run()
		-- 	end
		-- end
	end
	if verbose then
		local t1 = terralib.currenttimeinseconds()
		io.write("\n")
		print("Time:", t1 - t0)
		local trp = getTraceReplayTime()
		print(string.format("Time spent on trace replay: %g (%g%%)",
			trp, 100*(trp/(t1-t0))))
	end

end

---------------------------------------------------------------

return
{
	Resample = Resample,
	SIR = SIR,
	ParticleGibbs = ParticleGibbs,
	ParticleCascade = ParticleCascade,
	isReplaying = function()
		return globalParticle and globalParticle:isReplaying()
	end,
	sync = function()
		if globalParticle then globalParticle:sync() end
	end
}




