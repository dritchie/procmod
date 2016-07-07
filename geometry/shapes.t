local S = require("qs.lib.std")
local Mesh = require("geometry.mesh")
local Vec = require("linalg.vec")
local Mat = require("linalg.mat")


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

	local terra quadTextured(mesh: &MeshT, i0: uint, i1: uint, i2: uint, i3: uint,
							 			   uv0: int, uv1: int, uv2: int, uv3: int)
		var ni = mesh:numNormals()
		var v0 = mesh:getVertex(i0)
		var v1 = mesh:getVertex(i1)
		var v2 = mesh:getVertex(i2)
		var n = (v2-v1):cross(v0-v1)
		n:normalize()
		mesh:addNormal(n)
		mesh:addIndex(i0, ni, uv0)
		mesh:addIndex(i1, ni, uv1)
		mesh:addIndex(i2, ni, uv2)
		mesh:addIndex(i2, ni, uv2)
		mesh:addIndex(i3, ni, uv3)
		mesh:addIndex(i0, ni, uv0)
	end

	local terra addQuad(mesh: &MeshT, v0: Vec3, v1: Vec3, v2: Vec3, v3: Vec3) : {}
		var vi = mesh:numVertices()
		mesh:addVertex(v0)
		mesh:addVertex(v1)
		mesh:addVertex(v2)
		mesh:addVertex(v3)
		quad(mesh, vi+0, vi+1, vi+2, vi+3)
	end

	shapes.addQuad = terralib.overloadedfunction('shapes.addQuad', {})
	shapes.addQuad:adddefinition(addQuad)
	shapes.addQuad:adddefinition(quad)
	shapes.addQuad:adddefinition(quadTextured)

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

	-- The front face is tapered. Use transforms if you want to taper other faces.
	terra shapes.addTaperedBox(mesh: &MeshT, center: Vec3, xlen: real, ylen: real, zlen: real,
							   taperScale: real)
		var xh = xlen*0.5
		var yh = ylen*0.5
		var zh = zlen*0.5
		var vi = mesh:numVertices()

		-- To taper the front face, we scale vertices 1, 3, 5, and 7
		mesh:addVertex(center + Vec3.create(-xh, -yh, -zh))
		mesh:addVertex(center + Vec3.create(-taperScale*xh, -taperScale*yh, zh))
		mesh:addVertex(center + Vec3.create(-xh, yh, -zh))
		mesh:addVertex(center + Vec3.create(-taperScale*xh, taperScale*yh, zh))
		mesh:addVertex(center + Vec3.create(xh, -yh, -zh))
		mesh:addVertex(center + Vec3.create(taperScale*xh, -taperScale*yh, zh))
		mesh:addVertex(center + Vec3.create(xh, yh, -zh))
		mesh:addVertex(center + Vec3.create(taperScale*xh, taperScale*yh, zh))

		-- CCW order
		quad(mesh, vi+2, vi+6, vi+4, vi+0) -- Back
		quad(mesh, vi+1, vi+5, vi+7, vi+3) -- Front
		quad(mesh, vi+0, vi+1, vi+3, vi+2) -- Left
		quad(mesh, vi+6, vi+7, vi+5, vi+4) -- Right
		quad(mesh, vi+4, vi+5, vi+1, vi+0) -- Bottom
		quad(mesh, vi+2, vi+3, vi+7, vi+6) -- Top
	end

	local tesselatedUnitSquare = S.memoize(function(naxis, negnormal, flipwind)
		local VN = macro(function(mesh, off, c0, c1)
			local n = `1.0
			if negnormal then n = `-1.0 end
			if naxis == 0 then
				return quote
					mesh:addVertex(Vec3.create(off, c0, c1))
					mesh:addNormal(Vec3.create(n, 0.0, 0.0))
				end
			elseif naxis == 1 then
				return quote
					mesh:addVertex(Vec3.create(c0, off, c1))
					mesh:addNormal(Vec3.create(0.0, n, 0.0))
				end
			elseif naxis == 2 then
				return quote
					mesh:addVertex(Vec3.create(c0, c1, off))
					mesh:addNormal(Vec3.create(0.0, 0.0, n))
				end
			else
				error("Bad naxis")
			end
		end)
		local Q = macro(function(mesh, n, nv, nn, i, j)
			if flipwind then
				return quote
					var lli = (n+1)*i + j
					var lri = (n+1)*(i+1) + j
					var uri = (n+1)*(i+1) + (j+1)
					var uli = (n+1)*i + (j+1)
					mesh:addIndex(nn + lli, nv + lli)
					mesh:addIndex(nn + uli, nv + uli)
					mesh:addIndex(nn + uri, nv + uri)
					mesh:addIndex(nn + uri, nv + uri)
					mesh:addIndex(nn + lri, nv + lri)
					mesh:addIndex(nn + lli, nv + lli)
				end
			else
				return quote
					var lli = (n+1)*i + j
					var lri = (n+1)*(i+1) + j
					var uri = (n+1)*(i+1) + (j+1)
					var uli = (n+1)*i + (j+1)
					mesh:addIndex(nn + lli, nv + lli)
					mesh:addIndex(nn + lri, nv + lri)
					mesh:addIndex(nn + uri, nv + uri)
					mesh:addIndex(nn + uri, nv + uri)
					mesh:addIndex(nn + uli, nv + uli)
					mesh:addIndex(nn + lli, nv + lli)
				end
			end
		end)
		return terra (mesh: &MeshT, off: real, n: uint)
			var nv = mesh:numVertices()
			var nn = mesh:numNormals()
			-- Grid of vertices / normals
			var width = float(2.0)/n
			for i=0,n+1 do
				var c0 = -1.0 + width*i
				for j=0,n+1 do
					var c1 = -1.0 + width*j
					VN(mesh, off, c0, c1)
				end
			end
			-- Quads
			for i=0,n do
				for j=0,n do
					Q(mesh, n, nv, nn, i, j)
				end
			end
		end
	end)

	local lerp = macro(function(lo, hi, t) return `(1.0-t)*lo + t*hi end)
	terra shapes.addBeveledBox(mesh: &MeshT, center: Vec3, xlen: real, ylen: real, zlen: real,
							   bevelAmt: real, n: uint)

		var boxmesh = MeshT.salloc():init()
		-- Bottom face
		[tesselatedUnitSquare(1, true, false)](boxmesh, -1.0, n)
		-- Top face
		[tesselatedUnitSquare(1, false, true)](boxmesh, 1.0, n)
		-- Back face
		[tesselatedUnitSquare(2, true, true)](boxmesh, -1.0, n)
		-- Front face
		[tesselatedUnitSquare(2, false, false)](boxmesh, 1.0, n)
		-- Left face
		[tesselatedUnitSquare(0, true, true)](boxmesh, -1.0, n)
		-- Right face
		[tesselatedUnitSquare(0, false, false)](boxmesh, 1.0, n)

		-- Apply bevel
		-- http://joshparnell.com/blog/2014/02/22/rounded-box-projection/
		for i=0,boxmesh:numVertices() do
			var p = boxmesh:getVertex(i)
			var p_box = p:clamp(-Vec3.create(1.0-bevelAmt), Vec3.create(1.0-bevelAmt))
			boxmesh:getVertex(i) = p_box + bevelAmt * (p - p_box):normalized()
		end
		boxmesh:recomputeVertexNormals()

		-- Apply final scaling + placement transform
		var xform = Mat4.translate(center) * Mat4.scale(0.5*xlen, 0.5*ylen, 0.5*zlen)
		boxmesh:transform(&xform)
		mesh:append(boxmesh)
	end

	local terra circleOfVertsAndNormals(mesh: &MeshT, c: Vec3, up: Vec3, fwd: Vec3, r: double, n: uint)
		var v = c + r*up
		mesh:addVertex(v)
		mesh:addNormal((v - c):normalized())
		var rotamt = [2*math.pi]/n
		var m = Mat4.rotate(fwd, rotamt, c)
		for i=1,n do
			v = m:transformPoint(v)
			mesh:addVertex(v)
			mesh:addNormal((v - c):normalized())
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
		var initialNumNorms = mesh:numNormals()
		circleOfVertsAndNormals(mesh, baseCenter, up, fwd, radius, n)
		var afterOneCircleNumVerts = mesh:numVertices()
		circleOfVertsAndNormals(mesh, topCenter, up, fwd, radius, n)
		-- Make the sides
		var bvi = initialNumVerts
		var bni = initialNumNorms
		for i=0,n do
			var i0 = i
			var i1 = (i+1)%n
			var i2 = n + (i+1)%n
			var i3 = n + i
			mesh:addIndex(bvi+i0, bni+i0)
			mesh:addIndex(bvi+i1, bni+i1)
			mesh:addIndex(bvi+i2, bni+i2)
			mesh:addIndex(bvi+i2, bni+i2)
			mesh:addIndex(bvi+i3, bni+i3)
			mesh:addIndex(bvi+i0, bni+i0)
			-- quad(mesh, bvi + i, bvi + (i+1)%n, bvi + n + (i+1)%n, bvi + n + i)
		end
		-- Place center vertices, make the end caps
		mesh:addVertex(baseCenter)
		disk(mesh, mesh:numVertices()-1, initialNumVerts, n)
		mesh:getNormal(mesh:numNormals()-1) = -mesh:getNormal(mesh:numNormals()-1)	-- Make it face outside
		mesh:addVertex(topCenter)
		disk(mesh, mesh:numVertices()-1, afterOneCircleNumVerts, n)
	end

	terra shapes.addTaperedCylinder(mesh: &MeshT, baseCenter: Vec3, height: real, botRad: real, topRad: real, n: uint)
		var fwd = Vec3.create(0.0, 1.0, 0.0)
		var up = Vec3.create(0.0, 0.0, 1.0)
		var topCenter = baseCenter + height*fwd
		-- Make perimeter vertices on the top and bottom
		var initialNumVerts = mesh:numVertices()
		var initialNumNorms = mesh:numNormals()
		circleOfVertsAndNormals(mesh, baseCenter, up, fwd, botRad, n)
		var afterOneCircleNumVerts = mesh:numVertices()
		circleOfVertsAndNormals(mesh, topCenter, up, fwd, topRad, n)
		-- Make the sides
		var bvi = initialNumVerts
		var bni = initialNumNorms
		for i=0,n do
			var i0 = i
			var i1 = (i+1)%n
			var i2 = n + (i+1)%n
			var i3 = n + i
			mesh:addIndex(bvi+i0, bni+i0)
			mesh:addIndex(bvi+i1, bni+i1)
			mesh:addIndex(bvi+i2, bni+i2)
			mesh:addIndex(bvi+i2, bni+i2)
			mesh:addIndex(bvi+i3, bni+i3)
			mesh:addIndex(bvi+i0, bni+i0)
			-- quad(mesh, bvi + i, bvi + (i+1)%n, bvi + n + (i+1)%n, bvi + n + i)
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



