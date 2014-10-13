local S = terralib.require("qs.lib.std")

local BBox = S.memoize(function(VecT)

	local real = VecT.RealType

	local struct BBoxT(S.Object)
	{
		mins: VecT,
		maxs: VecT
	}

	terra BBoxT:__init(mins: VecT, maxs: VecT) : {}
		self.mins = mins
		self.maxs = maxs
	end

	terra BBoxT:__init() : {}
		self:__init(VecT.create([math.huge]), VecT.create([-math.huge]))
	end

	terra BBoxT:expand(point: VecT)
		self.mins:minInPlace(point)
		self.maxs:maxInPlace(point)
	end

	terra BBoxT:expand(amount: real)
		escape
			for i=0,VecT.Dimension-1 do
				emit quote
					self.mins(i) = self.mins(i) - amount
					self.maxs(i) = self.maxs(i) - amount
				end
			end
		end
	end

	terra BBoxT:contains(point: VecT)
		return point > self.mins and point < self.maxs
	end

	terra BBoxT:unionWith(other: &BBoxT)
		self.mins:minInPlace(other.mins)
		self.maxs:maxInPlace(other.maxs)
	end

	terra BBoxT:intersectWith(other: &BBoxT)
		self.mins:maxInPlace(other.mins)
		self.maxs:minInPlace(other.maxs)
	end

	terra BBoxT:extents()
		return self.maxs - self.mins
	end

	return BBoxT

end)


return BBox