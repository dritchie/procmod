local LS = terralib.require("lua.std")


-- Holds a bunch of config options loaded from a file.

local Config = LS.LObject()

function splitstring(str, sep)
    local sep, fields = sep or " ", {}
    local pattern = string.format("([^%s]+)", sep)
    str:gsub(pattern, function(c) fields[#fields+1] = c end)
    return fields
end

function Config:init(filename)
	for line in io.lines(filename) do
		local toks = splitstring(line)
		-- Skip comments and empty lines
		local key = toks[1]
		if key and not (key == "#") then
			assert(#toks == 2, string.format("Found malformed config line:\n%s", line))
			local val = toks[2]
			-- Check for an include directive
			if key == "#include" then
				self:init(val)	-- val is the filename
			-- Check if the parameter is a boolean
			elseif val == "true" then val = true elseif val == "false" then val = false
			-- Check if it's a number
			elseif tonumber(val) then val = tonumber(val) end
			-- Just leave it as a raw string
			self[key] = val
		end
	end
	return self
end

-- TODO: Metatable provides default values for params?

return Config