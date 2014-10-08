local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("mesh")
local Vec = terralib.require("linalg.vec")
local Shapes = terralib.require("shapes")

local Vec3 = Vec(double, 3)
local Shape = Shapes(double)

-- Main will call this
return terra(mesh: &Mesh(double))
	mesh:clear()
	-- Shape.addQuad(mesh, Vec3.create(-1.0, -1.0, -3.0),
	-- 					Vec3.create(1.0, -1.0, -3.0),
	-- 					Vec3.create(1.0, 1.0, -3.0),
	-- 					Vec3.create(-1.0, 1.0, -3.0))
	Shape.addBox(mesh, Vec3.create(0.0, 0.0, -4.0), 2.0, 2.0, 2.0)
end



