
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
	return terralib.includecstring(str, "-I", cpath)
end

-- The log of the minimum-representable double precision float
-- TODO: Replace with log of the minimum-representable *non-denormalized* double?
local LOG_DBL_MIN = -708.39641853226

-- Exponentiate a vector of log weights without causing underflow
function U.expNoUnderflow(logweights)
	local minweight = math.huge
	for _,w in ipairs(logweights) do
		if w ~= -math.huge then
			minweight = math.min(minweight, w)
		end
	end
	local underflowFix = (minweight < LOG_DBL_MIN) and (LOG_DBL_MIN - minweight) or 0
	for i=1,#logweights do logweights[i] = math.exp(logweights[i] + underflowFix) end
end


return U





