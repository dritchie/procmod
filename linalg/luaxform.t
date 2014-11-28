local S = terralib.require("qs.lib.std")
local LS = terralib.require("std")
local Vec = terralib.require("linalg.luavec")


local N = 4
local Vec3 = Vec(3)
local Vec4 = Vec(4)

local Transform = LS.LObject()

function Transform:__get(i, j)
	return self[N*(i-1) + j]
end

function Transform:__set(i, j, x)
	self[N*(i-1) + j] = x
end

function Transform:init()
	for i=1,N do
		for j=1,N do
			table.insert(self, 0)
		end 
	end
	return self
end

function Transform:copy(other)
	for i,a in ipairs(other) do
		self[i] = a
	end
	return self
end

function Transform.matVecMul(m, v)
	local vout = v:newcopy()
	for i=1,N do
		vout[i] = 0
		for j=1,N do
			vout[i] = vout[i] + m:__get(i,j) * v[j]
		end
	end
	return vout
end
function Transform.matMatMul(m1, m2)
	local mout = m1:newcopy()
	for i=1,N do
		for j=1,N do
			local sum = 0
			for k=1,N do
				sum = sum + m1:__get(i,k)*m2:__get(k,j)
			end
			mout:__set(i,j, sum)
		end
	end
	return mout
end
-- We only expose mat/mat mul to the user
Transform.__mul = Transform.matMatMul

function Transform:transformPoint(v)
	local vout = Transform.matVecMul(self, Vec4.new(v[1], v[2], v[3], 1))
	if vout[4] == 0 then
		return Vec3.new(0, 0, 0)
	else
		return Vec3.new(vout[1]/vout[4], vout[2]/vout[4], vout[3]/vout[4])
	end
end

function Transform:transformVector(v)
	local vout = Transform.matVecMul(self, Vec4.new(v[1], v[2], v[3], 0))
	return Vec3.new(vout[1], vout[2], vout[3])
end

function Transform.identity()
	local t = Transform.alloc():init()
	for i=1,N do t:__set(i, i, 1) end
	return t
end

function Transform.translate(vec)
	local t = Transform.identity()
	t:__set(1,4, vec[1])
	t:__set(2,4, vec[2])
	t:__set(3,4, vec[3])
	return t
end

function Transform.rotate(axis, angle)
	local c = math.cos(angle)
	local s = math.sin(angle)
	local t = 1 - c

	axis = axis:normalized()
	local x = axis[1]
	local y = axis[2]
	local z = axis[3]

	local result = Transform.alloc()

	result:__set(1,1, 1 + t*(x*x-1))
	result:__set(2,1, z*s+t*x*y)
	result:__set(3,1, -y*s+t*x*z)
	result:__set(4,1, 0)

	result:__set(1,2, -z*s+t*x*y)
	result:__set(2,2, 1+t*(y*y-1))
	result:__set(3,2, x*s+t*y*z)
	result:__set(4,2, 0)

	result:__set(1,3, y*s+t*x*z)
	result:__set(2,3, -x*s+t*y*z)
	result:__set(3,3, 1+t*(z*z-1))
	result:__set(4,3, 0)

	result:__set(1,4, 0)
	result:__set(2,4, 0)
	result:__set(3,4, 0)
	result:__set(4,4, 1)

	return result
end

function Transform.pivot(axis, angle, center)
	return Transform.translate(center) * Transform.rotate(axis, angle) * Transform.translate(-center)
end


return Transform




