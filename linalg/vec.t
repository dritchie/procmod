local S = terralib.require("qs.lib.std")
local mathlib = terralib.require("utils.mathlib")


-- Code gen helpers
local function replicate(val, n)
	local t = {}
	for i=1,n do table.insert(t, val) end
	return t
end
local function wrap(exprs, unaryFn)
	local t = {}
	for _,e in ipairs(exprs) do table.insert(t, `[unaryFn(e)]) end
	return t
end
local function zip(expList1, expList2, binaryFn)
	assert(#expList1 == #expList2)
	local t = {}
	for i=1,#expList1 do
		local e1 = expList1[i]
		local e2 = expList2[i]
		table.insert(t, binaryFn(e1, e2))
	end
	return t
end
local function reduce(exprs, accumFn)
	local curr = exprs[1]
	for i=2,#exprs do
		local e = exprs[i]
		curr = `[accumFn(e, curr)]
	end
	return curr
end


-- Simple vector type with constant, compile-time size
-- 'real' type must be primitive or POD (i.e. it is not safe to use a type with a non-trivial destructor)
-- Methods are defined to operate on Vecs by-value, not by-pointer (since metamethods must be defined this way).
local Vec
Vec = S.memoize(function(real, dim, GPU)

	local mlib = mathlib(GPU)

	local struct VecT(S.Object)
	{
		entries: real[dim]
	}
	VecT.metamethods.__typename = function(self)
		if GPU then
			return string.format("Vec(%s, %d, GPU)", tostring(real), dim)
		else
			return string.format("Vec(%s, %d)", tostring(real), dim)
		end
	end
	VecT.RealType = real
	VecT.Dimension = dim

	local function entryList(self)
		local t = {}
		for i=1,dim do table.insert(t, `[self].entries[ [i-1] ]) end
		return t
	end
	local function symbolList()
		local t = {}
		for i=1,dim do table.insert(t, symbol(real)) end
		return t
	end

	-- Constructors
	terra VecT:__init()
		[entryList(self)] = [replicate(`0.0, dim)]
	end
	local ctorags = symbolList()
	terra VecT:__init([ctorags])
		[entryList(self)] = [ctorags]
	end
	if dim > 1 then
		terra VecT:__init(val: real)
			[entryList(self)] = [replicate(val, dim)]
		end
	end
	terra VecT:__copy(other: &VecT)
		[entryList(self)] = [entryList(other)]
	end
	-- Create a vector with less syntax
	VecT.methods.create = macro(function(...)
		local args = {...}
		return `@VecT.salloc():init([args])
	end)

	-- Apply metamethod does element access (as a macro, so you can both
	--    read and write elements this way)
	VecT.metamethods.__apply = macro(function(self, index)
		return `self.entries[index]
	end)

	-- Arithmetic operators
	VecT.metamethods.__add = terra(v1: VecT, v2: VecT)
		var v : VecT
		[entryList(v)] = [zip(entryList(v1), entryList(v2),
			function(a, b) return `a+b end)]
		return v
	end
	VecT.metamethods.__add:setinlined(true)
	VecT.metamethods.__sub = terra(v1: VecT, v2: VecT)
		var v : VecT
		[entryList(v)] = [zip(entryList(v1), entryList(v2),
			function(a, b) return `a-b end)]
		return v
	end
	VecT.metamethods.__sub:setinlined(true)
	VecT.metamethods.__mul = terra(v1: VecT, s: real)
		var v : VecT
		[entryList(v)] = [zip(entryList(v1), replicate(s, dim),
			function(a, b) return `a*b end)]
		return v
	end
	VecT.metamethods.__mul:adddefinition((terra(s: real, v1: VecT)
		var v : VecT
		[entryList(v)] = [zip(entryList(v1), replicate(s, dim),
			function(a, b) return `a*b end)]
		return v
	end):getdefinitions()[1])
	VecT.metamethods.__mul:adddefinition((terra(v1: VecT, v2: VecT)
		var v : VecT
		[entryList(v)] = [zip(entryList(v1), entryList(v2),
			function(a, b) return `a*b end)]
		return v
	end):getdefinitions()[1])
	VecT.metamethods.__mul:setinlined(true)
	VecT.metamethods.__div = terra(v1: VecT, s: real)
		var v : VecT
		[entryList(v)] = [zip(entryList(v1), replicate(s, dim),
			function(a, b) return `a/b end)]
		return v
	end
	VecT.metamethods.__div:adddefinition((terra(v1: VecT, v2: VecT)
		var v: VecT
		[entryList(v)] = [zip(entryList(v1), entryList(v2),
			function(a, b) return `a/b end)]
		return v
	end):getdefinitions()[1])
	VecT.metamethods.__div:setinlined(true)
	VecT.metamethods.__unm = terra(v1: VecT)
		var v : VecT
		[entryList(v)] = [wrap(entryList(v1), function(e) return `-e end)]
		return v
	end
	VecT.metamethods.__unm:setinlined(true)

	-- Comparison operators
	VecT.metamethods.__eq = terra(v1: VecT, v2: VecT)
		return [reduce(zip(entryList(v1), entryList(v2),
						   function(a,b) return `a == b end),
					   function(a,b) return `a and b end)]
	end
	VecT.metamethods.__eq:adddefinition((terra(v1: VecT, s: real)
		return [reduce(zip(entryList(v1), replicate(s, dim),
						   function(a,b) return `a == b end),
					   function(a,b) return `a and b end)]
	end):getdefinitions()[1])
	VecT.metamethods.__gt = terra(v1: VecT, v2: VecT)
		return [reduce(zip(entryList(v1), entryList(v2),
						   function(a,b) return `a > b end),
					   function(a,b) return `a and b end)]
	end
	VecT.metamethods.__gt:adddefinition((terra(v1: VecT, s: real)
		return [reduce(zip(entryList(v1), replicate(s, dim),
						   function(a,b) return `a > b end),
					   function(a,b) return `a and b end)]
	end):getdefinitions()[1])
	VecT.metamethods.__ge = terra(v1: VecT, v2: VecT)
		return [reduce(zip(entryList(v1), entryList(v2),
						   function(a,b) return `a >= b end),
					   function(a,b) return `a and b end)]
	end
	VecT.metamethods.__ge:adddefinition((terra(v1: VecT, s: real)
		return [reduce(zip(entryList(v1), replicate(s, dim),
						   function(a,b) return `a >= b end),
					   function(a,b) return `a and b end)]
	end):getdefinitions()[1])
	VecT.metamethods.__lt = terra(v1: VecT, v2: VecT)
		return [reduce(zip(entryList(v1), entryList(v2),
						   function(a,b) return `a < b end),
					   function(a,b) return `a and b end)]
	end
	VecT.metamethods.__lt:adddefinition((terra(v1: VecT, s: real)
		return [reduce(zip(entryList(v1), replicate(s, dim),
						   function(a,b) return `a < b end),
					   function(a,b) return `a and b end)]
	end):getdefinitions()[1])
	VecT.metamethods.__le = terra(v1: VecT, v2: VecT)
		return [reduce(zip(entryList(v1), entryList(v2),
						   function(a,b) return `a <= b end),
					   function(a,b) return `a and b end)]
	end
	VecT.metamethods.__le:adddefinition((terra(v1: VecT, s: real)
		return [reduce(zip(entryList(v1), replicate(s, dim),
						   function(a,b) return `a <= b end),
					   function(a,b) return `a and b end)]
	end):getdefinitions()[1])

	-- Other mathematical operations
	terra VecT:dot(v: VecT)
		return [reduce(zip(entryList(self), entryList(v), function(a,b) return `a*b end),
					   function(a,b) return `a+b end)]
	end
	VecT.methods.dot:setinlined(true)
	terra VecT:angleBetween(v: VecT)
		var selfnorm = self:norm()
		if selfnorm == 0.0 then return real(0.0) end
		var vnorm = v:norm()
		if vnorm == 0.0 then return real(0.0) end
		var nd = self:dot(v) / selfnorm / vnorm
		-- Floating point error may lead to values outside of the bounds we expect
		if nd <= -1.0 then
			return real([math.pi])
		elseif nd >= 1.0 then
			return real(0.0)
		else
			return mlib.acos(nd)
		end
	end
	VecT.methods.angleBetween:setinlined(true)
	terra VecT:distSq(v: VecT)
		return [reduce(wrap(zip(entryList(self), entryList(v),
								function(a,b) return `a-b end),
							function(a) return quote var aa = a in aa*aa end end),
					   function(a,b) return `a+b end)]
	end
	VecT.methods.distSq:setinlined(true)
	terra VecT:dist(v: VecT)
		return mlib.sqrt(self:distSq(v))
	end
	VecT.methods.dist:setinlined(true)
	terra VecT:normSq()
		return [reduce(wrap(entryList(self),
							function(a) return `a*a end),
					   function(a,b) return `a+b end)]
	end
	VecT.methods.normSq:setinlined(true)
	terra VecT:norm()
		return mlib.sqrt(self:normSq())
	end
	VecT.methods.norm:setinlined(true)
	terra VecT:normalize()
		var n = self:norm()
		if n > 0.0 then
			[entryList(self)] = [wrap(entryList(self), function(a) return `a/n end)]
		end
	end
	VecT.methods.normalize:setinlined(true)

	local collinearThresh = 1e-8
	terra VecT:collinear(other: VecT)
		var n1 = self:norm()
		var n2 = other:norm()
		return 1.0 - mlib.fabs(self:dot(other)/(n1*n2)) < collinearThresh
	end
	VecT.methods.collinear:setinlined(true)

	local planeThresh = 1e-8
	terra VecT:inPlane(p: VecT, n: VecT) : bool
		n:normalize()
		return mlib.fabs((@self - p):dot(n)) < planeThresh
	end
	VecT.methods.inPlane:setinlined(true)

	terra VecT:projectToRay(p: VecT, d: VecT) : VecT
		d:normalize()
		return p + (@self - p):dot(d)*d
	end
	VecT.methods.projectToRay:setinlined(true)
	terra VecT:projectToLineSeg(p0: VecT, p1: VecT) : VecT
		return self:projectToRay(p0, p1-p0)
	end
	VecT.methods.projectToLineSeg:setinlined(true)

	-- What t value would interpolate the two provided points
	--    to produce this point?
	-- (Assumes the three points are collinear)
	terra VecT:inverseLerp(p0: VecT, p1: VecT)
		var d = p1 - p0
		var dnorm = d:norm()
		-- dot / dnorm gives us absolute length of self-p0;
		--    divide by dnorm again to get length as percentage of dnorm
		return (@self - p0):dot(d) / (dnorm*dnorm)
	end
	VecT.methods.inverseLerp:setinlined(true)

	terra VecT:projectToPlane(p: VecT, n: VecT) : VecT
		n:normalize()
		var vec = @self - p
		return p + (vec - vec:dot(n)*n)
	end
	VecT.methods.projectToPlane:setinlined(true)

	-- Specific stuff for 2D Vectors
	if dim == 2 then
		VecT.methods.fromPolar = terra(r: real, theta: real)
			var v : VecT
			v:init(r*mlib.cos(theta), r*mlib.sin(theta))
			return v
		end

		terra VecT:toPolar()
			var r = self:norm()
			var theta = mlib.atan2(self(1), self(0))
			return r, theta
		end
	end

	-- Specific stuff for 3D Vectors
	if dim == 3 then
		VecT.methods.fromSpherical = terra(r: real, theta: real, phi: real)
			var rsin = r * mlib.sin(theta)
			var v : VecT
			v:init(rsin*mlib.cos(phi), rsin*mlib.sin(phi), r*mlib.cos(theta))
			return v
		end

		terra VecT:toSpherical()
			var r = self:norm()
			var theta = mlib.acos(self(2)/r)
			var phi = mlib.atan2(self(1), self(0))
			return r, theta, phi
		end

		terra VecT:cross(other: VecT)
			var v : VecT
			v:init(
				self(1)*other(2) - self(2)*other(1),
				self(2)*other(0) - self(0)*other(2),
				self(0)*other(1) - self(1)*other(0)
			)
			return v
		end
		VecT.methods.cross:setinlined(true)

		terra VecT:inPlane(p1: VecT, p2: VecT, p3: VecT) : bool
			var v1 = p2 - p1
			var v2 = p3 - p1
			var n = v1:cross(v2)
			return self:inPlane(p1, n)
		end
		VecT.methods.inPlane:setinlined(true)

		terra VecT:projectToPlane(p1: VecT, p2: VecT, p3: VecT) : VecT
			var v1 = p2 - p1
			var v2 = p3 - p1
			var n = v1:cross(v2)
			return self:projectToPlane(p1, n)
		end
		VecT.methods.projectToPlane:setinlined(true)
	end

	terra VecT:distSqToLineSeg(a: VecT, b: VecT) : real
		var sqlen = a:distSq(b)
		-- Degenerate zero length segment
		if sqlen == 0.0 then return self:distSq(a) end
		var t = (@self - a):dot(b - a) / sqlen
		-- Beyond the bounds of the segment
		if t < 0.0 then return self:distSq(a) end
		if t > 1.0 then return self:distSq(b) end
		-- Normal case (projection onto segment)
		var proj = a + t*(b - a)
		return self:distSq(proj)
	end

	-- Min/max/abs
	terra VecT:maxInPlace(other: VecT)
		[entryList(self)] = [zip(entryList(self), entryList(other),
			function(a,b) return `mlib.fmax(a, b) end)]
	end
	VecT.methods.maxInPlace:setinlined(true)
	terra VecT:max(other: VecT)
		var v : VecT
		S.copy(v, @self)
		v:maxInPlace(other)
		return v
	end
	VecT.methods.max:setinlined(true)
	terra VecT:minInPlace(other: VecT)
		[entryList(self)] = [zip(entryList(self), entryList(other),
			function(a,b) return `mlib.fmin(a, b) end)]
	end
	VecT.methods.minInPlace:setinlined(true)
	terra VecT:min(other: VecT)
		var v : VecT
		S.copy(v, @self)
		v:minInPlace(other)
		return v
	end
	VecT.methods.min:setinlined(true)
	terra VecT:absInPlace()
		[entryList(self)] = [wrap(entryList(self), function(a) return `mlib.fabs(a) end)]
	end
	VecT.methods.absInPlace:setinlined(true)
	terra VecT:abs()
		var v : VecT
		S.copy(v, @self)
		v:absInPlace()
		return v
	end
	VecT.methods.abs:setinlined(true)

	-- Check for nans
	terra VecT:isnan()
		return not [reduce(wrap(entryList(self),
			function(x) return `x == x end),
			function(a,b) return `a and b end)]
	end
	VecT.methods.isnan:setinlined(true)

	return VecT

end)



return function(real, dim, GPU)
	if GPU == nil then GPU = false end
	return Vec(real, dim, GPU)
end




