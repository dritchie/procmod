local S = require("qs.lib.std")
local Intersections = require("geometry.intersection")
local Mat = require("linalg.mat")

local BBox = S.memoize(function(Vec)

	local real = Vec.RealType
	local Intersection = Intersections(real)

	local struct BBox(S.Object)
	{
		mins: Vec,
		maxs: Vec
	}

	BBox.methods.__init = terralib.overloadedfunction('BBox.__init', {
		terra(self: &BBox, mins: Vec, maxs: Vec) : {}
			self.mins = mins
			self.maxs = maxs
		end
	})
	BBox.methods.__init:adddefinition(
		terra(self: &BBox) : {}
			self:__init(Vec.create([math.huge]), Vec.create([-math.huge]))
		end
	)

	BBox.methods.expand = terralib.overloadedfunction('BBox.expand', {
		terra(self: &BBox, point: Vec)
			self.mins:minInPlace(point)
			self.maxs:maxInPlace(point)
		end,
		terra(self: &BBox, amount: real)
			escape
				for i=0,Vec.Dimension-1 do
					emit quote
						self.mins(i) = self.mins(i) - amount
						self.maxs(i) = self.maxs(i) + amount
					end
				end
			end
		end
	})

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
		var extents = self:extents()
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
		var absextends = self:extents()
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

	BBox.methods.intersects = terralib.overloadedfunction('BBox.intersects', {
		terra(self: &BBox, bbox: &BBox)
			return self.mins <= bbox.maxs and bbox.mins <= self.maxs
		end
	})

	if Vec.Dimension == 3 then
		BBox.methods.intersects:adddefinition(
			terra(self: &BBox, p0: Vec, p1: Vec, p2: Vec)
				return Intersection.intersectTriangleBBox(self.mins, self.maxs, p0, p1, p2)
			end
		)

		local Mat4 = Mat(real, 4, 4)
		terra BBox:transform(xform: &Mat4)
			var bbox = BBox.salloc():init()
			bbox:expand(xform:transformPoint(Vec.create(self.mins(0), self.mins(1), self.mins(2))))
			bbox:expand(xform:transformPoint(Vec.create(self.mins(0), self.mins(1), self.maxs(2))))
			bbox:expand(xform:transformPoint(Vec.create(self.mins(0), self.maxs(1), self.mins(2))))
			bbox:expand(xform:transformPoint(Vec.create(self.mins(0), self.maxs(1), self.maxs(2))))
			bbox:expand(xform:transformPoint(Vec.create(self.maxs(0), self.mins(1), self.mins(2))))
			bbox:expand(xform:transformPoint(Vec.create(self.maxs(0), self.mins(1), self.maxs(2))))
			bbox:expand(xform:transformPoint(Vec.create(self.maxs(0), self.maxs(1), self.mins(2))))
			bbox:expand(xform:transformPoint(Vec.create(self.maxs(0), self.maxs(1), self.maxs(2))))
			return @bbox
		end
	end

	return BBox

end)


return BBox



