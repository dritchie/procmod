local S = terralib.require("qs.lib.std")
local Vec = terralib.require("linalg.vec")
local tmath = terralib.require("qs.lib.tmath")


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
		var v = f * rd:dot(q)
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
	local terra intersectBoxPlane(bmins: Vec3, bmaxs: Vec3, pdist: real, pnorm: Vec3)
		var center = 0.5 * (bmaxs + bmins)
		var extent = bmaxs - center
		var fOrigin = pnorm:dot(center)
		var fMaxExtent = extent:dot(pnorm:abs())
		var fmin = fOrigin - fMaxExtent
		var fmax = fOrigin + fMaxExtent
		if pdist > fmax + BOX_PLANE_EPSILON then
			-- S.printf("-1\n")
			return -1
		elseif pdist + BOX_PLANE_EPSILON >= fmin then
			-- S.printf("1\n")
			return 1
		else
			-- S.printf("0\n")
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
		return `TEST_CROSS_EDGE_BOX_MCR(edge,absolute_edge,pointa,pointb,extend,2,1,1,2)
	end)
	local TEST_CROSS_EDGE_BOX_Y_AXIS_MCR = macro(function(edge,absolute_edge,pointa,pointb,extend)
		return `TEST_CROSS_EDGE_BOX_MCR(edge,absolute_edge,pointa,pointb,extend,0,2,2,0)
	end)
	local TEST_CROSS_EDGE_BOX_Z_AXIS_MCR = macro(function(edge,absolute_edge,pointa,pointb,extend)
		return `TEST_CROSS_EDGE_BOX_MCR(edge,absolute_edge,pointa,pointb,extend,1,0,0,1)
	end)

	terra Intersection.intersectTriangleBBox(bmins: Vec3, bmaxs: Vec3, p0: Vec3, p1: Vec3, p2: Vec3)
		var pnorm = (p1 - p0):cross(p2 - p0); pnorm:normalize()
		var pdist = pnorm:dot(p0)
		if pdist < 0.0 then
			pdist = -pdist
			pnorm = -pnorm
		end
		if intersectBoxPlane(bmins, bmaxs, pdist, pnorm) ~= 1 then
			-- S.printf("-------------------------------\n")
			-- S.printf("box/plane intersect FAILED\n")
			-- S.printf("plane: p = (%g, %g, %g), n = (%g, %g, %g)\n",
			-- 	p0(0), p0(1), p0(2), pnorm(0), pnorm(1), pnorm(2))
			-- S.printf("box: (%g, %g, %g) to (%g, %g, %g)\n",
			-- 	bmins(0), bmins(1), bmins(2), bmaxs(0), bmaxs(1), bmaxs(2))
			return false
		end
		-- S.printf("box/plane intersect PASSED\n")
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

	local SORT = macro(function(a, b)
		return quote
			if a > b then
				var tmp = a
				a = b
				b = tmp
			end
		end
	end)

	local terra EDGE_EDGE_TEST(v0: Vec3, u0: Vec3, u1: Vec3, i0: uint16, i1: uint16,
							   a: &Vec2, b: &Vec2, c: &Vec2, d: &real, e: &real, f: &real)
		b(0) = u0(i0) - u1(i0)
		b(1) = u0(i1) - u1(i1)
		c(0) = v0(i0) - u0(i0)
		c(1) = v0(i1) - u0(i1)
		@f = a(1)*b(0) - a(0)*b(1)
		@d = b(1)*c(0) - b(0)*c(1)
		if (@f > 0.0 and @d >= 0.0 and @d <= @f) or (@f < 0.0 and @d <= 0.0 and @d >= @f) then
			@e = a(0)*c(1) - a(1)*c(0)
			if @f > 0.0 then
				if @e >= 0.0 and @e <= @f then return true end
			else
				if @e <= 0.0 and @e >= @f then return true end
			end
		end
		return false
	end

	local terra EDGE_AGAINST_TRI_EDGES(v0: Vec3, v1: Vec3, u0: Vec3, u1: Vec3, u2: Vec3,
									   i0: uint16, i1: uint16)
		var a : Vec2, b : Vec2, c : Vec2
		var e : real, d : real, f : real
		a(0) = v1(i0) - v0(i0)
		a(1) = v1(i1) - v0(i1)
		if EDGE_EDGE_TEST(v0, u0, u1, i0, i1, &a, &b, &c, &d, &e, &f) then return true end
		if EDGE_EDGE_TEST(v0, u1, u2, i0, i1, &a, &b, &c, &d, &e, &f) then return true end
		if EDGE_EDGE_TEST(v0, u2, u0, i0, i1, &a, &b, &c, &d, &e, &f) then return true end
		return false
	end

	local terra POINT_IN_TRI(v0: Vec3, u0: Vec3, u1: Vec3, u2: Vec3, i0: uint16, i1: uint16)
		var a : real, b : real, c : real, d0 : real, d1 : real, d2 : real
		a = u1(i1) - u0(i1)
		b = -(u1(i0) - u0(i0))
		c = -a*u0(i0) - b*u0(i1)
		d0 = a*v0(i0) + b*v0(i1) + c
		a = u2(i1) - u1(i1)
		b = -(u2(i0) - u1(i0))
		c = -a*u1(i0) - b*u1(i1)
		d1 = a*v0(i0) + b*v0(i1) + c
		a = u0(i1) - u2(i1)
		b = -(u0(i0) - u2(i0))
		c = -a*u2(i0) - b*u2(i1)
		d2 = a*v0(i0) + b*v0(i1) + c
		if d0*d1 > 0.0 then
			if d0*d2 > 0.0 then return true end
		end
		return false
	end

	local terra coplanar_tri_tri(n: Vec3, v0: Vec3, v1: Vec3, v2: Vec3, u0: Vec3, u1: Vec3, u2: Vec3)
		var i0 : uint16, i1 : uint16
		var a = n:abs()
		if a(0) > a(1) then
			if a(0) > a(2) then
				i0 = 1
				i1 = 2
			else
				i0 = 0
				i1 = 1
			end
		else
			if a(2) > a(1) then
				i0 = 0
				i1 = 1
			else
				i0 = 0
				i1 = 2
			end
		end
		-- Test all edges of triangle 1 against all edges of triangle 2
		if EDGE_AGAINST_TRI_EDGES(v0, v1, u0, u1, u2, i0, i1) then return true end
		if EDGE_AGAINST_TRI_EDGES(v1, v2, u0, u1, u2, i0, i1) then return true end
		if EDGE_AGAINST_TRI_EDGES(v2, v0, u0, u1, u2, i0, i1) then return true end
		-- Test if either triangle is totally contained in the other
		if POINT_IN_TRI(v0, u0, u1, u2, i0, i1) then return true end
		if POINT_IN_TRI(u0, v0, v1, v2, i0, i1) then return true end
		return false
	end

	local terra NEWCOMPUTE_INTERVALS(vv0: real, vv1: real, vv2: real, d0: real, d1: real, d2: real, d0d1: real, d0d2: real,
									 a: &real, b: &real, c: &real, x0: &real, x1: &real)
		if d0d1 > 0.0 then
			@a = vv2; @b = (vv0 - vv2)*d2; @c = (vv1 - vv2)*d2; @x0 = d2 - d0; @x1 = d2 - d1
		elseif d0d2 > 0.0 then
			@a = vv1; @b = (vv0 - vv1)*d1; @c = (vv2 - vv1)*d1; @x0 = d1 - d0; @x1 = d1 - d2
		elseif d1*d2 > 0.0 or d0 ~= 0.0 then
			@a = vv0; @b = (vv1 - vv0)*d0; @c = (vv2 - vv0)*d0; @x0 = d0 - d1; @x1 = d0 - d2
		elseif d1 ~= 0.0 then
			@a = vv1; @b = (vv0 - vv1)*d1; @c = (vv2 - vv1)*d1; @x0 = d1 - d0; @x1 = d1 - d2
		elseif d2 ~= 0.0 then
			@a = vv2; @b = (vv0 - vv2)*d2; @c = (vv1 - vv2)*d2; @x0 = d2 - d0; @x1 = d2 - d1
		else
			return true		-- Triangles are coplanar
		end
		return false
	end

	local EPSILON = 0.000001
	terra Intersection.intersectTriangleTriangle(v0: Vec3, v1: Vec3, v2: Vec3, u0: Vec3, u1: Vec3, u2: Vec3,
												 coplanarCounts: bool)
		-- Compute plane equation of triangle v0, v1, v2 (n1.x + d1 = 0)
		var e1 = v1 - v0
		var e2 = v2 - v0
		var n1 = e1:cross(e2)
		var d1 = -(n1:dot(v0))
		-- Put u0, u1, u2 into plane equation to compute signed dists to the plane
		var du0 = n1:dot(u0) + d1
		var du1 = n1:dot(u1) + d1
		var du2 = n1:dot(u2) + d1
		-- Coplanarity robustness check
		if tmath.fabs(du0) < EPSILON then du0 = 0.0 end
		if tmath.fabs(du1) < EPSILON then du1 = 0.0 end
		if tmath.fabs(du2) < EPSILON then du1 = 0.0 end
		-- Same sign on all + not equal 0 --> no intersection
		var du0du1 = du0*du1
		var du0du2 = du0*du2
		if du0du1 > 0.0 and du0du2 > 0.0 then return false end
		-- Compute plane equation of triangle u0, u1, u2 (n2.x + d2 = 0)
		e1 = u1 - u0
		e2 = u2 - u0
		var n2 = e1:cross(e2)
		var d2 = -(n2:dot(u0))
		-- Put v0, v1, v2 into plane equation to compute signed dists to the plane
		var dv0 = n2:dot(v0) + d2
		var dv1 = n2:dot(v1) + d2
		var dv2 = n2:dot(v2) + d2
		-- Coplanarity robustness check
		if tmath.fabs(dv0) < EPSILON then dv0 = 0.0 end
		if tmath.fabs(dv1) < EPSILON then dv1 = 0.0 end
		if tmath.fabs(dv2) < EPSILON then du1 = 0.0 end
		-- Same sign on all + not equal 0 --> no intersection
		var dv0dv1 = dv0*dv1
		var dv0dv2 = dv0*dv2
		if dv0dv1 > 0.0 and dv0dv2 > 0.0 then return false end
		-- Compute direction of intersection line
		var D = n1:cross(n2)
		-- Compute index to largest component of D
		var max = tmath.fabs(D(0))
		var index = 0U
		var bb = tmath.fabs(D(1))
		var cc = tmath.fabs(D(2))
		if bb > max then max = bb; index = 1 end
		if cc > max then max = cc; index = 2 end
		-- Simplified projection onto intersection line L
		var vp0 = v0(index)
		var vp1 = v1(index)
		var vp2 = v2(index)
		var up0 = u0(index)
		var up1 = u1(index)
		var up2 = u2(index)
		-- Compute interval for triangle 1
		var a: real, b: real, c: real, x0: real, x1: real
		if NEWCOMPUTE_INTERVALS(vp0, vp1, vp2, dv0, dv1, dv2, dv0dv1, dv0dv2, &a, &b, &c, &x0, &x1) then
			if coplanarCounts then
				return coplanar_tri_tri(n1, v0, v1, v2, u0, u1, u2)
			else
				return false
			end
		end
		var d: real, e: real, f: real, y0: real, y1: real
		if NEWCOMPUTE_INTERVALS(up0, up1, up2, du0, du1, du2, du0du1, du0du2, &d, &e, &f, &y0, &y1) then
			if coplanarCounts then
				return coplanar_tri_tri(n1, v0, v1, v2, u0, u1, u2)
			else
				return false
			end
		end
		-- Finish up with non-coplanar intersection
		var xx: real, yy: real, xxyy: real, tmp: real
		xx = x0*x1
		yy = y0*y1
		xxyy = xx*yy
		var isect1 : Vec2, isect2 : Vec2
		tmp = a*xxyy
		isect1(0) = tmp + b*x1*yy
		isect1(1) = tmp + c*x0*yy
		tmp = d*xxyy
		isect2(0) = tmp + e*xx*y1
		isect2(1) = tmp + f*xx*y0
		SORT(isect1(0), isect1(1))
		SORT(isect2(0), isect2(1))
		if isect1(1) < isect2(0) or isect2(1) < isect1(0) then return false end
		return true
	end

	return Intersection

end)

return Intersection




