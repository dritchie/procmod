local S = terralib.require("qs.lib.std")
local Vec = terralib.require("linalg.vec")
local BBox = terralib.require("geometry.bbox")
local C = terralib.includecstring [[
#include <string.h>
]]


local BITS_PER_UINT = terralib.sizeof(uint) * 8

local struct BinaryGrid2D(S.Object)
{
	data: &uint,
	rows: uint,
	cols: uint
}

terra BinaryGrid2D:__init() : {}
	self.rows = 0
	self.cols = 0
	self.data = nil
end

terra BinaryGrid2D:__init(rows: uint, cols: uint) : {}
	self:__init()
	self:resize(rows, col)
end

terra BinaryGrid2D:__copy(other: &BinaryGrid2D)
	self:__init(other.rows, other.cols)
	C.memcpy(self.data, other.data, self:numuints()*sizeof(uint))
end

terra BinaryGrid2D:__destruct()
	if self.data ~= nil then
		S.free(self.data)
	end
end

terra BinaryGrid2D:resize(rows: uint, cols: uint)
	if self.rows ~= rows or self.cols ~= cols then
		self.rows = rows
		self.cols = cols
		if self.data ~= nil then
			self.data = [&uint](S.realloc(self.data, self:numuints()*sizeof(uint)))
		else
			self.data = [&uint](S.malloc(self:numuints()*sizeof(uint)))
		end
		self:clear()
	end
end

terra BinaryGrid2D:clear()
	for i=0,self:numuints() do
		self.data[i] = 0
	end
end

terra BinaryGrid2D:numcells()
	return self.rows*self.cols
end
BinaryGrid2D.methods.numcells:setinlined(true)

terra BinaryGrid2D:numuints()
	return (self:numcells() + BITS_PER_UINT - 1) / BITS_PER_UINT
end
BinaryGrid2D.methods.numuints:setinlined(true)

terra BinaryGrid2D:numCellsPadded()
	return self:numuints() * BITS_PER_UINT
end
BinaryGrid2D.methods.numCellsPadded:setinlined(true)

terra BinaryGrid2D:isPixelSet(row: uint, col: uint)
	var linidx = row*self.cols + col
	var baseIdx = linidx / BITS_PER_UINT
	var localidx = linidx % BITS_PER_UINT
	return (self.data[baseIdx] and (1 << localidx)) ~= 0
end

terra BinaryGrid2D:setPixel(row: uint, col: uint)
	var linidx = row*self.cols + col
	var baseIdx = linidx / BITS_PER_UINT
	var localidx = linidx % BITS_PER_UINT
	self.data[baseIdx] = self.data[baseIdx] or (1 << localidx)
end

terra BinaryGrid2D:togglePixel(row: uint, col: uint)
	var linidx = row*self.cols + col
	var baseIdx = linidx / BITS_PER_UINT
	var localidx = linidx % BITS_PER_UINT
	self.data[baseIdx] = self.data[baseIdx] ^ (1 << localidx)
end

terra BinaryGrid2D:clearPixel(row: uint, col: uint)
	var linidx = row*self.cols + col
	var baseIdx = linidx / BITS_PER_UINT
	var localidx = linidx % BITS_PER_UINT
	self.data[baseIdx] = self.data[baseIdx] and not (1 << localidx)
end

terra BinaryGrid2D:unionWith(other: &BinaryGrid2D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols)
	for i=0,self:numuints() do
		self.data[i] = self.data[i] or other.data[i]
	end
end

local struct Pixel { i: uint, j: uint }
local Vec2u = Vec(uint, 3)
local BBox2u = BBox(Vec2u)
terra BinaryGrid2D:fillInterior(bounds: &BBox2u) : {}
	var visited = BinaryGrid2D.salloc():copy(self)
	var frontier = BinaryGrid2D.salloc():init(self.rows, self.cols)
	-- Start expanding from every cell we haven't yet visited (already filled
	--    cells count as visited)
	for i=bounds.mins(1),bounds.maxs(1) do
		for j=bounds.mins(0),bounds.maxs(0) do
			if not visited:isPixelSet(i,j) then
				var isoutside = false
				var fringe = [S.Vector(Pixel)].salloc():init()
				fringe:insert(Pixel{i,j})
				while fringe:size() ~= 0 do
					var v = fringe:remove()
					frontier:setPixel(v.i, v.j)
					-- If we expanded to the edge of the bounds, then this region is outside
					if v.i == bounds.mins(1) or v.i == bounds.maxs(1)-1 or
					   v.j == bounds.mins(0) or v.j == bounds.maxs(0)-1 then
						isoutside = true
					-- Otherwise, expand to the neighbors
					else
						visited:setPixel(v.i, v.j)
						if not visited:isPixelSet(v.i-1, v.j) then
							fringe:insert(Pixel{v.i-1, v.j})
						end
						if not visited:isPixelSet(v.i+1, v.j) then
							fringe:insert(Pixel{v.i+1, v.j})
						end
						if not visited:isPixelSet(v.i, v.j-1) then
							fringe:insert(Pixel{v.i, v.j-1})
						end
						if not visited:isPixelSet(v.i, v.j+1) then
							fringe:insert(Pixel{v.i, v.j+1})
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

terra BinaryGrid2D:fillInterior() : {}
	var bounds = BBox2u.salloc():init(
		Vec2u.create(0),
		Vec2u.create(self.cols, self.rows)
	)
	self:fillInterior(bounds)
end


terra BinaryGrid2D:numFilledCells(bounds: &BBox2u) : uint
	var num = 0
	for i=bounds.mins(1),bounds.maxs(1) do
		for j=bounds.mins(0),bounds.maxs(0) do
			num = num + uint(self:isPixelSet(i,j))
		end
	end
	return num
end
terra BinaryGrid2D:numFilledCells() : uint
	var bounds = BBox2u.salloc():init(Vec2u.create(0, 0), Vec2u.create(self.cols, self.rows))
	return self:numFilledCells(bounds)
end


terra BinaryGrid2D:numCellsEqual(other: &BinaryGrid2D, bounds: &BBox2u) : uint
	var num = 0
	for i=bounds.mins(1),bounds.maxs(1) do
		for j=bounds.mins(0),bounds.maxs(0) do
			num = num + uint(self:isPixelSet(i,j) == other:isPixelSet(i,j))
		end
	end
	return num
end
terra BinaryGrid2D:numCellsEqual(other: &BinaryGrid2D) : uint
	var bounds = BBox2u.salloc():init(Vec2u.create(0, 0), Vec2u.create(self.cols, self.rows))
	return self:numCellsEqual(other, bounds)
end

terra BinaryGrid2D:percentCellsEqual(other: &BinaryGrid2D, bounds: &BBox2u) : double
	var num = self:numCellsEqual(other, bounds)
	return double(num)/bounds:volume()
end
terra BinaryGrid2D:percentCellsEqual(other: &BinaryGrid2D) : double
	var bounds = BBox2u.salloc():init(Vec2u.create(0, 0), Vec2u.create(self.cols, self.rows))
	return self:percentCellsEqual(other, bounds)
end

terra BinaryGrid2D:numFilledCellsEqual(other: &BinaryGrid2D, bounds: &BBox2u) : uint
	var num = 0
	for i=bounds.mins(1),bounds.maxs(1) do
		for j=bounds.mins(0),bounds.maxs(0) do
			num = num + uint(self:isPixelSet(i,j) and other:isPixelSet(i,j))
		end
	end
	return num
end
terra BinaryGrid2D:numFilledCellsEqual(other: &BinaryGrid2D) : uint
	var bounds = BBox2u.salloc():init(Vec2u.create(0, 0), Vec2u.create(self.cols, self.rows))
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

terra BinaryGrid2D:numFilledCellsPadded()
	var n = 0
	for i=0,self:numuints() do
		n = n + popcount(self.data[i])
	end
	return n
end

terra BinaryGrid2D:numEmptyCellsPadded()
	return self:numCellsPadded() - self:numFilledCellsPadded()
end

-- NOTE: This will return a value *higher* than if we compute this quanity by looping over all cells,
--    because we may have extra padding in self.data (i.e. up to 31 extra cells). These cells will
--    always be zero, so this function returns a slight upper bound on the actual number of equal cells.
--    For sufficiently high-res grids, this shouldn't make a difference.
terra BinaryGrid2D:numCellsEqualPadded(other: &BinaryGrid2D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols)
	var num = 0
	for i=0,self:numuints() do
		var x = not (self.data[i] ^ other.data[i])
		num = num + popcount(x)
	end
	return num
end
terra BinaryGrid2D:percentCellsEqualPadded(other: &BinaryGrid2D)
	var num = self:numCellsEqualPadded(other)
	return double(num)/self:numCellsPadded()
end


terra BinaryGrid2D:numEmptyCellsEqualPadded(other: &BinaryGrid2D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols)
	var num = 0
	for i=0,self:numuints() do
		var x = not (self.data[i] or other.data[i])
		num = num + popcount(x)
	end
	return num
end
-- NOTE: This is one-sided (denominator computed on self)
terra BinaryGrid2D:percentEmptyCellsEqualPadded(other: &BinaryGrid2D)
	var num = self:numEmptyCellsEqualPadded(other)
	return double(num)/self:numEmptyCellsPadded()
end

terra BinaryGrid2D:numFilledCellsEqualPadded(other: &BinaryGrid2D)
	S.assert(self.rows == other.rows and
			 self.cols == other.cols)
	var num = 0
	for i=0,self:numuints() do
		var x = (self.data[i] and other.data[i])
		num = num + popcount(x)
	end
	return num
end
-- NOTE: This is one-sided (denominator computed on self)
terra BinaryGrid2D:percentFilledCellsEqualPadded(other: &BinaryGrid2D)
	var num = self:numFilledCellsEqualPadded(other)
	return double(num)/self:numFilledCellsPadded()
end


return BinaryGrid2D




