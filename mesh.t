local S = terralib.require("qs.lib.std")
local gl = terralib.require("gl.gl")
local Vec = terralib.require("linalg.vec")
local Mat = terralib.require("linalg.mat")
local BBox = terralib.require("bbox")
local BinaryGrid = terralib.require("binaryGrid3d")
local Intersections = terralib.require("intersection")


-- Super simple mesh struct that can accumulate geometry and draw itself

local Mesh = S.memoize(function(real)

	assert(real == float or real == double,
		"Mesh: real must be float or double")

	local Vec3 = Vec(real, 3)
	local Mat4 = Mat(real, 4, 4)
	local BBox3 = BBox(Vec3)
	local Vec2 = Vec(real, 2)
	local Intersection = Intersections(real)

	local glVertex = real == float and gl.glVertex3fv or gl.glVertex3dv
	local glNormal = real == float and gl.glNormal3fv or gl.glNormal3dv

	local struct Index { vertex: uint, normal: uint }

	local struct Mesh(S.Object)
	{
		vertices: S.Vector(Vec3),
		normals: S.Vector(Vec3),
		indices: S.Vector(Index)
	}

	terra Mesh:numVertices() return self.vertices:size() end
	terra Mesh:numNormals() return self.normals:size() end
	terra Mesh:numIndices() return self.indices:size() end
	terra Mesh:numTris() return self:numIndices()/3 end

	terra Mesh:addVertex(vert: Vec3) self.vertices:insert(vert) end
	terra Mesh:addNormal(norm: Vec3) self.normals:insert(norm) end
	terra Mesh:addIndex(vind: uint, nind: uint) self.indices:insert(Index{vind,nind}) end

	terra Mesh:draw()
		-- Just simple immediate mode drawing for now
		gl.glBegin(gl.mGL_TRIANGLES())
		for i in self.indices do
			glNormal(&(self.normals(i.normal).entries[0]))
			glVertex(&(self.vertices(i.vertex).entries[0]))
		end
		gl.glEnd()
	end

	terra Mesh:clear()
		self.vertices:clear()
		self.normals:clear()
		self.indices:clear()
	end

	terra Mesh:append(other: &Mesh)
		var nverts = self.vertices:size()
		var nnorms = self.normals:size()
		for ov in other.vertices do
			self:addVertex(ov)
		end
		for on in other.normals do
			self:addNormal(on)
		end
		for oi in other.indices do
			self:addIndex(oi.vertex + nverts, oi.normal + nnorms)
		end
	end

	terra Mesh:transform(xform: &Mat4)
		for i=0,self.vertices:size() do
			self.vertices(i) = xform:transformPoint(self.vertices(i))
		end
		-- TODO: Implement 4x4 matrix inversion and use the inverse transpose
		--    for the normals (I expect to only use rotations and uniform scales
		--    for the time being, so this should be fine for now).
		for i=0,self.normals:size() do
			self.normals(i) = xform:transformVector(self.normals(i))
		end
	end

	terra Mesh:bbox()
		var bbox : BBox3
		bbox:init()
		for v in self.vertices do
			bbox:expand(v)
		end
		return bbox
	end

	-- How many intersections are there between triangles in other and triangles in self?
	-- Pretty stupid: Just loops over every triangle in other and checks it against every triangle in self
	--    (doing early out with bounding box tests)
	-- Contracts both of the triangles by a tiny epsilon so that touching (but not interpentratring)
	--    faces are not considered intersecting.
	local contractTri = macro(function(v0, v1, v2)
		local CONTRACT_EPS = 1e-10
		return quote
			var centroid = (v0 + v1 + v2) / 3.0
			v0 = v0 - (v0 - centroid)*CONTRACT_EPS
			v1 = v1 - (v1 - centroid)*CONTRACT_EPS
			v2 = v2 - (v2 - centroid)*CONTRACT_EPS
		end
	end)
	terra Mesh:numIntersectingTris(other: &Mesh)
		var numIsects = 0
		var numSelfTris = self.indices:size() / 3
		var numOtherTris = other.indices:size() / 3
		for i=0,numOtherTris do
			var v0 = other.vertices(self.indices(3*i).vertex)
			var v1 = other.vertices(self.indices(3*i + 1).vertex)
			var v2 = other.vertices(self.indices(3*i + 2).vertex)
			contractTri(v0, v1, v2)
			var otherbbox = BBox3.salloc():init()
			otherbbox:expand(v0); otherbbox:expand(v1); otherbbox:expand(v2)
			for j=0,numSelfTris do
				var u0 = self.vertices(self.indices(3*j).vertex)
				var u1 = self.vertices(self.indices(3*j + 1).vertex)
				var u2 = self.vertices(self.indices(3*j + 2).vertex)
				contractTri(u0, u1, u2)
				var selfbbox = BBox3.salloc():init()
				selfbbox:expand(u0); selfbbox:expand(u1); selfbbox:expand(u2)
				if selfbbox:intersects(otherbbox) then
					if Intersection.intersectTriangleTriangle(u0, u1, u2, v0, v1, v2, false) then
						numIsects = numIsects + 1
					end
				end
			end
		end
		return numIsects
	end

	terra Mesh:intersects(other: &Mesh)
		return self:numIntersectingTris(other) > 0
	end

	terra Mesh:numSelfIntersectingTris()
		return self:numIntersectingTris(self)
	end

	terra Mesh:selfIntersects()
		return self:numSelfIntersectingTris() > 0
	end

	local terra voxelizeTriangle(outgrid: &BinaryGrid, v0: Vec3, v1: Vec3, v2: Vec3, solid: bool) : {}
		var tribb = BBox3.salloc():init()
		tribb:expand(v0); tribb:expand(v1); tribb:expand(v2)
		-- If a triangle is perfectly axis-aligned, it will 'span' zero voxels, so the loops below
		--    will do nothing. To get around this, we expand the bbox a little bit.
		tribb:expand(0.000001)
		var minI = tribb.mins:floor()
		var maxI = tribb.maxs:ceil()
		-- Take care to ensure that we don't loop over any voxels that are outside the actual grid.
		minI:maxInPlace(Vec3.create(0.0))
		maxI:minInPlace(Vec3.create(real(outgrid.cols), real(outgrid.rows), real(outgrid.slices)))
		for k=uint(minI(2)),uint(maxI(2)) do
			for i=uint(minI(1)),uint(maxI(1)) do
				for j=uint(minI(0)),uint(maxI(0)) do
					var v = Vec3.create(real(j), real(i), real(k))
					var voxel = BBox3.salloc():init(
						v,
						v + Vec3.create(1.0)
					)
					-- Triangle has to intersect the voxel
					if voxel:intersects(v0, v1, v2) then
						outgrid:setVoxel(i,j,k)
					end
				end
			end
		end
	end

	-- Returns the number of triangles that fell outside the bounds
	terra Mesh:voxelize(outgrid: &BinaryGrid, bounds: &BBox3, xres: uint, yres: uint, zres: uint, solid: bool) : uint
		outgrid:resize(yres, xres, zres)
		var extents = bounds:extents()
		var xsize = extents(0)/xres
		var ysize = extents(1)/yres
		var zsize = extents(2)/zres
		var worldtovox = Mat4.scale(1.0/xsize, 1.0/ysize, 1.0/zsize) * Mat4.translate(-bounds.mins)
		var numtris = self.indices:size() / 3
		var gridbounds = BBox3.salloc():init(
			Vec3.create(0.0),
			Vec3.create(real(outgrid.cols), real(outgrid.rows), real(outgrid.slices))
		)
		var numOutsideTris = 0
		for i=0,numtris do
			var p0 = worldtovox:transformPoint(self.vertices(self.indices(3*i).vertex))
			var p1 = worldtovox:transformPoint(self.vertices(self.indices(3*i + 1).vertex))
			var p2 = worldtovox:transformPoint(self.vertices(self.indices(3*i + 2).vertex))
			var tribb = BBox3.salloc():init()
			tribb:expand(p0); tribb:expand(p1); tribb:expand(p2)
			if tribb:intersects(gridbounds) then
				voxelizeTriangle(outgrid, p0, p1, p2, solid)
			else
				numOutsideTris = numOutsideTris + 1
			end
		end
		if solid then
			outgrid:fillInterior()
		end
		return numOutsideTris
	end

	-- Find xres,yres,zres given a target voxel size
	terra Mesh:voxelize(outgrid: &BinaryGrid, bounds: &BBox3, voxelSize: real, solid: bool) : uint
		var numvox = (bounds:extents() / voxelSize):ceil()
		return self:voxelize(outgrid, bounds, uint(numvox(0)), uint(numvox(1)), uint(numvox(2)), solid)
	end

	-- Use mesh's bounding box as bounds for voxelization
	terra Mesh:voxelize(outgrid: &BinaryGrid, xres: uint, yres: uint, zres: uint, solid: bool) : uint
		var bounds = self:bbox()
		return self:voxelize(outgrid, &bounds, xres, yres, zres, solid)
	end
	terra Mesh:voxelize(outgrid: &BinaryGrid, voxelSize: real, solid: bool) : uint
		var bounds = self:bbox()
		return self:voxelize(outgrid, &bounds, voxelSize, solid)
	end

	-- Super simple: only handles triangular faces, doesn't handle UVs.
	-- f directives are assumed to be of the form vi//ni (i.e. requires normals).
	local C = terralib.includec("string.h")
	local delim = " /\n"
	terra Mesh:loadOBJ(filename: rawstring)
		var f = S.fopen(filename, "r")
		if f == nil then
			S.printf("Mesh:loadOBJ - could not open file '%s'\n", filename)
			S.assert(false)
		end
		var line : int8[1024]
		var numlines = 0
		while S.fgets(line, 1024, f) ~= nil do
			var cmd = C.strtok(line, delim)
			-- Skip empty lines and lines starting with #
			if cmd ~= nil and C.strcmp(cmd, "#") ~= 0 then
				if C.strcmp(cmd, "f") == 0 then
					var vi = S.atoi(C.strtok(nil, delim)) - 1
					var ni = S.atoi(C.strtok(nil, delim)) - 1
					self:addIndex(vi, ni)
					vi = S.atoi(C.strtok(nil, delim)) - 1
					ni = S.atoi(C.strtok(nil, delim)) - 1
					self:addIndex(vi, ni)
					vi = S.atoi(C.strtok(nil, delim)) - 1 
					ni = S.atoi(C.strtok(nil, delim)) - 1
					self:addIndex(vi, ni)
				elseif C.strcmp(cmd, "v") == 0 then
					var x = S.atof(C.strtok(nil, delim))
					var y = S.atof(C.strtok(nil, delim))
					var z = S.atof(C.strtok(nil, delim))
					self:addVertex(Vec3.create(x,y,z))
				elseif C.strcmp(cmd, "vn") == 0 then
					var x = S.atof(C.strtok(nil, delim))
					var y = S.atof(C.strtok(nil, delim))
					var z = S.atof(C.strtok(nil, delim))
					self:addNormal(Vec3.create(x,y,z))
				end
			end
		end
		S.fclose(f)
	end

	return Mesh

end)

return Mesh



