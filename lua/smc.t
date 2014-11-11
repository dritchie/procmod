local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local trace = terralib.require("lua.trace")

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
	local Particle = {}
	Particle.__index = Particle

	function Particle.alloc()
		local obj = {}
		setmetatable(obj, Particle)
		return obj
	end

	function Particle:init(program, ...)
		self.trace = Trace.alloc():init(program, ...)
		self.finished = false
		self.currSyncIndex = 1
		self.stopSyncIndex = 0
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

-- Straight-up sequential importance resampling
-- The last three args are callbacks
local function SIR(program, args, nParticles, verbose, beforeResample, afterResample, exit)
	-- Only need the simplest trace to do SIR
	local Trace = trace.FlatValueTrace
	-- Init particles
	local particles = {}
	local nextParticles = {}
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
	local generation = 1
	repeat
		local numfinished = 0
		for i,p in ipairs(particles) do
			p:step()
			if p.finished then
				numfinished = numfinished + 1
			end
			weights[i] = p.trace.loglikelihood
		end
		local allfinished = (numfinished == nParticles)
		if verbose then
			io.write(string.format("Generation %u: Finished %u/%u particles.\r",
				generation, numfinished, nParticles))
			io.flush()
		end
		generation = generation + 1
		beforeResample(particles)
		-- TODO: exponentiate weights, preventing underflow
		-- TODO: Resampling
		afterResample(particles)
	until allfinished
	exit(particles)
	if verbose then
		io.write("\n")
	end
end



return
{
	-- Particle = Particle,
	SIR = SIR,
	willStopAtNextSync = function()
		return globalParticle and globalParticle:willStopAtNextSync()
	end,
	sync = function()
		if globalParticle then globalParticle:sync() end
	end
}




