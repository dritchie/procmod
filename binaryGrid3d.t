local S = terralib.require("qs.lib.std")


-- Design inspired by mLib's binaryGrid3d.h

local BITS_PER_UINT = terralib.sizeof(uint) * 8

local struct BinaryGrid3D(S.Object)
{
	data: &uint,
	rows: uint,
	cols: uint,
	slices: uint
}

terra BinaryGrid3D:__init()
	self.rows = 0
	self.cols = 0
	self.slices = 0
	self.data = nil
end

terra BinaryGrid3D:__init(rows: uint, cols: uint, slices: uint)
	self:resize(rows, cols, slices)
end

terra BinaryGrid3D:__destruct()
	-- TODO: Make also work on CUDA?
	if self.data ~= nil then
		S.free(self.data)
	end
end

terra BinaryGrid3D:resize(rows: uint, cols: uint, slices: uint)
	self.rows = rows
	self.cols = cols
	self.slices = slices
	if self.data ~= nil then
		S.free(self.data)
	end
	-- TODO: Make also work on CUDA?
	self.data = [&uint](S.malloc(self:numuints()*sizeof(uint)))
	self:clear()
end

terra BinaryGrid3D:clear()
	for i=0,self:numuints() do
		self.data[i] = 0
	end
end

terra BinaryGrid3D:numuints()
	var numentries = self.rows*self.cols*self.slices
	return (numentries + BITS_PER_UINT - 1) / BITS_PER_UINT
end
BinaryGrid3D.methods.numuints:setinlined(true)

terra BinaryGrid3D:isVoxelSet(row: uint, col: uint, slice: uint)
	var linidx = slice*self.cols*self.rows + row*self.cols + col
	var baseIdx = linidx / BITS_PER_UINT
	var localidx = linidx % BITS_PER_UINT
	return (self.data[baseIdx] and (1 << localidx)) ~= 0
end

terra BinaryGrid3D:setVoxel(row: uint, col: uint, slice: uint)
	var linidx = slice*self.cols*self.rows + row*self.cols + col
	var baseIdx = linidx / BITS_PER_UINT
	var localidx = linidx % BITS_PER_UINT
	self.data[baseIdx] = self.data[baseIdx] or (1 << localidx)
end

terra BinaryGrid3D:toggleVoxel(row: uint, col: uint, slice: uint)
	var linidx = slice*self.cols*self.rows + row*self.cols + col
	var baseIdx = linidx / BITS_PER_UINT
	var localidx = linidx % BITS_PER_UINT
	self.data[baseIdx] = self.data[baseIdx] ^ (1 << localidx)
end

terra BinaryGrid3D:clearVoxel(row: uint, col: uint, slice: uint)
	var linidx = slice*self.cols*self.rows + row*self.cols + col
	var baseIdx = linidx / BITS_PER_UINT
	var localidx = linidx % BITS_PER_UINT
	self.data[baseIdx] = self.data[baseIdx] and not (1 << localidx)
end

BinaryGrid3D.toMesh = S.memoize(function(real)
	local Mesh = terralib.require("mesh")(real)
	local Vec3 = terralib.require("linalg.vec")(real, 3)
	local BBox3 = terralib.require("bbox")(Vec3)
	local Shape = terralib.require("shapes")(real)
	local lerp = macro(function(lo, hi, t) return `(1.0-t)*lo + t*hi end)
	return terra(grid: &BinaryGrid3D, mesh: &Mesh, bounds: &BBox3)
		mesh:clear()
		var extents = bounds:extents()
		var xsize = extents(0)/grid.cols
		var ysize = extents(1)/grid.rows
		var zsize = extents(2)/grid.slices
		for k=0,grid.slices do
			var z = lerp(bounds.mins(2), bounds.maxs(2), (k+0.5)/grid.slices)
			for i=0,grid.rows do
				var y = lerp(bounds.mins(1), bounds.maxs(1), (i+0.5)/grid.rows)
				for j=0,grid.cols do
					var x = lerp(bounds.mins(0), bounds.maxs(0), (j+0.5)/grid.cols)
					if grid:isVoxelSet(i,j,k) then
						Shape.addBox(mesh, Vec3.create(x,y,z), xsize, ysize, zsize)
					end
				end
			end
		end
	end
end)

-- -- TODO: Debug this!?!?
-- -- Write to .binvox file format
-- --    .binvox data runs y (rows) fastest, then z (slices), then x (cols)
-- BinaryGrid3D.methods.binvoxSpatialToLinear = macro(function(self, i, j, k)
-- 	return `j*self.rows*self.slices + k*self.rows + i
-- end)
-- BinaryGrid3D.methods.binvoxLinearToSpatial = macro(function(self, index)
-- 	return quote
-- 		var j = index % self.cols
-- 		var k = (index / self.cols) % self.slices
-- 		var i = index / (self.cols*self.slices)
-- 	in
-- 		i, j, k
-- 	end
-- end)
-- terra BinaryGrid3D:saveToFile(filebasename: rawstring)
-- 	if not ((self.rows == self.cols) and
-- 			(self.cols == self.slices) and
-- 			(self.slices == self.rows)) then
-- 		S.printf("BinaryGrid3D:saveToFile - .binvox requires all grid dimensions to be the same\n")
-- 		S.assert(false)
-- 	end
-- 	var fname : int8[512]
-- 	S.sprintf(fname, "%s.binvox", filebasename)
-- 	var f = S.fopen(fname, "w")
-- 	-- Write header
-- 	S.fprintf(f, "#binvox 1\n")
-- 	S.fprintf(f, "dim %u %u %u\n", self.slices, self.cols, self.rows)
-- 	S.fprintf(f, "translate 0.0 0.0 0.0\n")
-- 	S.fprintf(f, "scale 1.0\n")
-- 	S.fprintf(f, "data\n")
-- 	-- Write data
-- 	--    Data uses run-length encoding: a 0/1 byte, followed by a 'number of repetitions' byte
-- 	var numvox = self.rows*self.cols*self.slices
-- 	var index = 0
-- 	while index < numvox do
-- 		var i, j, k = self:binvoxLinearToSpatial(index)
-- 		var val = self:isVoxelSet(i, j, k)
-- 		var num = uint(0)
-- 		repeat
-- 			num = num + 1
-- 			index = index + 1
-- 			i, j, k = self:binvoxLinearToSpatial(index)
-- 		until num == 255 or index == numvox or self:isVoxelSet(i, j, k) ~= val
-- 		var byteval = uint8(val)
-- 		S.fwrite(&byteval, 1, 1, f)
-- 		S.fwrite(&num, 1, 1, f)
-- 	end
-- 	S.fclose(f)
-- end

return BinaryGrid3D




