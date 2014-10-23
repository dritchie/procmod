local S = terralib.require("qs.lib.std")
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
terra BinaryGrid3D:fillInterior()
	var visited = BinaryGrid3D.salloc():copy(self)
	var frontier = BinaryGrid3D.salloc():init(self.rows, self.cols, self.slices)
	-- Start expanding from every cell we haven't yet visited (already filled
	--    cells count as visited)
	for k=0,self.slices do
		for i=0,self.rows do
			for j=0,self.cols do
				if not visited:isVoxelSet(i,j,k) then
					var isoutside = false
					var fringe = [S.Vector(Voxel)].salloc():init()
					fringe:insert(Voxel{i,j,k})
					while fringe:size() ~= 0 do
						var v = fringe:remove()
						frontier:setVoxel(v.i, v.j, v.k)
						-- If we expanded to the edge of the grid, then this region is outside
						if v.i == 0 or v.i == self.rows-1 or
						   v.j == 0 or v.j == self.cols-1 or
						   v.k == 0 or v.k == self.slices-1 then
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
terra BinaryGrid3D:numCellsEqual(other: &BinaryGrid3D)
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
terra BinaryGrid3D:percentCellsEqual(other: &BinaryGrid3D)
	var num = self:numCellsEqual(other)
	return double(num)/self:numCellsPadded()
end


terra BinaryGrid3D:numEmptyCellsEqual(other: &BinaryGrid3D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols and
			 self.slices == other.slices)
	var num = 0
	for i=0,self:numuints() do
		var x = not (self.data[i] and other.data[i])
		num = num + popcount(x)
	end
	return num
end
-- NOTE: This is one-sided (denominator computed on self)
terra BinaryGrid3D:percentEmptyCellsEqual(other: &BinaryGrid3D)
	var num = self:numEmptyCellsEqual(other)
	return double(num)/self:numEmptyCellsPadded()
end

terra BinaryGrid3D:numFilledCellsEqual(other: &BinaryGrid3D)
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
terra BinaryGrid3D:percentFilledCellsEqual(other: &BinaryGrid3D)
	var num = self:numFilledCellsEqual(other)
	return double(num)/self:numFilledCellsPadded()
end


return BinaryGrid3D




