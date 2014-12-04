local S = terralib.require("qs.lib.std")
local Vec = terralib.require("linalg.vec")
local BBox = terralib.require("geometry.bbox")
local C = terralib.includecstring [[
#include <string.h>
]]

-- Design inspired by mLib's binaryGrid3d.h

local BITS_PER_UINT = terralib.sizeof(uint) * 8

local struct BinaryGrid3D(S.Object)
{
	data: &uint,
	rows: uint,
	cols: uint,
	slices: uint
}

terra BinaryGrid3D:__init() : {}
	self.rows = 0
	self.cols = 0
	self.slices = 0
	self.data = nil
end

terra BinaryGrid3D:__init(rows: uint, cols: uint, slices: uint) : {}
	self:__init()
	self:resize(rows, cols, slices)
end

terra BinaryGrid3D:__copy(other: &BinaryGrid3D)
	self:__init(other.rows, other.cols, other.slices)
	C.memcpy(self.data, other.data, self:numuints()*sizeof(uint))
end

terra BinaryGrid3D:__destruct()
	if self.data ~= nil then
		S.free(self.data)
	end
end

terra BinaryGrid3D:resize(rows: uint, cols: uint, slices: uint)
	if self.rows ~= rows or self.cols ~= cols or self.slices ~= slices then
		self.rows = rows
		self.cols = cols
		self.slices = slices
		if self.data ~= nil then
			S.free(self.data)
		end
		self.data = [&uint](S.malloc(self:numuints()*sizeof(uint)))
		self:clear()
	end
end

terra BinaryGrid3D:clear()
	for i=0,self:numuints() do
		self.data[i] = 0
	end
end

terra BinaryGrid3D:numcells()
	return self.rows*self.cols*self.slices
end
BinaryGrid3D.methods.numcells:setinlined(true)

terra BinaryGrid3D:numuints()
	return (self:numcells() + BITS_PER_UINT - 1) / BITS_PER_UINT
end
BinaryGrid3D.methods.numuints:setinlined(true)

terra BinaryGrid3D:numCellsPadded()
	return self:numuints() * BITS_PER_UINT
end
BinaryGrid3D.methods.numCellsPadded:setinlined(true)

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

terra BinaryGrid3D:unionWith(other: &BinaryGrid3D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols and
			 self.slices == other.slices)
	for i=0,self:numuints() do
		self.data[i] = self.data[i] or other.data[i]
	end
end

local struct Voxel { i: uint, j: uint, k: uint }
local Vec3u = Vec(uint, 3)
local BBox3u = BBox(Vec3u)
terra BinaryGrid3D:fillInterior(bounds: &BBox3u) : {}
	var visited = BinaryGrid3D.salloc():copy(self)
	var frontier = BinaryGrid3D.salloc():init(self.rows, self.cols, self.slices)
	-- Start expanding from every cell we haven't yet visited (already filled
	--    cells count as visited)
	for k=bounds.mins(2),bounds.maxs(2) do
		for i=bounds.mins(1),bounds.maxs(1) do
			for j=bounds.mins(0),bounds.maxs(0) do
				if not visited:isVoxelSet(i,j,k) then
					var isoutside = false
					var fringe = [S.Vector(Voxel)].salloc():init()
					fringe:insert(Voxel{i,j,k})
					while fringe:size() ~= 0 do
						var v = fringe:remove()
						frontier:setVoxel(v.i, v.j, v.k)
						-- If we expanded to the edge of the bounds, then this region is outside
						if v.i == bounds.mins(1) or v.i == bounds.maxs(1)-1 or
						   v.j == bounds.mins(0) or v.j == bounds.maxs(0)-1 or
						   v.k == bounds.mins(2) or v.k == bounds.maxs(2)-1 then
							isoutside = true
						-- Otherwise, expand to the neighbors
						else
							visited:setVoxel(v.i, v.j, v.k)
							if not visited:isVoxelSet(v.i-1, v.j, v.k) then
								fringe:insert(Voxel{v.i-1, v.j, v.k})
							end
							if not visited:isVoxelSet(v.i+1, v.j, v.k) then
								fringe:insert(Voxel{v.i+1, v.j, v.k})
							end
							if not visited:isVoxelSet(v.i, v.j-1, v.k) then
								fringe:insert(Voxel{v.i, v.j-1, v.k})
							end
							if not visited:isVoxelSet(v.i, v.j+1, v.k) then
								fringe:insert(Voxel{v.i, v.j+1, v.k})
							end
							if not visited:isVoxelSet(v.i, v.j, v.k-1) then
								fringe:insert(Voxel{v.i, v.j, v.k-1})
							end
							if not visited:isVoxelSet(v.i, v.j, v.k+1) then
								fringe:insert(Voxel{v.i, v.j, v.k+1})
							end
						end
					end
					-- Once we've grown this region to completion, check whether it is
					--    inside or outside. If inside, add it to self
					if not isoutside then
						self:unionWith(frontier)
					end
					frontier:clear()
				end
			end
		end
	end
end

terra BinaryGrid3D:fillInterior() : {}
	var bounds = BBox3u.salloc():init(
		Vec3u.create(0),
		Vec3u.create(self.cols, self.rows, self.slices)
	)
	self:fillInterior(bounds)
end

BinaryGrid3D.toMesh = S.memoize(function(real)
	local Vec3 = Vec(real, 3)
	local BBox3 = BBox(Vec3)
	local Mesh = terralib.require("geometry.mesh")(real)
	local Shape = terralib.require("geometry.shapes")(real)
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

-- Input: target bounds, desired padding factor, desired voxel size.
-- Returns: Padded bounds, dimensions of padded grid, translation of target bounds into grid coords.
local Vec3d = Vec(double, 3)
local BBox3d = BBox(Vec3d)
local terra toVec3u(v: Vec3d)
	return Vec3u.create(uint(v(0)), uint(v(1)), uint(v(2)))
end
BinaryGrid3D.methods.paddedGridBounds = terra(targetBounds: &BBox3d, padFactor: double, voxelSize: double)
	-- Determine padded bounds
	var paddedBounds : BBox3d
	paddedBounds:copy(targetBounds)
	var targetExtents = targetBounds:extents()
	paddedBounds.mins = paddedBounds.mins - padFactor*targetExtents
	paddedBounds.maxs = paddedBounds.maxs + padFactor*targetExtents
	-- Determine grid resolution
	var paddedExtents = paddedBounds:extents()
	var numvox = (paddedExtents / voxelSize):ceil()
	var gridres = toVec3u(numvox)
	-- Determine where the target bounds are within the grid
	var minOffset = toVec3u((((targetBounds.mins - paddedBounds.mins) / paddedExtents) * numvox):floor())
	var maxOffset = toVec3u((((targetBounds.maxs - paddedBounds.mins) / paddedExtents) * numvox):ceil())
	var targetGridBounds : BBox3u
	targetGridBounds:init(minOffset, maxOffset)

	return paddedBounds, gridres, targetGridBounds
end


terra BinaryGrid3D:numFilledCells(bounds: &BBox3u) : uint
	var num = 0
	for k=bounds.mins(2),bounds.maxs(2) do
		for i=bounds.mins(1),bounds.maxs(1) do
			for j=bounds.mins(0),bounds.maxs(0) do
				num = num + uint(self:isVoxelSet(i,j,k))
			end
		end
	end
	return num
end
terra BinaryGrid3D:numFilledCells() : uint
	var bounds = BBox3u.salloc():init(Vec3u.create(0, 0, 0), Vec3u.create(self.cols, self.rows, self.slices))
	return self:numFilledCells(bounds)
end


terra BinaryGrid3D:numCellsEqual(other: &BinaryGrid3D, bounds: &BBox3u) : uint
	var num = 0
	for k=bounds.mins(2),bounds.maxs(2) do
		for i=bounds.mins(1),bounds.maxs(1) do
			for j=bounds.mins(0),bounds.maxs(0) do
				num = num + uint(self:isVoxelSet(i,j,k) == other:isVoxelSet(i,j,k))
			end
		end
	end
	return num
end
terra BinaryGrid3D:numCellsEqual(other: &BinaryGrid3D) : uint
	var bounds = BBox3u.salloc():init(Vec3u.create(0, 0, 0), Vec3u.create(self.cols, self.rows, self.slices))
	return self:numCellsEqual(other, bounds)
end

terra BinaryGrid3D:percentCellsEqual(other: &BinaryGrid3D, bounds: &BBox3u) : double
	var num = self:numCellsEqual(other, bounds)
	return double(num)/bounds:volume()
end
terra BinaryGrid3D:percentCellsEqual(other: &BinaryGrid3D) : double
	var bounds = BBox3u.salloc():init(Vec3u.create(0, 0, 0), Vec3u.create(self.cols, self.rows, self.slices))
	return self:percentCellsEqual(other, bounds)
end

terra BinaryGrid3D:numFilledCellsEqual(other: &BinaryGrid3D, bounds: &BBox3u) : uint
	var num = 0
	for k=bounds.mins(2),bounds.maxs(2) do
		for i=bounds.mins(1),bounds.maxs(1) do
			for j=bounds.mins(0),bounds.maxs(0) do
				num = num + uint(self:isVoxelSet(i,j,k) and other:isVoxelSet(i,j,k))
			end
		end
	end
	return num
end
terra BinaryGrid3D:numFilledCellsEqual(other: &BinaryGrid3D) : uint
	var bounds = BBox3u.salloc():init(Vec3u.create(0, 0, 0), Vec3u.create(self.cols, self.rows, self.slices))
	return self:numFilledCellsEqual(other, bounds)
end


-- Fast population count, from https://github.com/BartMassey/popcount
local terra popcount(x: uint)
	var m1 = 0x55555555U
	var m2 = 0xc30c30c3U
	x = x - ((x >> 1) and m1)
	x = (x and m2) + ((x >> 2) and m2) + ((x >> 4) and m2)
	x = x + (x >> 6)
	return (x + (x >> 12) + (x >> 24)) and 0x3f
end
popcount:setinlined(true)

terra BinaryGrid3D:numFilledCellsPadded()
	var n = 0
	for i=0,self:numuints() do
		n = n + popcount(self.data[i])
	end
	return n
end

terra BinaryGrid3D:numEmptyCellsPadded()
	return self:numCellsPadded() - self:numFilledCellsPadded()
end

-- NOTE: This will return a value *higher* than if we compute this quanity by looping over all cells,
--    because we may have extra padding in self.data (i.e. up to 31 extra cells). These cells will
--    always be zero, so this function returns a slight upper bound on the actual number of equal cells.
--    For sufficiently high-res grids, this shouldn't make a difference.
terra BinaryGrid3D:numCellsEqualPadded(other: &BinaryGrid3D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols and
			 self.slices == other.slices)
	var num = 0
	for i=0,self:numuints() do
		var x = not (self.data[i] ^ other.data[i])
		num = num + popcount(x)
	end
	return num
end
terra BinaryGrid3D:percentCellsEqualPadded(other: &BinaryGrid3D)
	var num = self:numCellsEqualPadded(other)
	return double(num)/self:numCellsPadded()
end


terra BinaryGrid3D:numEmptyCellsEqualPadded(other: &BinaryGrid3D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols and
			 self.slices == other.slices)
	var num = 0
	for i=0,self:numuints() do
		var x = not (self.data[i] or other.data[i])
		num = num + popcount(x)
	end
	return num
end
-- NOTE: This is one-sided (denominator computed on self)
terra BinaryGrid3D:percentEmptyCellsEqualPadded(other: &BinaryGrid3D)
	var num = self:numEmptyCellsEqualPadded(other)
	return double(num)/self:numEmptyCellsPadded()
end

terra BinaryGrid3D:numFilledCellsEqualPadded(other: &BinaryGrid3D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols and
			 self.slices == other.slices)
	var num = 0
	for i=0,self:numuints() do
		var x = (self.data[i] and other.data[i])
		num = num + popcount(x)
	end
	return num
end
-- NOTE: This is one-sided (denominator computed on self)
terra BinaryGrid3D:percentFilledCellsEqualPadded(other: &BinaryGrid3D)
	var num = self:numFilledCellsEqualPadded(other)
	return double(num)/self:numFilledCellsPadded()
end


return BinaryGrid3D




