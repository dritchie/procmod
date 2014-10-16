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

	local glVertex = real == float and gl.glVertex3fv or gl.glVertex3dv
	local glNormal = real == float and gl.glNormal3fv or gl.glNormal3dv

	local struct Mesh(S.Object)
	{
		vertices: S.Vector(Vec3),
		normals: S.Vector(Vec3),
		indices: S.Vector(uint)
	}

	terra Mesh:draw()
		-- Just simple immediate mode drawing for now
		gl.glBegin(gl.mGL_TRIANGLES())
		for i in self.indices do
			glNormal(&(self.normals(i).entries[0]))
			glVertex(&(self.vertices(i).entries[0]))
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
		for ov in other.vertices do
			self.vertices:insert(ov)
		end
		for on in other.normals do
			self.normals:insert(on)
		end
		for oi in other.indices do
			self.indices:insert(oi + nverts)
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

	local Vec2 = Vec(real, 2)
	local Intersection = Intersections(real)
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
		-- S.printf("===========================\n")
		-- S.printf("mins: %g, %g, %g   |   maxs: %g, %g, %g\n",
		-- 	tribb.mins(0), tribb.mins(1), tribb.mins(2), tribb.maxs(0), tribb.maxs(1), tribb.maxs(2))
		-- S.printf("minI: %g, %g, %g   |   maxi: %g, %g, %g\n",
		-- 	minI(0), minI(1), minI(2), maxI(0), maxI(1), maxI(2))
		for k=uint(minI(2)),uint(maxI(2)) do
			for i=uint(minI(1)),uint(maxI(1)) do
				for j=uint(minI(0)),uint(maxI(0)) do
					var v = Vec3.create(real(j), real(i), real(k))
					var voxel = BBox3.salloc():init(
						v,
						v + Vec3.create(1.0)
					)
					-- Triangle has to intersect the voxel
					-- S.printf("----------------------\n")
					if voxel:intersects(v0, v1, v2) then
						-- S.printf("box/tri intersect PASSED\n")
						outgrid:setVoxel(i,j,k)
					else
						-- S.printf("box/tri intersect FAILED\n")
					end
				end
			end
		end
	end

	terra Mesh:voxelize(outgrid: &BinaryGrid, bounds: &BBox3, xres: uint, yres: uint, zres: uint, solid: bool) : {}
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
		for i=0,numtris do
			var p0 = worldtovox:transformPoint(self.vertices(self.indices(3*i)))
			var p1 = worldtovox:transformPoint(self.vertices(self.indices(3*i + 1)))
			var p2 = worldtovox:transformPoint(self.vertices(self.indices(3*i + 2)))
			var tribb = BBox3.salloc():init()
			tribb:expand(p0); tribb:expand(p1); tribb:expand(p2)
			if tribb:intersects(gridbounds) then
				voxelizeTriangle(outgrid, p0, p1, p2, solid)
			end
		end
		-- If we asked for a solid voxelization, then we do a simple parity count / flood fill
		--    to fill in the interior voxels.
		-- This is not robust to a whole host of things, but the meshes I'm working with should
		--    be well-behaved enough for it not to matter.
	end

	-- Find xres,yres,zres given a target voxel size
	terra Mesh:voxelize(outgrid: &BinaryGrid, bounds: &BBox3, voxelSize: real, solid: bool) : {}
		var numvox = (bounds:extents() / voxelSize):ceil()
		self:voxelize(outgrid, bounds, uint(numvox(0)), uint(numvox(1)), uint(numvox(2)), solid)
	end

	-- Use mesh's bounding box as bounds for voxelization
	terra Mesh:voxelize(outgrid: &BinaryGrid, xres: uint, yres: uint, zres: uint, solid: bool) : {}
		var bounds = self:bbox()
		self:voxelize(outgrid, &bounds, xres, yres, zres, solid)
	end
	terra Mesh:voxelize(outgrid: &BinaryGrid, voxelSize: real, solid: bool) : {}
		var bounds = self:bbox()
		self:voxelize(outgrid, &bounds, voxelSize, solid)
	end

	return Mesh

end)

return Mesh



