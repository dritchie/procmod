local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("geometry.mesh")
local Vec = terralib.require("linalg.vec")
local Mat = terralib.require("linalg.mat")


local shapes = S.memoize(function(real)
	local Vec3 = Vec(real, 3)
	local Mat4 = Mat(real, 4, 4)
	local MeshT = Mesh(real)

	local shapes = {}

	-- Builds a quad using existing vertices and adding in a new normal
	local terra quad(mesh: &MeshT, i0: uint, i1: uint, i2: uint, i3: uint) : {}
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

	terra shapes.addQuad(mesh: &MeshT, v0: Vec3, v1: Vec3, v2: Vec3, v3: Vec3) : {}
		var vi = mesh:numVertices()
		mesh:addVertex(v0)
		mesh:addVertex(v1)
		mesh:addVertex(v2)
		mesh:addVertex(v3)
		quad(mesh, vi+0, vi+1, vi+2, vi+3)
	end

	shapes.addQuad:adddefinition(quad:getdefinitions()[1])

	terra shapes.addBox(mesh: &MeshT, center: Vec3, xlen: real, ylen: real, zlen: real) : {}
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

	local terra circleOfVerts(mesh: &MeshT, c: Vec3, up: Vec3, fwd: Vec3, r: double, n: uint)
		var v = c + r*up
		mesh:addVertex(v)
		var rotamt = [2*math.pi]/n
		var m = Mat4.rotate(fwd, rotamt, c)
		for i=1,n do
			v = m:transformPoint(v)
			mesh:addVertex(v)
		end
	end

	-- Assumed that the first vertex is the center vertex, with the subsequent
	--    n being the circle around it.
	local terra disk(mesh: &MeshT, centeridx: uint, baseidx: uint, n: uint)
		var numN = mesh:numNormals()
		var v0 = mesh:getVertex(centeridx)
		var v1 = mesh:getVertex(baseidx)
		var v2 = mesh:getVertex(baseidx+1)
		var normal = (v2-v1):cross(v0-v1):normalized()
		mesh:addNormal(normal)
		for i=0,n do
			mesh:addIndex(centeridx, numN)
			mesh:addIndex(baseidx+i, numN)
			mesh:addIndex(baseidx+(i+1)%n, numN)
		end
	end

	terra shapes.addCylinder(mesh: &MeshT, baseCenter: Vec3, height: real, radius: real, n: uint)
		var fwd = Vec3.create(0.0, 1.0, 0.0)
		var up = Vec3.create(0.0, 0.0, 1.0)
		var topCenter = baseCenter + height*fwd
		-- Make perimeter vertices on the top and bottom
		var initialNumVerts = mesh:numVertices()
		circleOfVerts(mesh, baseCenter, up, fwd, radius, n)
		var afterOneCircleNumVerts = mesh:numVertices()
		circleOfVerts(mesh, topCenter, up, fwd, radius, n)
		-- Make the sides
		var bvi = initialNumVerts
		for i=0,n do
			quad(mesh, bvi + i, bvi + (i+1)%n, bvi + n + (i+1)%n, bvi + n + i)
		end
		-- Place center vertices, make the end caps
		mesh:addVertex(baseCenter)
		disk(mesh, mesh:numVertices()-1, initialNumVerts, n)
		mesh:getNormal(mesh:numNormals()-1) = -mesh:getNormal(mesh:numNormals()-1)	-- Make it face outside
		mesh:addVertex(topCenter)
		disk(mesh, mesh:numVertices()-1, afterOneCircleNumVerts, n)
	end

	-- Transformed versions of every shape function
	local names = {}
	for k,_ in pairs(shapes) do table.insert(names, k) end
	for _,name in ipairs(names) do
		local rawfn = shapes[name]
		shapes[string.format("%sTransformed", name)] = macro(function(mesh, xform, ...)
			local args = {...}
			return quote
				var vstarti = mesh:numVertices()
				var nstarti = mesh:numNormals()
				rawfn(mesh, [args])
				var vendi = mesh:numVertices()
				var nendi = mesh:numNormals()
				mesh:transform(xform, vstarti, vendi, nstarti, nendi)
			end
		end)
	end

	return shapes
end)


return shapes



