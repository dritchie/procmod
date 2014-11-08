local S = terralib.require("qs.lib.std")
local util = terralib.require("lua.util")
local trace = terralib.require("lua.trace")

-- (For now) borrow some code from old probabilistic-lua
local distrib = terralib.require("probabilistic.random")

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
		self.currSyncIndex = 0
		self.stopSyncIndex = 0
		return self
	end

	function Particle:reachedNextSyncPoint()
		return self.currSyncIndex == self.stopSyncIndex
	end

	function Particle:step()
		if not self.finished then
			local prevGlobalParticle = globalParticle
			self.stopSyncIndex = self.stopSyncIndex + 1
			self.currSyncIndex = 0
			local succ, err = pcall(function() self.trace:update() end)
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
local function SIR(nParticles, program, args, beforeResample, afterResample, exit)
	--
end



return
{
	SIR = SIR,
	reachedNextSyncPoint = function()
		return globalParticle and globalParticle:reachedNextSyncPoint()
	end,
	sync = function() globalParticle and error(SMC_SYNC_ERROR) end
}




