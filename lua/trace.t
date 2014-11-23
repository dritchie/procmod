local S = terralib.require("qs.lib.std")
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
	local val, logprob = self:makeRandomChoiceImpl(erp, ...)
	self.logprior = self.logprior + logprob
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

-- Address stack management functions. These are no-ops for all Trace types
--    except the StructuredERPTrace.
function Trace:pushAddress(name) end
function Trace:popAddress() end
function Trace:setAddressLoopIndex(i) end

---------------------------------------------------------------

-- Simple trace that stores the values (and logprobs) of random choices in a flat list.
-- Sufficent to replay an execution, and that's about it.
local FlatValueTrace = LS.LObject()
setmetatable(FlatValueTrace, Trace)

function FlatValueTrace:init(program, ...)
	Trace.init(self, program, ...)
	self.choicevals = {}
	self.choicelogprobs = {}
	self.choiceindex = 1
	return self
end

function FlatValueTrace:copy(other)
	Trace.copy(self, other)
	self.choicevals = {}
	for _,v in ipairs(other.choicevals) do
		table.insert(self.choicevals, v)
	end
	self.choicelogprobs = {}
	for _,lp in ipairs(other.choicelogprobs) do
		table.insert(self.choicelogprobs, lp)
	end
	self.choiceindex = other.choiceindex
	return self
end

function FlatValueTrace:clear()
	self.choicevals = {}
	self.choicelogprobs = {}
	self.choiceindex = 1
end

function FlatValueTrace:run()
	self.choiceindex = 1
	Trace.run(self)
end

-- Look up the value, or sample a new one if we're past
--    the end of the list
function FlatValueTrace:makeRandomChoiceImpl(erp, ...)
	local val, lp
	if self.choiceindex <= #self.choicevals then
		val = self.choicevals[self.choiceindex]
		lp = self.choicelogprobs[self.choiceindex]
	else
		val = erp.sample(...)
		lp = erp.logprob(val, ...)
		table.insert(self.choicevals, val)
		table.insert(self.choicelogprobs, lp)
	end
	self.choiceindex = self.choiceindex + 1
	return val, lp
end

---------------------------------------------------------------

-- ERP record type needed by StructuredERPTrace
local ERPRec = LS.LObject()

function ERPRec:init(erp, ...)
	self.erp = erp
	self.value = erp.sample(...)
	self.logprob = erp.logprob(self.value, ...)
	self.params = {...}
	self.reachable = true
	return self
end

function ERPRec:copy(other)
	self.erp = other.erp
	self.value = other.value
	self.logprob = other.logprob
	self.params = {}
	for _,p in ipairs(other.params) do
		table.insert(self.params, p)
	end
	self.reachable = other.reachable
	return self
end

function ERPRec:checkForParamChanges(...)
	local params = {...}
	local hasChanges = false
	for i,p in ipairs(self.params) do
		if p ~= params[i] then
			hasChanges = true
			break
		end 
	end
	if hasChanges then
		self.params = params
		self.logprob = self.erp.logprob(self.val, ...)
	end
end

function ERPRec:propose()
	local newval, fwdlp, rvslp = self.erp.propose(self.val, unpack(self.params))
	self.logprob = self.erp.logprob(newval, unpack(self.params))
	self.val = newval
	return fwdlp, rvslp
end


-- Address type abstracts the actual implementation of the address stack
local Address = LS.LObject()

local currid = 1
local name2id = S.memoize(function(name)
	local id = currid
	currid = currid + 1
	return id
end)

function Address:init()
	self.str = "|0:0:0"
	self.data = {
		blockid = 0,
		loopid = 0,
		varid = 0
	}
	return self
end

-- Addresses only hold data *during* the run of a program, so when we copy them, 
--    they're always empty
function Address:copy(other)
	return self:init()
end

function Address:getstr() return self.str end

function Address:push(name)
	local id = name2id(name)
	table.insert(self.data, {
		blockid = id,
		loopid = 0,
		varid = 0
	})
	self.addressString = string.format("%s|%u:0:0", self.addressString, id)
end

function Address:pop()
	table.remove(self.data)
	local endindex = string.find(self.addressString, "|[^|]*$")
	self.addressString = string.sub(1, endindex-1)
end

function Address:setLoopIndex(i)
	local d = self.data[#self.data]
	d.loopid = i
	if i == 0 then
		d.varid = 0
	end
	local endindex = string.find(self.addressString, "|[^|]*$")
	self.addressString = string.format("%s|%u:%u:%u", 
		string.sub(1, endindex-1), d.blockid, d.loopid, d.varid)
end

function Address:incrementVarIndex()
	local d = self.data[#self.data]
	d.varid = d.varid + 1
	local endindex = string.find(self.addressString, "|[^|]*$")
	self.addressString = string.format("%s|%u:%u:%u", 
		string.sub(1, endindex-1), d.blockid, d.loopid, d.varid)
end


-- Trace that indexes ERPs by their structural address in the program.
-- Needed to do efficient MH.
local StructuredERPTrace = LS.LObject()
setmetatable(StructuredERPTrace, Trace)

function StructuredERPTrace:init(program, ...)
	Trace.init(self, program, ...)
	self.choicemap = {}
	self.address = Address.alloc():init()
	return self
end

function StructuredERPTrace:copy(other)
	Trace.copy(self, other)
	self.choicemap = {}
	for addr, rec in pairs(other.choicemap) do
		self[addr] = rec:newcopy()
	end
	self.address = other.address:newcopy()
end

function StructuredERPTrace:clear()
	self.choicemap = {}
end

function StructuredERPTrace:run()
	Trace.run(self)
	-- Clear out any random choices that are no longer reachable
	for addr,rec in pairs(self.choicemap) do
		if not rec.reachable then
			self.choicemap[addr] = nil
		end
	end
end

-- Return vars as a list
function StructuredERPTrace:records()
	local recs = {}
	for _,rec in pairs(self.choicemap) do
		table.insert(recs, rec)
	end
	return recs
end

function StructuredERPTrace:makeRandomChoiceImpl(erp, ...)
	-- Look for the ERP by address, and generate a new one if we don't find it
	local addr = self.address:getstr()
	local rec = self.choicemap[addr]
	if rec then
		-- Do anything that needs to be done if the parameters have changed.
		rec:checkForParamChanges(...)
		rec.reachable = true
	else
		-- Make a new record
		rec = ERPRec.alloc():init(erp, ...)
		self.choicemap[addr] = rec
	end
	self.address:incrementVarIndex()
	return rec.val, rec.logprob
end

function StructuredERPTrace:pushAddress(name)
	self.address:push(name)
end

function StructuredERPTrace:popAddress()
	self.address:pop()
end

function StructuredERPTrace:setAddressLoopIndex(i)
	self.address:setLoopIndex(i)
end

---------------------------------------------------------------

-- ERP is a table consisting of sample, logprob, and (optionally) propose
local function makeSampler(ERP)
	ERP.propose = ERP.propose or function(val, ...)
		local pval = ERP.sample(...)
		local fwdlp = ERP.logprob(pval, ...)
		local rvslp = ERP.logprob(val, ...)
		return pval, fwdlp, rvslp
	end
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
	StructuredERPTrace = StructuredERPTrace,
	isrunning = function() return globalTrace ~= nil end,
	flip = flip,
	uniform = uniform,
	multinomial = multinomial,
	factor = function(num) if globalTrace then globalTrace:addFactor(num) end end,
	likelihood = function(num) if globalTrace then globalTrace:setLoglikelihood(num) end end
}




