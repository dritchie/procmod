local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local trace = terralib.require("lua.trace")
local util = terralib.require("lua.util")

---------------------------------------------------------------

-- An eager deterministic future just immediately executes itself and saves
--    its return value(s) for when :force asks for them

local EagerDeterministicFuture = LS.LObject()

function EagerDeterministicFuture:init(fn, ...)
	local retvals = { pcall(fn, ...) }
	if not retvals[1] then
		error(retvals[2])
	else
		table.remove(retvals, 1)
		self.retvals = retvals
	end
	return self
end

function EagerDeterministicFuture:force()
	return unpack(self.retvals)
end


local edfuture = {}

function edfuture.create(fn, ...)
	return EagerDeterministicFuture.alloc():init(fn, ...)
end

-- Deterministic futures execute in a fixed order and
--    don't interleave their execution, so this does nothing.
function edfuture.yield() end

-- Execute ell remaining unforced futures.
-- Does nothing, because eager futures always execute immediately.
function edfuture.finishall() end

-- Discard all remaining unforced futures
-- Again, does nothing
function edfuture.killall() end

---------------------------------------------------------------

-- A lazy deterministic future waits until :force is called to execute itself

-- Abstract the actual implementation of the queue
local ldqueue =
{
	queue = {}
}
function ldqueue:add(f)
	table.insert(self.queue, f)
end
function ldqueue:remove(f)
	for i,qf in ipairs(self.queue) do
		if f == qf then
			table.remove(self.queue, i)
			break
		end
	end
end
function ldqueue:clear()
	self.queue = {}
end
function ldqueue:isempty()
	return #self.queue == 0
end
function ldqueue:back()
	return self.queue[#self.queue]
end



-- This is the functionality we'll export
local ldfuture = 
{
	isrunning = false
}



local LazyDeterministicFuture = LS.LObject()

function LazyDeterministicFuture:init(fn, ...)
	self.fn = fn
	self.args = {...}
	ldqueue:add(self)
	return self
end

function LazyDeterministicFuture:force()
	ldfuture.isrunning = true
	local retvals = { pcall(self.fn, unpack(self.args)) }
	ldfuture.isrunning = false
	ldqueue:remove(self)
	if retvals[1] then
		table.remove(retvals, 1)
		return unpack(retvals)
	else
		error(retvals[2])
	end
end



function ldfuture.create(fn, ...)
	return LazyDeterministicFuture.alloc():init(fn, ...)
end

-- Deterministic futures execute in a fixed order and
--    don't interleave their execution, so this does nothing.
function ldfuture.yield() end

-- Execute all remaining unforced futures
function ldfuture.finishall()
	assert(not ldfuture.isrunning, "future.finishall cannot be invoked from within a future")
	local futures = {}
	while not ldqueue:isempty() do
		ldqueue:back():force()
	end
end

-- Discard all remaining unforced futures
function ldfuture.killall()
	assert(not ldfuture.isrunning, "future.killall cannot be invoked from within a future")
	ldqueue:clear()
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
	self.activequeue = {}
end
function squeue:selectrandom_uniform()
	local randidx = math.ceil(trace.uniform(0, #self.activequeue))
	return self.activequeue[randidx]
end
function squeue:selectrandom_priority()
	-- If we have any futures with infinite weight, then we must sample them first
	local infs = {}
	for _,f in ipairs(self.activequeue) do
		if f.priority == math.huge then
			table.insert(infs, f)
		end
	end
	if #infs > 0 then
		local randidx = math.ceil(trace.uniform(0, #infs))
		return infs[randidx]
	end
	-- Otherwise, we sample proportional to priority
	local weights = {}
	for _,f in ipairs(self.activequeue) do
		table.insert(weights, f.priority)
	end
	util.expNoUnderflow(weights)
	local randidx = trace.multinomial(weights)
	return self.activequeue[randidx]
end
squeue.selectrandom = squeue.selectrandom_uniform
-- squeue.selectrandom = squeue.selectrandom_priority



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
	self.priority = math.huge
	-- self.priority = 1
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
		-- Propagate the error, but first kill all active futures, since execution is unrecoverable
		sfuture.killall()
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
	-- Handle situation where coroutine has yielded, potentially with a priority
	else
		self.priority = self.retvals[2] or 1
		-- self.priority = 1
	end
end



function sfuture.create(fn, ...)
	return StochasticFuture.alloc():init(fn, ...)
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
-- local future = edfuture
-- local future = ldfuture
local future = sfuture

return future




