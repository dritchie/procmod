local S = terralib.require("qs.lib.std")


local MeshSet = S.memoize(function(real)

	local Mesh = terralib.require("mesh")(real)
	local Vec3 = terralib.require("linalg.vec")(real, 3)
	local BBox3 = terralib.require("bbox")(Vec3)
	local Mat4 = terralib.require("linalg.mat")(real, 4, 4)
	local BinaryGrid = terralib.require("binaryGrid3d")

	local struct MeshSet(S.Object)
	{
		meshes: S.Vector(Mesh)
	}

	-- Assumes ownership of mesh
	terra MeshSet:addMesh(mesh: &Mesh)
		self.meshes:insert(@mesh)
	end

	terra MeshSet:bbox()
		var bbox : BBox3
		bbox:init()
		for mesh in self.meshes do
			var bb = mesh:bbox()
			bbox:unionWith(&bb)
		end
		return bbox
	end

	terra MeshSet:transform(xform: &Mat4)
		for mesh in self.meshes do
			mesh:transform(xform)
		end
	end

	terra MeshSet:draw()
		for mesh in self.meshes do
			mesh:draw()
		end
	end

	-- Making this a macro because I really don't feel like duplicating all the
	--    method signatures from Mesh
	MeshSet.methods.voxelize = macro(function(self, outgrid, ...)
		local args = {...}
		return quote
			var tmpgrid = BBox3.salloc():init(outgrid.rows, outgrid.cols, outgrid.slices)
			for mesh in self.meshes do
				mesh:voxelize(tmpgrid, [args])
				outgrid:unionWith(tmpgrid)
			end
		end
	end)

	return MeshSet

end)

return MeshSet



