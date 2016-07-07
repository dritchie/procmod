
local U = {}


function U.wait(procstr)
	return io.popen(procstr):read("*a")
end

function U.osName()
	return U.wait("uname")
end

function U.includec_path(filename)
	local cpath = os.getenv("C_INCLUDE_PATH") or "."
	return terralib.includec(filename, "-I", cpath)
end

function U.includecstring_path(str)
	local cpath = os.getenv("C_INCLUDE_PATH") or "."
	return terralib.includecstring(str, {"-I", cpath})
end

function U.appendTable(t1, t2)
	for _,v in ipairs(t2) do
		table.insert(t1, v)
	end
end

-- The log of the minimum-representable double precision float
-- TODO: Replace with log of the minimum-representable *non-denormalized* double?
local LOG_DBL_MIN = -708.39641853226
local LOG_DBL_MAX = 709.78271289338

-- Exponentiate a vector of log weights without causing underflow (but see comments...)
function U.expNoUnderflow(logweights)
	local minweight = math.huge
	local maxweight = -math.huge
	for _,w in ipairs(logweights) do
		if w ~= -math.huge then
			minweight = math.min(minweight, w)
			maxweight = math.max(maxweight, w)
		end
	end
	-- First, compute the offset that would correct for all underflow
	local correction = (minweight < LOG_DBL_MIN) and (LOG_DBL_MIN - minweight) or 0
	-- However, don't let this offset cause any log weight to become larger than log(DBL_MAX/N),
	--    where N is the number of weights. This is because we ultimately need to sum the
	--    exponentiated weights, so this sum must be representable.
	local ldmn = LOG_DBL_MAX - math.log(#logweights)
	if maxweight + correction > ldmn then
		correction = ldmn - maxweight
	end
	for i=1,#logweights do logweights[i] = math.exp(logweights[i] + correction) end
end

function U.setinlinedOverloaded(overloadedfn, flag)
	for i,def in ipairs(overloadedfn:getdefinitions()) do
		def:setinlined(flag)
	end
end


return U





