local trace = terralib.require("lua.trace")
local future = terralib.require("lua.future")

local prob = {
	-- ERPs
	flip = trace.flip,
	uniform = trace.uniform,
	factor = trace.factor,

	-- Likelihood adjustments
	likelihood = trace.likelihood,
	future = future,

	-- Address management
	pushAddress = trace.pushAddress,
	popAddress = trace.popAddress,
	setAddressLoopIndex = trace.setAddressLoopIndex
}

return prob