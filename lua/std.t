local ffi = require("ffi")

local S = {}

-- Metatype that exposes standard Object stuff
-- to Lua code.
function S.Object(T)
	
	-- Allocation is done via terralib.new, but we attach a LuaJIT ffi
	--    finalizer to clean up memory
	function T.luaalloc()
		local obj = terralib.new(T)
		ffi.gc(obj, T.methods.destruct)
		return obj
	end

	function T:luainit(...)
		if T.methods.__init then
			self:__init(...)
		else
			self:initmembers()
		end
		return self
	end

	function T:newcopy()
		return T.luaalloc():copy(self)
	end

end


function S.newcopy(obj)
	if obj.newcopy then
		return obj:newcopy()
	else
		return obj
	end
end


return S