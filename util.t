
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


return U





