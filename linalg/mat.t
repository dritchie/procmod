local S = require("qs.lib.std")
local mlib = require("qs.lib.tmath")
local Vec = require("linalg.vec")
local util = require('util')


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


-- Simple matrix type with constant, compile-time size
-- 'real' type must be primitive or POD (i.e. it is not safe to use a type with a non-trivial destructor)
-- Methods are defined to operate on Mats by-value, not by-pointer (since metamethods must be defined this way).
local Mat
Mat = S.memoize(function(real, rowdim, coldim, GPU)

	local numelems = rowdim*coldim
	local struct MatT(S.Object)
	{
		entries: real[numelems]
	}
	MatT.RealType = real
	MatT.RowDimension = rowdim
	MatT.ColDimension = coldim

	MatT.metamethods.__typename = function(self)
		if GPU then
			return string.format("Mat(%s, %d, %d, GPU)", tostring(real), rowdim, coldim)
		else
			return string.format("Mat(%s, %d, %d)", tostring(real), rowdim, coldim)
		end
	end

	local function entryList(self)
		local t = {}
		for i=1,numelems do table.insert(t, `[self].entries[ [i-1] ]) end
		return t
	end

	local function index(row, col)
		return row*coldim + col
	end

	local function diagonalElems(self)
		local t = {}
		for i=1,rowdim do
			table.insert(t, `self.entries[ [index(i-1,i-1)] ])
		end
		return t
	end

	-- Constructors and factories

	terra MatT:__init()
		[entryList(self)] = [replicate(`0.0, numelems)]
	end

	terra MatT:__copy(other: &MatT)
		[entryList(self)] = [entryList(other)]
	end

	MatT.methods.zero = terra()
		var m : MatT
		m:init()
		return m
	end

	MatT.methods.identity = terra()
		var mat = MatT.zero()
		[diagonalElems(mat)] = [replicate(`1.0, rowdim)]
		return mat
	end


	-- Element access

	MatT.metamethods.__apply = macro(function(self, i, j)
		return `self.entries[ i*coldim + j ]
	end)


	-- Matrix/matrix and Matrix/vector arithmetic

	terra MatT:addInPlace(m2: &MatT)
		[entryList(self)] = [zip(entryList(self), entryList(m2),
			function(a,b) return `a+b end)]
	end
	MatT.methods.addInPlace:setinlined(true)
	MatT.metamethods.__add = terra(m1: MatT, m2: MatT)
		var mat = MatT.salloc():copy(&m1)
		mat:addInPlace(&m2)
		return @mat
	end
	MatT.metamethods.__add:setinlined(true)

	terra MatT:subInPlace(m2: &MatT)
		[entryList(self)] = [zip(entryList(self), entryList(m2),
			function(a,b) return `a-b end)]
	end
	MatT.methods.subInPlace:setinlined(true)
	MatT.metamethods.__sub = terra(m1: MatT, m2: MatT)
		var mat = MatT.salloc():copy(&m1)
		mat:subInPlace(&m2)
		return @mat
	end
	MatT.metamethods.__sub:setinlined(true)

	terra MatT:scaleInPlace(s: real)
		[entryList(self)] = [wrap(entryList(self),
			function(a) return `s*a end)]
	end
	MatT.methods.scaleInPlace:setinlined(true)
	MatT.metamethods.__mul = terralib.overloadedfunction('Mat.__mul', {
		terra(m1: MatT, s: real)
			var mat = MatT.salloc():copy(&m1)
			mat:scaleInPlace(s)
			return @mat
		end,
		terra(s: real, m1: MatT)
			var mat = MatT.salloc():copy(&m1)
			mat:scaleInPlace(s)
			return @mat
		end
	})
	terra MatT:divInPlace(s: real)
		[entryList(self)] = [wrap(entryList(self),
			function(a) return `a/s end)]
	end
	MatT.methods.divInPlace:setinlined(true)
	MatT.metamethods.__div = terra(m1: MatT, s: real)
		var mat = MatT.salloc():copy(&m1)
		mat:divInPlace(s)
		return @mat
	end
	MatT.metamethods.__div:setinlined(true)

	terra MatT:transposeInPlace()
		var tmp : real
		for i=0,rowdim do
			for j=i+1,coldim do
				tmp = self(i,j)
				self(i,j) = self(j,i)
				self(j,i) = tmp				
			end
		end
	end
	terra MatT:transpose()
		var mat = MatT.salloc():copy(self)
		mat:transposeInPlace()
		return @mat
	end

	-- At the moment, I'll only support matrix/matrix multiply between
	--    square matrices
	if rowdim == coldim then
		local dim = rowdim
		MatT.metamethods.__mul:adddefinition(
			terra(m1: MatT, m2: MatT)
				var mout : MatT
				[(function()
					local stmts = {}
					for i=0,dim-1 do
						for j=0,dim-1 do
							local sumexpr = `real(0.0)
							for k=0,dim-1 do
								sumexpr = `[sumexpr] + m1(i,k)*m2(k,j)
							end
							table.insert(stmts, quote mout(i,j) = [sumexpr] end)
						end
					end
					return stmts
				end)()]
				return mout
			end
		)
		terra MatT:mulInPlace(m2: &MatT)
			@self = @self * @m2
		end
		MatT.methods.mulInPlace:setinlined(true)
	end

	-- Matrix/vector multiply
	local InVecT = Vec(real, coldim, GPU)
	local OutVecT = Vec(real, rowdim, GPU)
	MatT.metamethods.__mul:adddefinition(
		terra(m1: MatT, v: InVecT)
			var vout : OutVecT
			[(function()
				local stmts = {}
				for i=0,rowdim-1 do
					local sumexpr = `real(0.0)
					for j=0,coldim-1 do
						sumexpr = `[sumexpr] + m1(i,j)*v(j)
					end
					table.insert(stmts, quote vout(i) = [sumexpr] end)
				end
				return stmts
			end)()]
			return vout
		end
	)

	util.setinlinedOverloaded(MatT.metamethods.__mul, true)

	-- Check for nans
	terra MatT:isnan()
		return not [reduce(wrap(entryList(self),
			function(x) return `x == x end),
			function(a,b) return `a and b end)]
	end
	MatT.methods.isnan:setinlined(true)

	-- 2D Transformation matrices
	if rowdim == 3 and coldim == 3 then
		local Vec2 = Vec(real, 2, GPU)
		local Vec3 = Vec(real, 3, GPU)

		terra MatT:transformPoint(v: Vec2)
			var vout = @self * @Vec3.salloc():init(v(0), v(1), 1.0)
			var vret : Vec2
			if vout(2) == 0.0 then
				vret:init(0.0, 0.0)
			else
				vret:init(vout(0)/vout(2), vout(1)/vout(2))
			end
			return vret
		end
		MatT.methods.transformPoint:setinlined(true)

		terra MatT:transformVector(v: Vec2)
			var vout = @self * @Vec3.salloc():init(v(0), v(1), 0.0)
			var vret : Vec2
			vret:init(vout(0), vout(1))
			return vret
		end
		MatT.methods.transformVector:setinlined(true)

		MatT.methods.translate = terra(tx: real, ty: real) : MatT
			var mat = MatT.identity()
			mat(0, 2) = tx
			mat(1, 2) = ty
			return mat
		end
		MatT.methods.translate:adddefinition((terra(tv: Vec2) : MatT
			return MatT.translate(tv(0), tv(1))
		end):getdefinitions()[1])

		MatT.methods.scale = terra(sx: real, sy: real) : MatT
			var mat = MatT.identity()
			mat(0,0) = sx
			mat(1,1) = sy
			return mat
		end
		MatT.methods.scale:adddefinition((terra(s: real) : MatT
			return MatT.scale(s, s)
		end):getdefinitions()[1])

		MatT.methods.rotate = terra(r: real)
			var mat = MatT.identity()
			var cosr = mlib.cos(r)
			var sinr = mlib.sin(r)
			mat(0,0) = cosr
			mat(0,1) = -sinr
			mat(1,0) = sinr
			mat(1,1) = cosr
			return mat
		end

		MatT.methods.shearYontoX = terra(s: real)
			var mat = MatT.identity()
			mat(0, 1) = s
			return mat
		end

		MatT.methods.shearXontoY = terra(s: real)
			var mat = MatT.identity()
			mat(1, 0) = s
			return mat
		end

	end

	-- 3D Transformation matrices
	if rowdim == 4 and coldim == 4 then
		local Vec3 = Vec(real, 3, GPU)
		local Vec4 = Vec(real, 4, GPU)

		terra MatT:transformPoint(v: Vec3)
			var vout = @self * @Vec4.salloc():init(v(0), v(1), v(2), 1.0)
			var vret : Vec3
			if vout(3) == 0.0 then
				vret:init(0.0, 0.0, 0.0)
			else
				vret:init(vout(0)/vout(3), vout(1)/vout(3), vout(2)/vout(3))
			end
			return vret
		end
		MatT.methods.transformPoint:setinlined(true)

		terra MatT:transformVector(v: Vec3)
			var vout = @self * @Vec4.salloc():init(v(0), v(1), v(2), 0.0)
			var vret : Vec3
			vret:init(vout(0), vout(1), vout(2))
			return vret
		end
		MatT.methods.transformVector:setinlined(true)

		MatT.methods.translate = terralib.overloadedfunction('Mat.translate', {
			terra(tx: real, ty: real, tz: real) : MatT
				var mat = MatT.identity()
				mat(0, 3) = tx
				mat(1, 3) = ty
				mat(2, 3) = tz
				return mat
			end
		})
		MatT.methods.translate:adddefinition(
			terra(tv: Vec3) : MatT
				return MatT.translate(tv(0), tv(1), tv(2))
			end
		)

		MatT.methods.scale = terralib.overloadedfunction('Mat.scale', {
			terra(sx: real, sy: real, sz: real) : MatT
				var mat = MatT.identity()
				mat(0,0) = sx
				mat(1,1) = sy
				mat(2,2) = sz
				return mat
			end
		})
		MatT.methods.scale:adddefinition(
			terra(s: real) : MatT
				return MatT.scale(s, s, s)
			end
		)

		MatT.methods.rotateX = terra(r: real)
			var mat = MatT.identity()
			var cosr = mlib.cos(r)
			var sinr = mlib.sin(r)
			mat(1,1) = cosr
			mat(1,2) = -sinr
			mat(2,1) = sinr
			mat(2,2) = cosr
			return mat
		end

		MatT.methods.rotateY = terra(r: real)
			var mat = MatT.identity()
			var cosr = mlib.cos(r)
			var sinr = mlib.sin(r)
			mat(0,0) = cosr
			mat(2,0) = -sinr
			mat(0,2) = sinr
			mat(2,2) = cosr
			return mat
		end

		MatT.methods.rotateZ = terra(r: real)
			var mat = MatT.identity()
			var cosr = mlib.cos(r)
			var sinr = mlib.sin(r)
			mat(0,0) = cosr
			mat(0,1) = -sinr
			mat(1,0) = sinr
			mat(1,1) = cosr
			return mat
		end

		MatT.methods.rotate = terralib.overloadedfunction('Mat.rotate', {
			terra(axis: Vec3, angle: real) : MatT
				var c = mlib.cos(angle)
				var s = mlib.sin(angle)
				var t = 1.0 - c

				axis:normalize()
				var x = axis(0)
				var y = axis(1)
				var z = axis(2)

				var result : MatT

				result(0,0) = 1 + t*(x*x-1)
				result(1,0) = z*s+t*x*y
				result(2,0) = -y*s+t*x*z
				result(3,0) = 0.0

				result(0,1) = -z*s+t*x*y
				result(1,1) = 1+t*(y*y-1)
				result(2,1) = x*s+t*y*z
				result(3,1) = 0.0

				result(0,2) = y*s+t*x*z
				result(1,2) = -x*s+t*y*z
				result(2,2) = 1+t*(z*z-1)
				result(3,2) = 0.0

				result(0,3) = 0.0
				result(1,3) = 0.0
				result(2,3) = 0.0
				result(3,3) = 1.0

				return result
			end
		})

		MatT.methods.rotate:adddefinition(
			terra(axis: Vec3, angle: real, center: Vec3) : MatT
				return MatT.translate(center) * MatT.rotate(axis, angle) * MatT.translate(-center)
			end
		)

		MatT.methods.face = terra(fromVec: Vec3, toVec: Vec3)
			var axis = fromVec:cross(toVec)
			if axis:norm() == 0.0 then
				return MatT.identity()
			else
				var ang = fromVec:angleBetween(toVec)
				return MatT.rotate(axis, ang)
			end
		end

		MatT.methods.shearYontoX = terra(s: real)
			var mat = MatT.identity()
			mat(0, 1) = s
			return mat
		end

		MatT.methods.shearXontoY = terra(s: real)
			var mat = MatT.identity()
			mat(1, 0) = s
			return mat
		end

		MatT.methods.shearZontoX = terra(s: real)
			var mat = MatT.identity()
			mat(0, 2) = s
			return mat
		end

		MatT.methods.shearXontoZ = terra(s: real)
			var mat = MatT.identity()
			mat(2, 0) = s
			return mat
		end

		MatT.methods.shearYontoZ = terra(s: real)
			var mat = MatT.identity()
			mat(2, 1) = s
			return mat
		end

		MatT.methods.shearZontoY = terra(s: real)
			var mat = MatT.identity()
			mat(1, 2) = s
			return mat
		end

		MatT.methods.lookAt = terra(eyePos: Vec3, lookAtPoint: Vec3, upVec: Vec3)
			var w = (eyePos - lookAtPoint):normalized()
			var u = upVec:cross(w):normalized()
			var v = w:cross(u)
			var rot = MatT.identity()
			rot(0,0) = u(0); rot(0,1) = u(1); rot(0,2) = u(2)
			rot(1,0) = v(0); rot(1,1) = v(1); rot(1,2) = v(2)
			rot(2,0) = w(0); rot(2,1) = w(1); rot(2,2) = w(2)
			return rot * MatT.translate(-eyePos)
		end

		MatT.methods.ortho = terra(bottom: real, top: real, left: real, right: real, near: real, far: real)
			var mat = MatT.identity()
			mat(0,0) = 2.0 / (right - left); mat(0, 3) = -(right+left)/(right-left)
			mat(1,1) = 2.0 / (top - bottom); mat(1, 3) = -(top+bottom)/(top-bottom)
			mat(2,2) = -2.0 / (far - near);   mat(2, 3) = -(far+near)/(far-near)
			return mat
		end

		-- fovy assumed to be in radians
		MatT.methods.perspective = terra(fovy: real, aspect: real, near: real, far: real)
			var f = 1.0 / mlib.tan(fovy/2.0)
			var mat = MatT.zero()
			mat(0,0) = f/aspect
			mat(1,1) = f
			mat(2,2) = (far+near)/(near-far); mat(2,3) = (2*far*near)/(near-far)
			mat(3,2) = -1
			return mat
		end

		local colmajidx = macro(function(i,j) return `j*4 + i end)
		terra MatT:toColumnMajor(data: &real)
			for i=0,4 do
				for j=0,4 do
					data[colmajidx(i,j)] = self(i,j)
				end
			end
		end

		-- Code for 4x4 inverse from http://rodolphe-vaillant.fr/?e=7

		local MINOR = macro(function(m, r0, r1, r2, c0, c1, c2)
			return `m[4*r0+c0] * (m[4*r1+c1] * m[4*r2+c2] - m[4*r2+c1] * m[4*r1+c2]) -
		            m[4*r0+c1] * (m[4*r1+c0] * m[4*r2+c2] - m[4*r2+c0] * m[4*r1+c2]) +
		            m[4*r0+c2] * (m[4*r1+c0] * m[4*r2+c1] - m[4*r2+c0] * m[4*r1+c1])
		end)

		terra MatT:determinant()
			var m = self.entries
			return m[0] * MINOR(m, 1, 2, 3, 1, 2, 3) -
		           m[1] * MINOR(m, 1, 2, 3, 0, 2, 3) +
		           m[2] * MINOR(m, 1, 2, 3, 0, 1, 3) -
		           m[3] * MINOR(m, 1, 2, 3, 0, 1, 2)
		end

		local terra adjoint(m: &real, adjOut: &real)
		    adjOut[ 0] =  MINOR(m,1,2,3,1,2,3); adjOut[ 1] = -MINOR(m,0,2,3,1,2,3); adjOut[ 2] =  MINOR(m,0,1,3,1,2,3); adjOut[ 3] = -MINOR(m,0,1,2,1,2,3)
		    adjOut[ 4] = -MINOR(m,1,2,3,0,2,3); adjOut[ 5] =  MINOR(m,0,2,3,0,2,3); adjOut[ 6] = -MINOR(m,0,1,3,0,2,3); adjOut[ 7] =  MINOR(m,0,1,2,0,2,3)
		    adjOut[ 8] =  MINOR(m,1,2,3,0,1,3); adjOut[ 9] = -MINOR(m,0,2,3,0,1,3); adjOut[10] =  MINOR(m,0,1,3,0,1,3); adjOut[11] = -MINOR(m,0,1,2,0,1,3)
		    adjOut[12] = -MINOR(m,1,2,3,0,1,2); adjOut[13] =  MINOR(m,0,2,3,0,1,2); adjOut[14] = -MINOR(m,0,1,3,0,1,2); adjOut[15] =  MINOR(m,0,1,2,0,1,2)
		end
		 
		terra MatT:inverse()
			var inv = MatT.salloc():init()
			adjoint(self.entries, inv.entries)
			inv:scaleInPlace(1.0 / self:determinant())
			return @inv
		end

	end

	return MatT
end)


return function(real, rowdim, coldim, GPU)
	if GPU == nil then GPU = false end
	return Mat(real, rowdim, coldim, GPU)
end



