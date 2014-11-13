local trace = terralib.require("lua.trace")

local prob = {
	flip = trace.flip,
	uniform = trace.uniform,
	factor = trace.factor,
	likelihood = trace.likelihood
}

return prob