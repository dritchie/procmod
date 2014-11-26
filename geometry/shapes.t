local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("geometry.mesh")
local Vec = terralib.require("linalg.vec")


local shapes = S.memoize(function(real)
	local Vec3 = Vec(real, 3)
	local MeshT = Mesh(real)

	local shapes = {}

	-- Builds a quad using existing vertices and adding in a new normal
	local terra quad(mesh: &MeshT, i0: uint, i1: uint, i2: uint, i3: uint)
		var ni = mesh:numNormals()
		var v0 = mesh:getVertex(i0)
		var v1 = mesh:getVertex(i1)
		var v2 = mesh:getVertex(i2)
		var n = (v2-v1):cross(v0-v1)
		n:normalize()
		mesh:addNormal(n)
		mesh:addIndex(i0, ni)
		mesh:addIndex(i1, ni)
		mesh:addIndex(i2, ni)
		mesh:addIndex(i2, ni)
		mesh:addIndex(i3, ni)
		mesh:addIndex(i0, ni)
	end

	terra shapes.Quad(mesh: &MeshT, v0: Vec3, v1: Vec3, v2: Vec3, v3: Vec3)
		var vi = mesh:numVertices()
		mesh:addVertex(v0)
		mesh:addVertex(v1)
		mesh:addVertex(v2)
		mesh:addVertex(v3)
		quad(mesh, vi+0, vi+1, vi+2, vi+3)
	end

	terra shapes.Box(mesh: &MeshT, center: Vec3, xlen: real, ylen: real, zlen: real)
		var xh = xlen*0.5
		var yh = ylen*0.5
		var zh = zlen*0.5
		var vi = mesh:numVertices()

		mesh:addVertex(center + Vec3.create(-xh, -yh, -zh))
		mesh:addVertex(center + Vec3.create(-xh, -yh, zh))
		mesh:addVertex(center + Vec3.create(-xh, yh, -zh))
		mesh:addVertex(center + Vec3.create(-xh, yh, zh))
		mesh:addVertex(center + Vec3.create(xh, -yh, -zh))
		mesh:addVertex(center + Vec3.create(xh, -yh, zh))
		mesh:addVertex(center + Vec3.create(xh, yh, -zh))
		mesh:addVertex(center + Vec3.create(xh, yh, zh))

		-- CCW order
		quad(mesh, vi+2, vi+6, vi+4, vi+0) -- Back
		quad(mesh, vi+1, vi+5, vi+7, vi+3) -- Front
		quad(mesh, vi+0, vi+1, vi+3, vi+2) -- Left
		quad(mesh, vi+6, vi+7, vi+5, vi+4) -- Right
		quad(mesh, vi+4, vi+5, vi+1, vi+0) -- Bottom
		quad(mesh, vi+2, vi+3, vi+7, vi+6) -- Top
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
				-- Caller assumes ownership of mesh's memory
				var mesh : Mesh(real)
				mesh:init()
				func(mesh, [args])
			in
				mesh
			end
		end)
	end

	return finalshapes
end)


return shapes



