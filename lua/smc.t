local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local trace = terralib.require("lua.trace")
local distrib = terralib.require("lua.distrib")
local util = terralib.require("lua.util")

---------------------------------------------------------------

-- Sync points use exception handling
-- 'Error code' that that indicates whether the exception is due to
--    a sync point.
local SMC_SYNC_ERROR = {}

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
		return self
	end

	function Particle:copy(other)
		self.trace = Trace.alloc():copy(other.trace)
		self.finished = other.finished
		self.currSyncIndex = other.currSyncIndex
		self.stopSyncIndex = other.stopSyncIndex
		return self
	end

	function Particle:willStopAtNextSync()
		return self.currSyncIndex == self.stopSyncIndex
	end

	function Particle:sync()
		if self.currSyncIndex == self.stopSyncIndex then
			error(SMC_SYNC_ERROR)
		else
			self.currSyncIndex = self.currSyncIndex + 1
		end
	end

	function Particle:step()
		if not self.finished then
			local prevGlobalParticle = globalParticle
			globalParticle = self
			self.stopSyncIndex = self.stopSyncIndex + 1
			self.currSyncIndex = 1
			local succ, err = pcall(function() self.trace:run() end)
			if succ then
				self.finished = true
			elseif err ~= SMC_SYNC_ERROR then
				-- Propagate error if it's not due to a sync point
				error(err)
			end
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
		local ri = N * weightCDF[i] / weightCDF[N]
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
--    * doAnneal: Do annealing
--    * nAnnealSteps: Duration of time to do annealing
--    * annealStartTemp: Start temperature for annealing
--    * annealEndTemp: Final temperature for annealing
--    * doFunnel: Funnel the number of particles from a large number to a small number over time
--    * nFunnelSteps: Duration of time to do funneling
--    * funnelStartNum: Number of particles to start with
--    * funnelEndNum: Number of particles to end with
--    * verbose: Verbose output?
--    * beforeResample: Callback that does something with particles before resampling
--    * afterResample: Callback that does something with particles after resampling
--    * exit: Callback that does something with particles when everything is finished
local function SIR(program, args, opts)
	local function nop() end

	-- Extract options
	local nParticles = opts.nParticles or 200
	local resample = opts.resample or Resample.systematic
	local doAnneal = opts.doAnneal
	local nAnnealSteps = opts.nAnnealSteps or 10	-- No idea...
	local annealStartTemp = opts.annealStartTemp or 100
	local annealEndTemp = opts.annealEndTemp or 1
	local doFunnel = opts.doFunnel
	local nFunnelSteps = opts.nFunnelSteps or 10  	-- No idea...
	local funnelStartNum = opts.funnelStartNum or 1000
	local funnelEndNum = opts.funnelEndNum or 100
	local verbose = opts.verbose
	local beforeResample = opts.beforeResample or nop
	local afterResample = opts.afterResample or nop
	local exit = opts.exit or nop

	-- Only need the simplest trace to do SIR
	local Trace = trace.FlatValueTrace

	-- Init particles
	local particles = {}
	local weights = {}
	if doFunnel then nParticles = funnelStartNum end
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
	-- -- TESTING --
	-- local data = io.open("tableau/scores_over_time.csv", "w")
	-- data:write("generation,avglikelihood,maxlikelihood,minlikelihood,avgposterior,maxposterior,minposterior\n")
	-- --------------
	repeat
		local numfinished = 0
		-- -- TESTING --
		-- local avglikelihood = 0
		-- local maxlikelihood = -math.huge
		-- local minlikelihood = math.huge
		-- local avgposterior = 0
		-- local maxposterior = -math.huge
		-- local minposterior = math.huge
		-- --------------
		-- Step
		for i,p in ipairs(particles) do
			p:step()
			if p.finished then
				numfinished = numfinished + 1
			end
			weights[i] = p.trace.loglikelihood
			if doAnneal then
				local t = math.min(generation / nAnnealSteps, 1.0)
				local temp = (1.0-t)*annealStartTemp + t*annealEndTemp
				weights[i] = weights[i]/temp
			end
			-- -- TESTING --
			-- if weights[i] ~= -math.huge then
			-- 	avglikelihood = avglikelihood + p.trace.loglikelihood
			-- 	maxlikelihood = math.max(maxlikelihood, p.trace.loglikelihood)
			-- 	minlikelihood = math.min(minlikelihood, p.trace.loglikelihood)
			-- 	avgposterior = avgposterior + p.trace.logposterior
			-- 	maxposterior = math.max(maxposterior, p.trace.logposterior)
			-- 	minposterior = math.min(minposterior, p.trace.logposterior)
			-- end
			-- --------------
		end
		local allfinished = (numfinished == nParticles)
		-- -- TESTING --
		-- avglikelihood = avglikelihood / nParticles
		-- avgposterior = avgposterior / nParticles
		-- data:write(string.format("%u,%g,%g,%g,%g,%g,%g\n",
		-- 	generation, avglikelihood, maxlikelihood, minlikelihood, avgposterior, maxposterior, minposterior))
		-- allfinished = generation == 85
		-- --------------
		if verbose then
			io.write(string.format("Generation %u: Finished %u/%u particles.        \r",
				generation, numfinished, nParticles))
			io.flush()
		end
		-- Exponentiate weights, preventing underflow
		util.expNoUnderflow(weights)
		-- Resampling
		beforeResample(particles)
		if doFunnel then
			local t = math.min(generation / nAnnealSteps, 1.0)
			nParticles = (1.0-t)*funnelStartNum + t*funnelEndNum
		end
		particles = resample(particles, weights, nParticles)
		weights = {}
		afterResample(particles)
		generation = generation + 1
	until allfinished

	-- -- TESTING --
	-- data:close()
	-- --------------

	if verbose then
		local t1 = terralib.currenttimeinseconds()
		io.write("\n")
		print("Time:", t1 - t0)
	end
	exit(particles)
end



return
{
	Resample = Resample,
	SIR = SIR,
	willStopAtNextSync = function()
		return globalParticle and globalParticle:willStopAtNextSync()
	end,
	sync = function()
		if globalParticle then globalParticle:sync() end
	end
}




