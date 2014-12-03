local trace = terralib.require("prob.trace")


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


-- Do lightweight MH
-- Options are:
--    * nSamples: how many samples to collect?
--    * timeBudget: how long to run for before terminating? (overrules nSamples)
--    * lag: How many iterations between collected samples?
--    * verbose: print verbose output
--    * onSample: Callback that says what to do with the trace every time a sample is reached
local function MH(program, args, opts)
	-- Extract options
	local nSamples = opts.nSamples or 1000
	local timeBudget = opts.timeBudget
	local lag = opts.lag or 1
	local verbose = opts.verbose
	local onSample = opts.onSample or function() end
	local iters = lag*nSamples
	-- Initialize with a complete trace of nonzero probability
	local trace = trace.StructuredERPTrace.alloc():init(program, unpack(args))
	trace:rejectionSample()
	-- Do MH loop
	local numAccept = 0
	local t0 = terralib.currenttimeinseconds()
	local itersdone = 0
	for i=1,iters do
		-- Copy the trace
		local newtrace = trace:newcopy()
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
		local accept = math.log(math.random()) < newtrace.logposterior - trace.logposterior + rvslp - fwdlp
		if accept then
			trace:freeMemory()
			trace = newtrace
			numAccept = numAccept + 1
		else
			newtrace:freeMemory()
		end
		-- Do something with the sample
		if i % lag == 0 then
			onSample(trace)
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



