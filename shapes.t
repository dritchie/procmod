local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("mesh")
local Vec = terralib.require("linalg.vec")


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

	terra shapes.Box(mesh: &MeshT, center: Vec3, xlen: real, ylen: real, zlen: real)
		var xh = xlen*0.5
		var yh = ylen*0.5
		var zh = zlen*0.5
		var x0y0z0 = center + Vec3.create(-xh, -yh, -zh)
		var x0y0z1 = center + Vec3.create(-xh, -yh, zh)
		var x0y1z0 = center + Vec3.create(-xh, yh, -zh)
		var x0y1z1 = center + Vec3.create(-xh, yh, zh)
		var x1y0z0 = center + Vec3.create(xh, -yh, -zh)
		var x1y0z1 = center + Vec3.create(xh, -yh, zh)
		var x1y1z0 = center + Vec3.create(xh, yh, -zh)
		var x1y1z1 = center + Vec3.create(xh, yh, zh)
		-- CCW order
		shapes.Quad(mesh, x0y1z0, x1y1z0, x1y0z0, x0y0z0) -- Back
		shapes.Quad(mesh, x0y0z1, x1y0z1, x1y1z1, x0y1z1) -- Front
		shapes.Quad(mesh, x0y0z0, x0y0z1, x0y1z1, x0y1z0) -- Left
		shapes.Quad(mesh, x1y1z0, x1y1z1, x1y0z1, x1y0z0) -- Right
		shapes.Quad(mesh, x1y0z0, x1y0z1, x0y0z1, x0y0z0) -- Bottom
		shapes.Quad(mesh, x0y1z0, x0y1z1, x1y1z1, x1y1z0) -- Top
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


return shapes



