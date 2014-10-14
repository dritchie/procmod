local S = terralib.require("qs.lib.std")
local Vec = terralib.require("linalg.vec")


-- Code mostly lifted from mLib's intersection.h

local Intersection = S.memoize(function(real)

	local Vec2 = Vec(real, 2)
	local Vec3 = Vec(real, 3)

	local Intersection = {}

	terra Intersection.intersectRayTriangle(v0: Vec3, v1: Vec3, v2: Vec3, ro: Vec3, rd: Vec3, _t: &real, _u: &real, _v: &real, tmin: real, tmax: real)
		var e1 = v1 - v0
		var e2 = v2 - v0
		var h = rd:cross(e2)
		var a = e1:dot(h)
		if a == 0.0 or a == -0.0 then return false end
		var f = 1.0/a
		var s = ro - v0
		var u = f * s:dot(h)
		if u < 0.0 or u > 1.0 then return false end
		var q = s:cross(e1)
		var v = f * d:dot(q)
		if v < 0.0 or v > 1.0 then return false end
		var t = f * e2:dot(q)
		if t <= tmax and t >= tmin then
			@_t = t
			@_u = u
			@_v = v
			return true
		else
			return false
		end
	end

	local terra halfEdgeTest(p1: Vec2, p2: Vec2, p3: Vec2)
		return (p1(0) - p3(0)) * (p2(1) - p3(1)) - (p2(0) - p3(0)) * (p1(1) - p3(1))
	end

	terra Intersection.intersectPointTriangle(v1: Vec2, v2: Vec2, v3: Vec2, pt: Vec2)
		var b1 = halfEdgeTest(pt, v1, v2) < 0.0
		var b2 = halfEdgeTest(pt, v2, v3) < 0.0
		var b3 = halfEdgeTest(pt, v3, v1) < 0.0
		return (b1 == b2) and (b2 == b3)
	end

	-- Returns 1 if intersects; 0 if front, -1 if back
	local BOX_PLANE_EPSILON = 0.00001
	local terra intersectBoxPlane(bmins: Vec3, bmaxs: Vec3, pdist: Vec3, pnorm: Vec3)
		var center = 0.5 * (bmaxs - bmins)
		var extent = bmaxs - center
		var fOrigin = pnorm:dot(center)
		var fMaxExtent = extent:dot(pnorm:abs())
		var fmin = fOrigin - fMaxExtent
		var fmax = fOrigin + fMaxExtent
		if pdist > fmax + BOX_PLANE_EPSILON then
			return -1
		elseif pdist + BOX_PLANE_EPSILON >= fmin then
			return 1
		else
			return 0
		end
	end

	local TEST_CROSS_EDGE_BOX_MCR = macro(function(edge,absolute_edge,pointa,pointb,extend,i_dir_0,i_dir_1,i_comp_0,i_comp_1)
		return quote
			var dir0 = -edge(i_dir_0)
			var dir1 = edge(i_dir_1)
			var pmin = pointa(i_comp_0)*dir0 + pointa(i_comp_1)*dir1
			var pmax = pointb(i_comp_0)*dir0 + pointb(i_comp_1)*dir1
			if pmin>pmax then
				-- swap
				var tmp = pmin
				pmin = pmax
				pmax = tmp
			end
			var abs_dir0 = absolute_edge(i_dir_0)
			var abs_dir1 = absolute_edge(i_dir_1)
			var rad = extend(i_comp_0)*abs_dir0 + extend(i_comp_1)*abs_dir1
			if pmin>rad or -rad>pmax then
				return false
			end
		end
	end)
	local TEST_CROSS_EDGE_BOX_X_AXIS_MCR = macro(function(edge,absolute_edge,pointa,pointb,extend)
		return TEST_CROSS_EDGE_BOX_MCR(edge,absolute_edge,pointa,pointb,extend,2,1,1,2)
	end)
	local TEST_CROSS_EDGE_BOX_Y_AXIS_MCR = macro(function(edge,absolute_edge,pointa,pointb,extend)
		return TEST_CROSS_EDGE_BOX_MCR(edge,absolute_edge,pointa,pointb,extend,0,2,2,0)
	end)
	local TEST_CROSS_EDGE_BOX_Z_AXIS_MCR = macro(function(edge,absolute_edge,pointa,pointb,extend)
		return TEST_CROSS_EDGE_BOX_MCR(edge,absolute_edge,pointa,pointb,extend,1,0,0,1)
	end)

	terra Intersection.intersectTriangleBBox(bmins: Vec3, bmaxs: Vec3, p0: Vec3, p1: Vec3, p2: Vec3)
		var pnorm = (p1 - p0):cross(p2 - p0); pnorm:normalize()
		var pdist = pnorm:dot(p0)
		if pdist < 0.0 then
			pdist = -pdist
			pnorm = -pnorm
		end
		if intersectBoxPlane(bmins, bmaxs, p0, pdist, pnorm) ~= 1 then
			return false
		end
		var center = 0.5 * (bmins + bmaxs)
		var extent = bmaxs - center
		var v1 = (p0 - center)
		var v2 = (p1 - center)
		var v3 = (p2 - center)
		-- First
		var diff = v2 - v1
		var abs_diff = diff:abs()
		TEST_CROSS_EDGE_BOX_X_AXIS_MCR(diff,abs_diff,v1,v3,extent)
		TEST_CROSS_EDGE_BOX_Y_AXIS_MCR(diff,abs_diff,v1,v3,extent)
		TEST_CROSS_EDGE_BOX_Z_AXIS_MCR(diff,abs_diff,v1,v3,extent)
		-- Second
		diff = v3 - v2
		abs_diff = diff:abs()
		TEST_CROSS_EDGE_BOX_X_AXIS_MCR(diff,abs_diff,v2,v1,extent)
		TEST_CROSS_EDGE_BOX_Y_AXIS_MCR(diff,abs_diff,v2,v1,extent)
		TEST_CROSS_EDGE_BOX_Z_AXIS_MCR(diff,abs_diff,v2,v1,extent)
		-- Third
		diff = v1 - v3
		abs_diff = diff:abs()
		TEST_CROSS_EDGE_BOX_X_AXIS_MCR(diff,abs_diff,v3,v2,extent)
		TEST_CROSS_EDGE_BOX_Y_AXIS_MCR(diff,abs_diff,v3,v2,extent)
		TEST_CROSS_EDGE_BOX_Z_AXIS_MCR(diff,abs_diff,v3,v2,extent)

		return true
	end

end)

return Intersection




