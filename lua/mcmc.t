local trace = terralib.require("lua.trace")

-- Do lightweight MH
-- Options are:
--    * nSamples: how many samples to collect?
--    * lag: How many iterations between collected samples?
--    * verbose: print verbose output
--    * onSample: Callback that says what to do with the trace every time a sample is reached
local function MH(program, args, opts)
	-- Extract options
	local nSamples = opts.nSamples or 1000
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
		newtrace:run()
		recs = newtrace:records()
		rvslp = rvslp - math.log(#recs)
		-- Accept/reject
		local accept = math.log(math.random()) < newtrace.logposterior - trace.logposterior + rvslp - fwdlp then
		if accept then
			trace = newtrace
			numAccept = numAccept + 1
		end
		-- Do something with the sample
		if i % lag == 0 then
			onSample(trace)
			if verbose then
				io.write(string.format("Done with sample %u/%u\r", i/lag, nSamples))
				io.flush()
			end
		end
	end
	if verbose then
		local t1 = terralib.currenttimeinseconds()
		io.write("\n")
		print("Acceptance ratio:", numAccept/iters)
		print("Time:", t1 - t0)
	end
end


return
{
	MH = MH
}



