local distrib_terra = terralib.require("qs.distrib")
local distrib_lua = terralib.require("probabilistic.random")

local function go(fn, N)
	local res = 0
	for i=1,N do
		res = res + fn()
		res = res - fn()
	end
	return res
end

local function test(name, fn, N)
	local t0 = os.clock()
	go(fn, N)
	local t1 = os.clock()
	print(name .. ": ", t1-t0)
end

local N = 100000
local terra_gaussian = function() return distrib_terra.gaussian(double).sample(0.0, 1.0) end
local lua_gaussian = function() return distrib_lua.gaussian_sample(0.0, 1.0) end
local terra_poisson = function() return distrib_terra.poisson(double).sample(4.0) end
local lua_poisson = function() return distrib_lua.poisson_sample(4.0) end
test("Terra gaussian", terra_gaussian, N)
test("Lua gaussian (JIT on)", lua_gaussian, N)
jit.off()
test("Lua gaussian (JIT off)", lua_gaussian, N)
jit.on()
test("Terra poisson", terra_poisson, N)
test("Lua poisson (JIT on)", lua_poisson, N)
jit.off()
test("Lua poisson (JIT off)", lua_poisson, N)
jit.on()