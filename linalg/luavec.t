local S = require("qs.lib.std")
local LS = require("std")


return S.memoize(function(N)

	local Vec = LS.LObject()

	function Vec:init(...)
		local args = {...}
		for i,a in ipairs(args) do
			self[i] = a
		end
		return self
	end

	function Vec:copy(other)
		for i,a in ipairs(other) do
			self[i] = a
		end
		return self
	end

	function Vec.new(...)
		return Vec.alloc():init(...)
	end

	function Vec:__unm()
		local v = self:newcopy()
		for i=1,N do v[i] = -v[i] end
		return v
	end

	function Vec.__add(v1, v2)
		local v = v1:newcopy()
		for i=1,N do v[i] = v[i] + v2[i] end
		return v
	end

	function Vec.__sub(v1, v2)
		local v = v1:newcopy()
		for i=1,N do v[i] = v[i] - v2[i] end
		return v
	end

	function Vec.vecVecMul(v1, v2)
		local v = v1:newcopy()
		for i=1,N do v[i] = v[i] * v2[i] end
		return v
	end
	function Vec.scalarVecMul(s, v1)
		local v = v1:newcopy()
		for i=1,N do v[i] = s * v[i] end
		return v
	end
	function Vec.vecScalarMul(v1, s)
		local v = v1:newcopy()
		for i=1,N do v[i] = s * v[i] end
		return v
	end
	function Vec.__mul(a, b)
		if type(a) == "number" then
			return Vec.scalarVecMul(a, b)
		elseif type(b) == "number" then
			return Vec.vecScalarMul(a, b)
		else
			return Vec.vecVecMul(a, b)
		end
	end

	function Vec.vecScalarDiv(v1, s)
		local v = v1:newcopy()
		for i=1,N do v[i] = v[i] / s end
		return v
	end
	function Vec.vecVecDiv(v1, v2)
		local v = v1:newcopy()
		for i=1,N do v[i] = v[i] / v2[i] end
		return v
	end
	function Vec.__div(a, b)
		if type(b) == "number" then
			return Vec.vecScalarDiv(a, b)
		else
			return Vec.vecVecDiv(a, b)
		end
	end

	function Vec.__eq(v1, v2)
		for i=1,N do
			if not (v1[i] == v2[i]) then
				return false
			end
		end
		return true
	end

	function Vec.__lt(v1, v2)
		for i=1,N do
			if not (v1[i] < v2[i]) then
				return false
			end
		end
		return true
	end

	function Vec.__le(v1, v2)
		for i=1,N do
			if not (v1[i] <= v2[i]) then
				return false
			end
		end
		return true
	end

	function Vec:dot(v)
		local sum = 0
		for i=1,N do
			sum = sum + self[i]*v[i]
		end
		return sum
	end

	function Vec:normSquared()
		return self:dot(self)
	end

	function Vec:norm()
		return math.sqrt(self:normSquared())
	end

	function Vec:normalize()
		local n = self:norm()
		for i=1,N do self[i] = self[i] / n end
	end

	function Vec:normalized()
		local cp = Vec.alloc():copy(self)
		cp:normalize()
		return cp
	end

	if N == 3 then
		function Vec:cross(v)
			return Vec.alloc():init(
				self[2]*v[3] - self[3]*v[2],
				self[3]*v[1] - self[1]*v[3],
				self[1]*v[2] - self[2]*v[1]
			)
		end
	end

	function Vec:projectToPlane(p, n)
		n = n:normalized()
		local v = self - p
		return p + (v - v:dot(n)*n)
	end

	function Vec:projectToRay(p, d)
		d = d:normalized()
		return p + (self - p):dot(d)*d
	end

	function Vec:projectToLineSeg(p0, p1)
		return self:projectToRay(p0, p1-p0)
	end

	-- What t value would interpolate the two provided points
	--    to produce this point?
	-- (Assumes the three points are collinear)
	function Vec:inverseLerp(p0, p1)
		local d = p1 - p0
		local dnorm = d:norm()
		-- dot / dnorm gives us absolute length of self-p0;
		--    divide by dnorm again to get length as percentage of dnorm
		return (self - p0):dot(d) / (dnorm*dnorm)
	end

	return Vec
end)




