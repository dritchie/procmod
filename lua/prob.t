local trace = terralib.require("lua.trace")
local future = terralib.require("lua.future")

local prob = {
	flip = trace.flip,
	uniform = trace.uniform,
	factor = trace.factor,
	likelihood = trace.likelihood,
	future = future
}

return prob