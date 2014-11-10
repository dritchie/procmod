local LS = terralib.require("lua.std")

---------------------------------------------------------------

-- Functionality that all traces share
local Trace = {}
Trace.__index = Trace
local globalTrace = nil

-- Program can optionally take some arguments (typically used for some
--    persistent store)
function Trace:init(program, ...)
	self.program = program
	self.args = {...}
	self.retval = nil
	self.logprior = 0.0
	self.loglikelihood = 0.0
	self.logposterior = 0.0
	return self
end

function Trace:copy(other)
	self.program = other.program
	self.args = {}
	for _,a in ipairs(other.args) do
		table.insert(self.args, LS.newcopy(a))
	end
	self.retval = LS.newcopy(other.retval)
	self.logprior = other.logprior
	self.loglikelihood = other.loglikelihood
	self.logposterior = other.logposterior
end

-- Find a complete trace of nonzero probability via rejection sampling
function Trace:rejectionSample()
	repeat
		self:clear()
		self:run()
	until self.logposterior > -math.huge
end

function Trace:clear()
	error("Trace: 'clear' method not implemented.")
end

function Trace:run()
	local prevGlobalTrace = Trace.globalTrace
	globalTrace = self
	self.choiceindex = 1
	self.logprior = 0.0
	self.loglikelihood = 0.0
	self.logposterior = 0.0
	self.retval = self.program(unpack(self.args))
	globalTrace = prevGlobalTrace
end

function Trace:makeRandomChoice(erp, ...)
	local val = self:makeRandomChoiceImpl(erp, ...)
	self.logprior = self.logprior + erp.logprob(val, ...)
	self.logposterior = self.logprior + self.loglikelihood
	return val
end

function Trace:makeRandomChoiceImpl(erp, ...)
	error("Trace: 'makeRandomChoiceImpl' method not implemented.")
end

function Trace:addFactor(num)
	self.loglikelihood = self.loglikelihood + num
	self.logposterior = self.logprior + self.logposterior
end

function Trace:setLoglikelihood(num)
	self.loglikelihood = num
	self.logposterior = self.logprior + self.loglikelihood
end

---------------------------------------------------------------

-- Simple trace that stores the values of random choices in a flat list.
-- Sufficent to replay an execution, and that's about it.
local FlatValueTrace = {}
FlatValueTrace.__index = FlatValueTrace
setmetatable(FlatValueTrace, Trace)
FlatValueTrace.globalTrace = nil

function FlatValueTrace.alloc()
	local obj = {}
	setmetatable(obj, FlatValueTrace)
	return obj
end

function FlatValueTrace:init(program, ...)
	Trace.init(self, program, ...)
	self.choicevals = {}
	self.choiceindex = 1
	return self
end

function FlatValueTrace:copy(other)
	Trace.copy(self, other)
	self.choicevals = {}
	for _,v in ipairs(other.choicevals) do
		table.insert(self.choicevals, v)
	end
	self.choiceindex = other.choiceindex
end

function FlatValueTrace:clear()
	self.choicevals = {}
	self.choiceindex = 1
end

function FlatValueTrace:run()
	self.choiceindex = 1
	Trace.run(self)
end

-- Look up the value, or sample a new one if we're past
--    the end of the list
function FlatValueTrace:makeRandomChoiceImpl(erp, ...)
	local val
	local reused = false
	if self.choiceindex <= #self.choicevals then
		val = self.choicevals[self.choiceindex]
		reused = true
	else
		val = erp.sample(...)
		table.insert(self.choicevals, val)
	end
	self.choiceindex = self.choiceindex + 1
	return val
end

---------------------------------------------------------------

-- TODO: FlatERPTrace?

-- TODO: StructuredERPTrace?

---------------------------------------------------------------

-- ERP is a table consisting of sample, logprob, and (optionally) propose
local function makeSampler(ERP)
	return function(...)
		if globalTrace then
			return globalTrace:makeRandomChoice(ERP, ...)
		else
			return ERP.sample(...)
		end
	end
end


-- TODO: Make 'propose' methods for these?

local flip = makeSampler({
	name = "flip",
	sample = function(p) return math.random() < p end,
	logprob = function(val, p)
		local prob = val and p or 1-p
		return math.log(prob)
	end
})

local uniform = makeSampler({
	name = "uniform",
	sample = function(lo, hi)
		local u = math.random()
		return (1-u)*lo + u*hi
	end,
	logprob = function(val, lo, hi)
		if val < lo or val > hi then return -math.huge end
		return -math.log(hi - lo)
	end
})

---------------------------------------------------------------


return
{
	FlatValueTrace = FlatValueTrace,
	flip = flip,
	uniform = uniform,
	factor = function(num) if globalTrace then globalTrace:addFactor(num) end end,
	likelihood = function(num) if globalTrace then globalTrace:setLoglikelihood(num) end end
}




