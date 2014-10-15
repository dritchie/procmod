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
		var diagLenSq = 3.0
		-- Test triangles only if they are small
		if (v0-v1):normSq() < diagLenSq and (v0-v2):normSq() < diagLenSq and (v1-v2):normSq() < diagLenSq then
			var tribb = BBox3.salloc():init()
			tribb:expand(v0); tribb:expand(v1); tribb:expand(v2)
			var minI = tribb.mins:floor()
			var maxI = tribb.maxs:ceil()
			for i=uint(minI(0)),uint(maxI(0)) do
				for j=uint(minI(1)),uint(maxI(1)) do
					for k=uint(minI(2)),uint(maxI(2)) do
						var v = Vec3.create(real(i), real(j), real(k))
						var voxel = BBox3.salloc():init()
						var eps = 0.0000
						voxel:expand(v - Vec3.create(0.5-eps))
						voxel:expand(v + Vec3.create(0.5+eps))
						-- Triangle has to intersect the voxel
						if voxel:intersects(v0, v1, v2) then
							-- If we only want a hollow voxelization, then we're done.
							if not solid then
								outgrid:setVoxel(i,j,k)
							-- Otherwise, we need to 'line trace' to fill in internal voxels.
							else
								-- First, check that the voxel center even lies within the 2d projection
								--    of the triangle (early out to try and avoid ray tests)
								var pointTriIsect = Intersection.intersectPointTriangle(
									Vec2.create(v0(0), v0(1)),
									Vec2.create(v1(0), v1(1)),
									Vec2.create(v2(0), v2(1)),
									Vec2.create(v(0), v(1))
								)
								if pointTriIsect then
									-- Trace rays (basically, we don't want to fill in a line of internal
									--    voxels if this triangle only intersects a sliver of this voxel--that
									--    would 'bloat' our voxelixation and make it inaccurate)
									var rd0 = Vec3.create(0.0, 0.0, 1.0)
									var rd1 = Vec3.create(0.0, 0.0, -1.0)
									var t0 : real, t1 : real, _u0 : real, _u1 : real, _v0 : real, _v1 : real
									var b0 = Intersection.intersectRayTriangle(v0, v1, v2, v, rd0, &t0, &_u0, &_v0, 0.0, 1.0)
									var b1 = Intersection.intersectRayTriangle(v0, v1, v2, v, rd1, &t1, &_u1, &_v1, 0.0, 1.0)
									if (b0 and t0 <= 0.5) or (b1 and t1 <= 0.5) then
										for kk=k,outgrid.slices do
											outgrid:toggleVoxel(i,j,kk)
										end
									end
								end
							end
						end
					end
				end
			end
		-- Otherwise, recursively subdivide
		else
			var e0 = 0.5*(v0+v1)
			var e1 = 0.5*(v1+v2)
			var e2 = 0.5*(v2+v0)
			voxelizeTriangle(outgrid, v0, e0, e2, solid)
			voxelizeTriangle(outgrid, e0, v1, e1, solid)
			voxelizeTriangle(outgrid, e1, v2, e2, solid)
			voxelizeTriangle(outgrid, e0, e1, e2, solid)
		end
	end

	terra Mesh:voxelize(outgrid: &BinaryGrid, voxelSize: real, bounds: &BBox3, solid: bool) : {}
		outgrid:destruct()
		var numvox = bounds:extents() / voxelSize
		outgrid:init(uint(numvox(1)), uint(numvox(0)), uint(numvox(2)))
		var worldtovox = Mat4.scale(1.0 / voxelSize)
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
	end

	-- Use mesh's bounding box as bounds
	terra Mesh:voxelize(outgrid: &BinaryGrid, voxelSize: real, solid: bool) : {}
		var bounds = self:bbox()
		self:voxelize(outgrid, voxelSize, &bounds, solid)
	end

	return Mesh

end)

return Mesh



