local LS = require("std")


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
				if not rulerecognized then
					-- Next, see if it's an include directive
					if key == "#include" then
						assert(#toks == 2, string.format("config: malformed #include directive: '%s'", line))
						self:load(toks[2])	-- toks[2] is the filename
					else
					-- Else, do the default behavior of parsing a single value / list of values
						local lst = {}
						for i=2,#toks do
							local val = toks[i]
							-- Check if the parameter is a boolean
							if val == "true" then val = true elseif val == "false" then val = false
							-- Check if it's a number
							elseif tonumber(val) then val = tonumber(val) end
							-- (If these all fail, it'll be left as a raw string)
							table.insert(lst, val)
						end
						-- If the lst is a single element long, then store it as a value. Otherwise, store
						--    the whole list
						if #lst == 1 then
							self[key] = lst[1]
						else
							self[key] = lst
						end
					end
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
