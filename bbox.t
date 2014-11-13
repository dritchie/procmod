local S = terralib.require("qs.lib.std")
local Intersections = terralib.require("intersection")

local BBox = S.memoize(function(Vec)

	local real = Vec.RealType
	local Intersection = Intersections(real)

	local struct BBox(S.Object)
	{
		mins: Vec,
		maxs: Vec
	}

	terra BBox:__init(mins: Vec, maxs: Vec) : {}
		self.mins = mins
		self.maxs = maxs
	end

	terra BBox:__init() : {}
		self:__init(Vec.create([math.huge]), Vec.create([-math.huge]))
	end

	terra BBox:expand(point: Vec)
		self.mins:minInPlace(point)
		self.maxs:maxInPlace(point)
	end

	terra BBox:expand(amount: real)
		escape
			for i=0,Vec.Dimension-1 do
				emit quote
					self.mins(i) = self.mins(i) - amount
					self.maxs(i) = self.maxs(i) + amount
				end
			end
		end
	end

	terra BBox:contains(point: Vec)
		return point >= self.mins and point <= self.maxs
	end

	terra BBox:unionWith(other: &BBox)
		self.mins:minInPlace(other.mins)
		self.maxs:maxInPlace(other.maxs)
	end

	terra BBox:intersectWith(other: &BBox)
		self.mins:maxInPlace(other.mins)
		self.maxs:minInPlace(other.maxs)
	end

	terra BBox:extents()
		return self.maxs - self.mins
	end

	terra BBox:center()
		return 0.5 * (self.mins + self.maxs)
	end

	terra BBox:volume()
		var extents = self:extents():abs()
		var vol = 1.0
		escape
			for i=0,Vec.Dimension-1 do
				emit quote
					vol = vol * extents(i)
				end
			end
		end
		return vol
	end

	terra BBox:cubify()
		-- Expand all dims to be the same size as the largest one
		var maxlen = 0.0
		var absextends = self:extents():abs()
		var center = self:center()
		escape
			for i=0,Vec.Dimension-1 do
				emit quote
					if absextends(i) > maxlen then
						maxlen = absextends(i)
					end
				end
			end
			for i=0,Vec.Dimension-1 do
				emit quote
					self.mins(i) = center(i) - 0.5*maxlen
					self.maxs(i) = center(i) + 0.5*maxlen
				end
			end
		end
	end

	terra BBox:intersects(bbox: &BBox)
		return self.mins <= bbox.maxs and bbox.mins <= self.maxs
	end

	terra BBox:intersects(p0: Vec, p1: Vec, p2: Vec)
		return Intersection.intersectTriangleBBox(self.mins, self.maxs, p0, p1, p2)
	end

	return BBox

end)


return BBox



