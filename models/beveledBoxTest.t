local S = terralib.require("qs.lib.std")
local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)

local flip = prob.flip
local uniform = prob.uniform

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	local bevAmt = 0.25
	local n = geoRes
	-- local n = 32

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen)
	end)
	local bevbox = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBeveledBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen, bevAmt, n)
	end)

	return function()
		box(1, 0, 0,   1, 1, 1)
		bevbox(-1, 0, 0,   1, 1, 1)
	end

end)



