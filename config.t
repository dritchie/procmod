local LS = terralib.require("std")


-- Holds a bunch of config options loaded from a file.

local Config = LS.LObject()

function splitstring(str)
    local fields = {}
    local pattern = "([^%s]+)"
    str:gsub(pattern, function(c) fields[#fields+1] = c end)
    return fields
end

function Config:init()
	self.__rules = {}
	return self
end

function Config:load(filename)
	for line in io.lines(filename) do
		local toks = splitstring(line)
		local key = toks[1]
		-- Skip comments and empty lines
		local isEmpty = not key
		if not isEmpty then
			local isComment = ((string.sub(key, 1, 1) == "#") and (not (key == "#include")))
			if not isComment then
				-- First, try to parse the line with any user-provided rules
				local rulerecognized = false
				for _,rule in ipairs(self.__rules) do
					if rule(self, toks) then
						rulerecognized = true
						break
					end
				end
				-- If all rules failed to recognize the line, then do default behavior
				if not rulerecognized then
					assert(#toks == 2, string.format("Found malformed config line:\n%s", line))
					local val = toks[2]
					-- Check for an include directive
					if key == "#include" then
						self:load(val)	-- val is the filename
					-- Check if the parameter is a boolean
					elseif val == "true" then val = true elseif val == "false" then val = false
					-- Check if it's a number
					elseif tonumber(val) then val = tonumber(val) end
					-- Just leave it as a raw string
					self[key] = val
				end
			end
		end
	end
end

-- Can add rules to a config object which specify how to parse certain lines
-- A rulefn takes a reference to the config object, plus a list of tokens.
-- It returns true if the rule recognizes that token stream and false otherwise.
function Config:addrule(rulefn)
	table.insert(self.__rules, rulefn)
end

return Config