local ffi = require("ffi")

local S = {}

function S.luaalloc(T)
	local obj = terralib.new(T)
	ffi.gc(obj, T.methods.destruct)
	return obj
end

function doluainit(T, self, ...)
	if T.methods.__init then
		self:__init(...)
	else
		self:initmembers()
	end
	return self
end


function S.luainit(self, ...)
	local T = terralib.typeof(self)
	if T:ispointertostruct() then T = T.type end
	return doluainit(T, self, ...)
end

function S.newcopy(obj)
	if obj.newcopy then
		return obj:newcopy()
	else
		return obj
	end
end


-- Metatype that exposes standard Object stuff
-- to Lua code.
function S.Object(T)
	
	-- Allocation is done via terralib.new, but we attach a LuaJIT ffi
	--    finalizer to clean up memory
	function T.luaalloc()
		return S.luaalloc(T)
	end

	T.methods.luainit = function(self, ...)
		return doluainit(T, self, ...)
	end

	T.methods.newcopy = function(self)
		return T.luaalloc():copy(self)
	end

end


return S