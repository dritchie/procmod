local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("mesh")
local Vec = terralib.require("linalg.vec")

local Vec3 = Vec(double, 3)


-- Do cool procedural generation here

local shapes = S.memoize(function(real)
	local Vec3 = Vec(real, 3)
	local MeshT = Mesh(real)

	local shapes = {}

	terra shapes.Quad(mesh: &MeshT, v0: Vec3, v1: Vec3, v2: Vec3, v3: Vec3)
		var baseIndex = mesh.vertices:size()
		mesh.vertices:insert(v0)
		mesh.vertices:insert(v1)
		mesh.vertices:insert(v2)
		mesh.vertices:insert(v3)
		var n = (v2-v1):cross(v0-v1)
		n:normalize()
		mesh.normals:insert(n)
		mesh.normals:insert(n)
		mesh.normals:insert(n)
		mesh.normals:insert(n)
		mesh.indices:insert(baseIndex+0)
		mesh.indices:insert(baseIndex+1)
		mesh.indices:insert(baseIndex+2)
		mesh.indices:insert(baseIndex+2)
		mesh.indices:insert(baseIndex+3)
		mesh.indices:insert(baseIndex+0)
	end

	-- Two versions of every generator:
	--    * 'add' - appends the geometry to an existing mesh
	--    * 'make' - creates a new mesh with the geometry
	local finalshapes = {}
	for name,func in pairs(shapes) do
		finalshapes[string.format("add%s", name)] = func
		finalshapes[string.format("make%s", name)] = macro(function(...)
			local args = {...}
			return quote
				var mesh = [Mesh(real)].salloc():init()
				func(mesh, [args])
			in
				mesh
			end
		end)
	end

	return finalshapes
end)

local Shapes = shapes(double)

-- Main will call this
return terra(mesh: &Mesh(double))
	mesh:clear()
	Shapes.addQuad(mesh, Vec3.create(-1.0, -1.0, -3.0),
						 Vec3.create(1.0, -1.0, -3.0),
						 Vec3.create(1.0, 1.0, -3.0),
						 Vec3.create(-1.0, 1.0, -3.0))
end



