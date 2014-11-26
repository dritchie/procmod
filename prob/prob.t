local trace = terralib.require("prob.trace")
local future = terralib.require("prob.future")

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