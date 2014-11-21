local LS = terralib.require("lua.std")
local distrib = terralib.require("lua.distrib")

---------------------------------------------------------------

-- Functionality that all traces share
local Trace = LS.LObject()
local globalTrace = nil

-- Program can optionally take some arguments (typically used for some
--    persistent store)
function Trace:init(program, ...)
	self.program = program
	self.args = {...}
	self.retvals = {}
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
	self.retvals = {}
	for _,rv in ipairs(other.retvals) do
		table.insert(self.retvals, LS.newcopy(rv))
	end
	self.logprior = other.logprior
	self.loglikelihood = other.loglikelihood
	self.logposterior = other.logposterior
	return self
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
	local retvals = { pcall(self.program, unpack(self.args)) }
	globalTrace = prevGlobalTrace
	if retvals[1] then
		table.remove(retvals, 1)
		self.retvals = retvals
	else
		error(retvals[2])
	end
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
local FlatValueTrace = LS.LObject()
setmetatable(FlatValueTrace, Trace)

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
	return self
end

function FlatValueTrace:clear()
	self.choicevals = {}
	self.choiceindex = 1
end

function FlatValueTrace:run()
	-- print("-------------------")
	self.choiceindex = 1
	Trace.run(self)
end

-- Look up the value, or sample a new one if we're past
--    the end of the list
function FlatValueTrace:makeRandomChoiceImpl(erp, ...)
	local val
	if self.choiceindex <= #self.choicevals then
		val = self.choicevals[self.choiceindex]
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

local flip = makeSampler(distrib.bernoulli)
local multinomial = makeSampler(distrib.multinomial)

-- Decided to do uniform this way so that we don't have range-invalidation
--    problems if and when we ever do MH.
local uniformerp = makeSampler({
	sample = math.random,
	logprob = function() return 0.0 end
})
local uniform = function(lo, hi)
	local u = uniformerp()
	return (1.0-u)*lo + u*hi
end
-- local uniform = makeSampler(distrib.uniform)

---------------------------------------------------------------


return
{
	FlatValueTrace = FlatValueTrace,
	addPreRunEvent = function(e) table.insert(Trace.preRunEvents, e) end,
	addPostRunEvent = function(e) table.insert(Trace.postRunEvents, e) end,
	isrunning = function() return globalTrace ~= nil end,
	flip = flip,
	uniform = uniform,
	multinomial = multinomial,
	factor = function(num) if globalTrace then globalTrace:addFactor(num) end end,
	likelihood = function(num) if globalTrace then globalTrace:setLoglikelihood(num) end end
}




