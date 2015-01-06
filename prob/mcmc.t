local trace = terralib.require("prob.trace")
local LS = terralib.require("std")


-- Bookkeeping to help us tell whether an MH-run is replaying still-valid trace or is
--    generating new trace.
local propVarIndex = -1
local function setPropVarIndex(i)
	propVarIndex = i
end
local function unsetPropVarIndex()
	propVarIndex = -1
end
local function isReplaying()
	local nextVarIndex = trace.nextVarIndex()
	if nextVarIndex then
		return nextVarIndex <= propVarIndex
	else
		return false
	end
end


-- An MH chain
local MHChain = LS.LObject()

function MHChain:init(program, args, temp)
	self.temp = temp or 1
	self.trace = trace.StructuredERPTrace.alloc():init(program, unpack(args))
	self.trace:rejectionSample()
	return self
end

-- Returns true if step was an accepted proposal, false otherwise.
function MHChain:step()
	-- Copy the trace
	local newtrace = self.trace:newcopy()
	-- Select a variable at random, propose change
	local recs = newtrace:records()
	local randidx = math.ceil(math.random()*#recs)
	local rec = recs[randidx]
	local fwdlp, rvslp = rec:propose()
	fwdlp = fwdlp - math.log(#recs)
	-- Re-run trace to propagate changes
	setPropVarIndex(rec.index)
	newtrace:run()
	unsetPropVarIndex()
	fwdlp = fwdlp + newtrace.newlogprob
	recs = newtrace:records()
	rvslp = rvslp - math.log(#recs) + newtrace.oldlogprob
	-- Accept/reject
	local accept = math.log(math.random()) < (newtrace.logposterior - self.trace.logposterior)/self.temp + rvslp - fwdlp
	if accept then
		self.trace:freeMemory()
		self.trace = newtrace
	else
		newtrace:freeMemory()
	end
	return accept
end


-- Do lightweight MH
-- Options are:
--    * nSamples: how many samples to collect?
--    * timeBudget: how long to run for before terminating? (overrules nSamples)
--    * lag: How many iterations between collected samples?
--    * verbose: print verbose output
--    * onSample: Callback that says what to do with the trace every time a sample is reached
--    * temp: Temperature to divide the log posterior by when calculating accept/reject
local function MH(program, args, opts)
	-- Extract options
	local nSamples = opts.nSamples or 1000
	local timeBudget = opts.timeBudget
	local lag = opts.lag or 1
	local verbose = opts.verbose
	local onSample = opts.onSample or function() end
	local temp = opts.temp or 1
	local iters = lag*nSamples
	-- Initialize with a complete trace of nonzero probability
	local chain = MHChain.alloc():init(program, args, temp)
	-- Do MH loop
	local numAccept = 0
	local t0 = terralib.currenttimeinseconds()
	local itersdone = 0
	for i=1,iters do
		-- Do a proposal step
		local accept = chain:step()
		if accept then numAccept = numAccept + 1 end
		-- Do something with the sample
		if i % lag == 0 then
			onSample(chain.trace)
			if verbose then
				io.write(string.format("Done with sample %u/%u\r", i/lag, nSamples))
				io.flush()
			end
		end
		itersdone = itersdone + 1
		-- Maybe terminate, if we're on a time budget
		if timeBudget then
			local t = terralib.currenttimeinseconds()
			if t - t0 >= timeBudget then
				break
			end
		end
	end
	if verbose then
		local t1 = terralib.currenttimeinseconds()
		io.write("\n")
		print("Acceptance ratio:", numAccept/itersdone)
		print("Time:", t1 - t0)
	end
end


return
{
	MH = MH,
	isReplaying = isReplaying
}



