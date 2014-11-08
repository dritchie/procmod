-- Stochastic futures


-- Deterministic ordering
function genBody(...)
	local finished = false
	repeat
		if flip(P_WING) then
			genWing(...)
		end
		if flip(P_FIN) then
			genFin(...)
		end
		-- The call to 'flip' will pause the current thread and pick a random other
		--    thread to execute, but there are no other threads available except the
		--    one that just yielded.
		finished = flip(P_FINISH)
	until finished
end



-- Random interleaving of wing and fin creation, but both must still
--    finish before the next iteration in the body loop
function genBody(...)
	local finished = false
	repeat
		-- Create computations that may begin running at any time in any order
		--    with respect to other such computations
		local wing = future.create(function()
			if flip(P_WING) then
				genWing(...)
			end
		end)
		local fin = future.create(function()
			if flip(P_FIN) then
				genFin(...)
			end
		end)
		-- Suspends the current execution thread until the future has finished
		-- (Implementation: continue executing coroutines at random, but mark the one that
		--    called 'force' as 'un-continuable' until the forced coroutine completes)
		future.force(wing)
		future.force(fin)
		finished = flip(P_FINISH)
	until finished
end



-- Futures can also return values
function genBody(...)
	local finished = false
	repeat
		local wing = future.create(function()
			if flip(P_WING) then
				genWing(...)
			end
			return 0
		end)
		local fin = future.create(function()
			if flip(P_FIN) then
				genFin(...)
			end
			return 1
		end)
		local w = future.force(wing)
		local f = future.force(fin)
		finished = flip(P_FINISH)
	until finished
end



-- This common pattern of running multiple functions in any interleaved order could
--    be encapsulated in a utility function 'concurrently':
function genBody(...)
	local finished = false
	repeat
		local wing = function()
			if flip(P_WING) then
				genWing(...)
			end
			return 0
		end
		local fin = function()
			if flip(P_FIN) then
				genFin(...)
			end
			return 1
		end
		-- Could also implement a version that accepts a table of functions and returns
		--    a table of values.
		local w, f = concurrently(wing, fin)
		finished = flip(P_FINISH)
	until finished
end



-- Full randomization: wings and fin are generated in random order, and the
--    body loop can proceed to subsequent iterations before they finish
-- Works because futures that are never forced are still guaranteed to terminate
--    before the program exits
-- This pattern seems useful only to imperative code, because un-forced futures have
--    nowhere to return values and thus can only do useful work via side effects
function genBody(...)
	local finished = false
	repeat
		future.create(function()
			if flip(P_WING) then
				genWing(...)
			end
		end)
		future.create(function()
			if flip(P_FIN) then
				genFin(...)
			end
		end)
		finished = flip(P_FINISH)
	until finished
end



-- This pattern of using un-forced futures to get 'as-lazy-as-possible'
--    execution can also be encapsulated in a utility function 'eventually':
function genBody(...)
	local finished = false
	repeat
		eventually(function()
			if flip(P_WING) then
				genWing(...)
			end
		end)
		eventually(function()
			if flip(P_FIN) then
				genFin(...)
			end
		end)
		finished = flip(P_FINISH)
	until finished
end




