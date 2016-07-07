local ffi = require("ffi")

local S = {}

function S.copytable(tbl)
	local t = {}
	for k,v in pairs(tbl) do
		t[k] = v
	end
	return t
end

-- Allocation is done via terralib.new, but we attach a LuaJIT ffi
--    finalizer to clean up memory
function S.luaalloc(T)
	-- I think this'll allow me to use more memory, especially if
	--   I'm allocing lots of large structs.
	local obj = terralib.new(&T)
	obj = T.methods.alloc()
	ffi.gc(obj, T.methods.delete)
	-- local obj = terralib.new(T)
	-- ffi.gc(obj, T.methods.destruct)
	return obj
end

function S.luacallmethod(self, methodname, ...)
	local T = terralib.typeof(self)
	if T:ispointertostruct() then T = T.type end
	local method = T.methods[methodname]
	assert(method, 'Struct type ' .. tostring(T) .. ' has no method ' .. methodname)
	if terralib.isfunction(method) then
		return method(self, ...)
	elseif terralib.isoverloadedfunction(method) then
		-- Try all versions
		local args = {...}
		local rets = nil
		for i,def in ipairs(method:getdefinitions()) do
			local tryfn = function() return def(self, unpack(args)) end
			rets = { pcall(tryfn) }
			if rets[1] then break end
			-- print(rets[2])
		end

		assert(rets[1], 'Struct type ' .. tostring(T) .. ' has no appropriate overload of method '
			.. methodname .. ' for arguments ' .. tostring(args))
		table.remove(rets, 1)
		return unpack(rets)
	end
end

function doluainit(T, self, ...)
	if T.methods.__init then
		-- self:__init(...)
		S.luacallmethod(self, '__init', ...)
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
	if obj and obj.newcopy then
		return obj:newcopy()
	else
		return obj
	end
end


-- Terra metatype that exposes standard Object stuff
-- to Lua code.
function S.Object(T)

	function T.luaalloc()
		return S.luaalloc(T)
	end

	T.methods.luainit = function(self, ...)
		return doluainit(T, self, ...)
	end

	T.methods.newcopy = function(self)
		local newobj = T.luaalloc()
		newobj:copy(self)
		return newobj
	end

end

-- Lua 'metatype' that adds some common functionality
function S.LObject(T)

	T = T or {}
	T.__index = T
	
	function T.alloc()
		local obj = {}
		setmetatable(obj, T)
		return obj
	end

	-- Will error if the copy method doesn't exist, but that's
	--    probably the right behavior
	function T:newcopy()
		return T.alloc():copy(self)
	end

	return T

end


return S
