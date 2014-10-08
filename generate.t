local Mesh = terralib.require("mesh")
local Vec = terralib.require("linalg.vec")
local Shapes = terralib.require("shapes")


-- Main will call the function returned by this module


-- local Vec3 = Vec(double, 3)
-- local Shape = Shapes(double)
-- return terra(mesh: &Mesh(double))
-- 	mesh:clear()
-- 	-- Shape.addQuad(mesh, Vec3.create(-1.0, -1.0, -3.0),
-- 	-- 					Vec3.create(1.0, -1.0, -3.0),
-- 	-- 					Vec3.create(1.0, 1.0, -3.0),
-- 	-- 					Vec3.create(-1.0, 1.0, -3.0))
-- 	Shape.addBox(mesh, Vec3.create(0.0, 0.0, -4.0), 2.0, 2.0, 2.0)
-- end


local qs = terralib.require("qs")
local p = qs.program(function()
	local Vec3 = Vec(qs.real, 3)
	local Shape = Shapes(qs.real)
	return terra()
		-- Stack some random, horizontally-symmetric boxes
		var mesh : Mesh(qs.real)
		mesh:init()
		var nboxes = qs.poisson(5) + 1
		var xbase = 0.0
		var zlo = -5.0
		var zhi = 5.0
		for i=0,nboxes do
			-- TODO: ranges stay synced during MH proposals???
			var zbase = qs.uniform(zlo, zhi, {struc=false})
			var xlen = qs.uniform(0.25, 2.0, {struc=false})
			var ylen = qs.uniform(0.25, 2.0, {struc=false})
			var zlen = qs.uniform(0.5, 4.0, {struc=false})
			Shape.addBox(&mesh, Vec3.create(xbase + 0.5*xlen, 0.0, zbase), xlen, ylen, zlen)
			Shape.addBox(&mesh, Vec3.create(-(xbase + 0.5*xlen), 0.0, zbase), xlen, ylen, zlen)
			xbase = xbase + xlen
			zlo = zbase - 0.5*zlen
			zhi = zbase + 0.5*zlen
		end
		return mesh
	end
end)
local gen = p:compile()
return terra(mesh: &Mesh(double))
	mesh:destruct()
	@mesh = gen()
end

