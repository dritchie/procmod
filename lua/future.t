local LS = terralib.require("lua.std")
local trace = terralib.require("lua.trace")

---------------------------------------------------------------

-- Deterministic futures don't do anything interesting--they're just here
--    to provide a predictable point of comparison.

-- Abstract the actual implementation of the queue (it's just a hash set)
local dqueue =
{
	queue = {}
}
function dqueue:add(f)
	self.queue[f] = true
end
function dqueue:remove(f)
	self.queue[f] = nil
end
function dqueue:clear()
	self.queue = {}
end
-- Iterator for generic for loop
local function nextkey(t, k)
	local kn = next(t, k)
	return kn
end
function dqueue:iter()
	return nextkey, self.queue, nil
end



-- This is the functionality we'll export
local dfuture = 
{
	isrunning = false
}



local DeterministicFuture = LS.LObject()

function DeterministicFuture:init(fn, ...)
	self.fn = fn
	self.args = {...}
	dqueue:add(self)
	return self
end

function DeterministicFuture:force()
	dfuture.isrunning = true
	local ret = self.fn(unpack(self.args))
	dfuture.isrunning = false
	dqueue:remove(self)
	return ret
end



function dfuture.create(fn)
	assert(trace.isrunning(), "future.create can only be invoked when a probabilistic program trace is running")
	return DeterministicFuture.alloc():init(fn)
end

-- Deterministic futures execute in a fixed order and
--    don't interleave their execution, so this does nothing.
function dfuture.yield() end

-- Execute all remaining unforced futures
function dfuture.finishall()
	assert(not dfuture.isrunning, "future.finishall cannot be invoked from within a future")
	for f in dqueue:iter() do
		f:force()
	end
end

-- Discard all remaining unforced futures
function dfuture.killall()
	assert(not dfuture.isrunning, "future.killall cannot be invoked from within a future")
	dqueue:clear()
end

---------------------------------------------------------------

-- Stochastic futures can have their execution randomly interleaved


-- Abstract the actual implementation of the active queue
-- For now, it's a linear vector, because we expect to do index-based loookups
--    much more frequently than adds (and even more frequently than removes)
local squeue =
{
	activequeue = {}
}
function squeue:add(f)
	table.insert(self.activequeue, f)
end
function squeue:remove(f)
	for i,qf in ipairs(self.activequeue) do
		if f == qf then
			table.remove(self.activequeue, i)
			break
		end
	end
end
function squeue:isempty()
	return #self.activequeue == 0
end
function squeue:clear()
	self.activequeue = false
end
function squeue:selectrandom()
	local randidx = math.ceil(trace.uniform(0, #self.activequeue))
	return self.activequeue[randidx]
end



-- This is the functionality that we'll export
local sfuture = 
{
	isrunning = false,
	currentlyRunningFuture = nil
}



-- The future objects themselves need to store more information than just a simple thunk
local StochasticFuture = LS.LObject()

function StochasticFuture:init(fn, ...)
	self.coroutine = coroutine.create(fn)
	self.waiters = {}
	self.resumevals = {...}
	self.retvals = {}
	self.finished = false
	squeue:add(self)
	return self
end

function StochasticFuture:force()
	-- If we're not currently runnning a future, then set up a loop where we run
	--    futures randomly until this one is finished.
	if not sfuture.isrunning then
		while not self.finished do
			squeue:selectrandom():resume()
		end
		return unpack(self.retvals)
	-- If we are currently running a future, then we de-active the currently-running
	--    future, place it in this future's 'waiters' list, and then yield.
	else
		squeue:remove(sfuture.currentlyRunningFuture)
		table.insert(self.waiters, sfuture.currentlyRunningFuture)
		return sfuture.yield()
	end
end

function StochasticFuture:resume()
	sfuture.isrunning = true
	sfuture.currentlyRunningFuture = self
	self.retvals = { coroutine.resume(self.coroutine, unpack(self.resumevals)) }
	sfuture.isrunning = false
	sfuture.currentlyRunningFuture = nil
	self.resumevals = {}
	-- Handle situation where the coroutine threw an error (coroutines are executed under pcall,
	--    so the first return value is bool indicating whether execution terminated safely)
	if not self.retvals[1] then
		error(self.retvals[2])
	-- Handle situation where the coroutine has finished.
	elseif coroutine.status(self.coroutine) == 'dead' then
		table.remove(self.retvals, 1)
		-- For any futures that are waiting on this one to finish:
		for _,wf in ipairs(self.waiters) do
			-- Pass return values to the waiting future...
			wf.resumevals = retvals
			-- ...and reactivate it (i.e. make it valid to run again)
			squeue:insert(wf)
		end
		-- Remove this future from the queue
		squeue:remove(self)
		self.finished = true
	end
end



function sfuture.create(fn)
	assert(trace.isrunning(), "future.create can only be invoked when a probabilistic program trace is running")
	return StochasticFuture.alloc():init(fn)
end

function sfuture.yield()
	if sfuture.isrunning then
		coroutine.yield()
	end
end

function sfuture.finishall()
	assert(not sfuture.isrunning, "future.finishall cannot be invoked from within a future")
	while not squeue:isempty() do
		squeue:selectrandom():resume()
	end
end

function sfuture.killall()
	assert(not sfuture.isrunning, "future.killall cannot be invoked from within a future")
	squeue:clear()
end

---------------------------------------------------------------

-- Can switch which implementation of futures we expose
local future = dfuture
-- local future = sfuture

-- Before a trace runs, we make sure that there are no futures lingering in the system.
trace.addPreRunEvent(future.killall)
-- After a trace run ends, we finish any unforced futures.
trace.addPostRunEvent(future.finishall)

return future




