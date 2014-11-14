local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local trace = terralib.require("lua.trace")
local distrib = terralib.require("lua.distrib")

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

function Resample.multinomial(particles, weights)
	local newparticles = {}
	for i,p in ipairs(particles) do
		local idx = distrib.multinomial.sample(weights)
		table.insert(newparticles, particles[idx]:newcopy())
	end
	return newparticles
end

local function resampleStratified(particles, weights, systematic)
	local N = #weights
	local newparticles = {}
	-- Compute CDF of weight distribution
	local weightCDF = {weights[1]}
	for i=2,N do
		local wprev = weightCDF[#weightCDF]
		table.insert(weightCDF, wprev + weights[i])
	end
	-- Resample
	local u
	if systematic then
		u = math.random()
	end
	local cumOffspring = 0
	for i=1,N do
		local ri = N * weightCDF[i] / weightCDF[N]
		local ki = math.min(math.floor(ri) + 1, N)
		if not systematic then
			u = math.random()
		end
		local oi = math.min(math.floor(ri + u), N)
		-- cumOffspring must be non-decreasing
		oi = math.max(oi, cumOffspring)
		local numOffspring = oi - cumOffspring
		cumOffspring = oi
		for j=1,numOffspring do
			table.insert(newparticles, particles[i]:newcopy())
		end
	end
	return newparticles
end

function Resample.stratified(particles, weights)
	return resampleStratified(particles, weights, false)
end

function Resample.systematic(particles, weights)
	return resampleStratified(particles, weights, true)
end

---------------------------------------------------------------

-- The log of the minimum-representable double precision float
-- TODO: Replace with log of the minimum-representable *non-denormalized* double?
local LOG_DBL_MIN = -708.39641853226

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
	-- Only need the simplest trace to do SIR
	local Trace = trace.FlatValueTrace
	-- Init particles
	local particles = {}
	local weights = {}
	for i=1,nParticles do
		-- Each particle gets a copy of any input args
		local argscopy = {}
		for _,a in ipairs(args) do table.insert(argscopy, LS.newcopy(a)) end
		local p = Particle(Trace).alloc():init(program, unpack(argscopy))
		table.insert(particles, p)
		table.insert(weights, 0)
	end
	-- Step all particles forward in lockstep until they are all finished
	local t0 = terralib.currenttimeinseconds()
	local generation = 1
	repeat
		local numfinished = 0
		local minFiniteScore = math.huge
		-- Step
		for i,p in ipairs(particles) do
			p:step()
			if p.finished then
				numfinished = numfinished + 1
			end
			weights[i] = p.trace.loglikelihood
			if weights[i] ~= -math.huge then
				minFiniteScore = math.min(minFiniteScore, weights[i])
			end
		end
		local allfinished = (numfinished == nParticles)
		if verbose then
			io.write(string.format("Generation %u: Finished %u/%u particles.\r",
				generation, numfinished, nParticles))
			io.flush()
		end
		generation = generation + 1
		-- Exponentiate weights, preventing underflow
		local underflowFix = (minFiniteScore < LOG_DBL_MIN) and (LOG_DBL_MIN - minFiniteScore) or 0
		for i=1,#weights do weights[i] = math.exp(weights[i] + underflowFix) end
		-- Resampling
		beforeResample(particles)
		particles = resample(particles, weights)
		afterResample(particles)
	until allfinished
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




