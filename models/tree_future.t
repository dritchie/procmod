local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Mat4 = terralib.require("linalg.mat")(double, 4, 4)
local util = terralib.require("util")
local S = terralib.require("qs.lib.std")
local cmath = terralib.includec("math.h")
local LVec3 = terralib.require("linalg.luavec")(3)
local LTransform = terralib.require("linalg.luaxform")

local flip = prob.flip
local uniform = prob.uniform
local gaussian = prob.gaussian
local future = prob.future

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	local function lerp(lo, hi, t) return (1-t)*lo + t*hi end

	local function unpackFrame(frame)
		return frame.center[1], frame.center[2], frame.center[3],
			   frame.forward[1], frame.forward[2], frame.forward[3],
			   frame.up[1], frame.up[2], frame.up[3],
			   frame.radius
	end

	local function packFrame(cx, cy, cz, fx, fy, fz, ux, uy, uz, r)
		return {
			center = LVec3.new(cx, cy, cz),
			forward = LVec3.new(fx, fy, fz),
			up = LVec3.new(ux, uy, uz),
			radius = r
		}
	end

	local terra circleOfVertsAndNormals(mesh: &Mesh, c: Vec3, up: Vec3, fwd: Vec3, r: double, n: uint)
		var v = c + r*up
		mesh:addVertex(v)
		mesh:addNormal((v - c):normalized())
		var rotamt = [2*math.pi]/n
		var m = Mat4.rotate(fwd, rotamt, c)
		for i=1,n do
			v = m:transformPoint(v)
			mesh:addVertex(v)
			mesh:addNormal((v - c):normalized())
		end
	end

	local terra weldCircleOfVerts(mesh: &Mesh, d: Vec3, p0: Vec3, p1: Vec3, r0: double, r1: double, bvi: uint, n: uint)
		var center = 0.5*(p0+p1)
		var a = d:dot(d)
		for i=0,n do
			var v = mesh:getVertex(bvi+i)
			var p = v:projectToLineSeg(p0, p1)
			var t = p:inverseLerp(p0, p1)
			var radius = (1.0-t)*r0 + t*r1
			var r2 = radius*radius
			var b = 2*d:dot(v - p)
			var c = (v - p):dot(v - p) - r2
			var disc = b*b - 4*a*c
			if disc	< 0.0 then disc = 0.0 end
			disc = cmath.sqrt(disc)
			var rayt = (-b - disc)/(2*a)
			mesh:getVertex(bvi+i) = v + rayt*d

		end
	end

	local terra cylinderSides(mesh: &Mesh, baseVertIndex: uint, baseNormIndex: uint, n: uint)
		var bvi = baseVertIndex
		var bni = baseNormIndex
		for i=0,n do
			var i0 = i
			var i1 = (i+1)%n
			var i2 = n + (i+1)%n
			var i3 = n + i
			mesh:addIndex(bvi+i0, bni+i0)
			mesh:addIndex(bvi+i1, bni+i1)
			mesh:addIndex(bvi+i2, bni+i2)
			mesh:addIndex(bvi+i2, bni+i2)
			mesh:addIndex(bvi+i3, bni+i3)
			mesh:addIndex(bvi+i0, bni+i0)
			-- Shapes.addQuad(mesh, bvi + i, bvi + (i+1)%n, bvi + n + (i+1)%n, bvi + n + i)
		end
	end

	local terra cylinderCap(mesh: &Mesh, baseIndex: uint, n: uint)
		var bvi = baseIndex
		var nStrips = (n-2)/2
		for i=0,nStrips/2 do
			Shapes.addQuad(mesh, bvi + i, bvi + i+1, bvi + (n/2)-i-1, bvi + (n/2)-i)
		end
		for i=0,nStrips/2 do
			Shapes.addQuad(mesh, bvi + (n/2)+i, bvi + (n/2)+i+1, bvi + n-i-1, bvi + (n-i)%n)
		end
	end

	local _treeSegment = makeGeoPrim(terra(mesh: &Mesh,
										   nSegs: uint,
										   prevPoint0_x: double, prevPoint0_y: double, prevPoint0_z: double,
										   prevPoint1_x: double, prevPoint1_y: double, prevPoint1_z: double,
										   prevRadius0: double, prevRadius1: double,
										   f0_cx: double, f0_cy: double, f0_cz: double,
										   f0_fx: double, f0_fy: double, f0_fz: double,
										   f0_ux: double, f0_uy: double, f0_uz: double,
										   f0_r: double,
										   f1_cx: double, f1_cy: double, f1_cz: double,
										   f1_fx: double, f1_fy: double, f1_fz: double,
										   f1_ux: double, f1_uy: double, f1_uz: double,
										   f1_r: double,
										   f2_cx: double, f2_cy: double, f2_cz: double,
										   f2_fx: double, f2_fy: double, f2_fz: double,
										   f2_ux: double, f2_uy: double, f2_uz: double,
										   f2_r: double)
		var p0 = Vec3.create(prevPoint0_x, prevPoint0_y, prevPoint0_z)
		var p1 = Vec3.create(prevPoint1_x, prevPoint1_y, prevPoint1_z)
		var c0 = Vec3.create(f0_cx, f0_cy, f0_cz)
		var fwd0 = Vec3.create(f0_fx, f0_fy, f0_fz)
		var up0 = Vec3.create(f0_ux, f0_uy, f0_uz)
		var r0 = f0_r
		var c1 = Vec3.create(f1_cx, f1_cy, f1_cz)
		var fwd1 = Vec3.create(f1_fx, f1_fy, f1_fz)
		var up1 = Vec3.create(f1_ux, f1_uy, f1_uz)
		var r1 = f1_r
		var c2 = Vec3.create(f2_cx, f2_cy, f2_cz)
		var fwd2 = Vec3.create(f2_fx, f2_fy, f2_fz)
		var up2 = Vec3.create(f2_ux, f2_uy, f2_uz)
		var r2 = f2_r

		var bvi = mesh:numVertices()
		var bni = mesh:numNormals()

		-- Vertices 0,nSegs are the bottom outline of the base
		circleOfVertsAndNormals(mesh, c0, up0, fwd0, r0, nSegs)
		-- Vertices nSegs+1,2*nSegs are the outline of the split frame
		circleOfVertsAndNormals(mesh, c1, up1, fwd1, r1, nSegs)
		-- Finally, we have the vertices of the end frame
		circleOfVertsAndNormals(mesh, c2, up2, fwd2, r2, nSegs)
		-- Add quads for the outside between the base and split
		cylinderSides(mesh, bvi, bni, nSegs)
		-- Add quads for the outside between the split and end
		cylinderSides(mesh, bvi+nSegs, bni+nSegs, nSegs)
		-- Finally, add quads across the bottom of the cylinder
		cylinderCap(mesh, bvi, nSegs)
		-- ...and add quads across the top of the cylinder
		cylinderCap(mesh, bvi+2*nSegs, nSegs)
		-- Deal with the 'prev trunk radius' stuff by welding the first circle of verts to the parent branch
		if prevRadius0 > 0.0 then
			var d = 0.5*(p0+p1) - c0; d:normalize()
			weldCircleOfVerts(mesh, d, p0, p1, prevRadius0, prevRadius1, bvi, nSegs)
		end
	end)
	local function treeSegment(nsegs, prev, startFrame, splitFrame, endFrame)
		local args
		if prev then
			args = {nsegs,
				    prev.p0[1], prev.p0[2], prev.p0[3],
				    prev.p1[1], prev.p1[2], prev.p1[3],
				    prev.r0, prev.r1}
		else
			args = {nsegs, 0, 0, 0, 0, 0, 0, -1, -1}
		end
		util.appendTable(args, {unpackFrame(startFrame)})
		util.appendTable(args, {unpackFrame(splitFrame)})
		util.appendTable(args, {unpackFrame(endFrame)})
		_treeSegment(unpack(args))
	end


	local worldup = LVec3.new(0, 1, 0)
	-- local upblendamt = 0.25
	local function advanceFrame(frame, uprot, leftrot, len, endradius)
		local c = frame.center
		local fwd = frame.forward
		local up = frame.up
		local left = up:cross(fwd)
		local uprotmat = LTransform.rotate(up, uprot)
		local leftrotmat = LTransform.rotate(left, leftrot)
		local newup = leftrotmat:transformVector(up)
		local newfwd = (leftrotmat*uprotmat):transformVector(fwd)
		-- newfwd = lerp(newfwd, worldup, upblendamt):normalized()
		local newc = c + len*newfwd
		return {
			center = newc,
			forward = newfwd,
			up = newup,
			radius = endradius
		}
	end

	local function branchFrame(startFrame, endFrame, t, theta, radius, n)
		-- Construct the frame at the given t value
		local ct = lerp(startFrame.center, endFrame.center, t)
		local rt = lerp(startFrame.radius, endFrame.radius, t)
		-- This is just the inradius; need to compute the outradius, since we branches
		--    are polygonal approximations
		rt = rt/math.cos(math.pi/n)


		-- Construct the branch frame
		local m = LTransform.pivot(endFrame.forward, theta, ct)
		local m1 = LTransform.pivot(endFrame.forward, theta, endFrame.center)
		local cbf = m:transformPoint(ct + rt*endFrame.up)
		local upbf = (m1:transformPoint(endFrame.center + endFrame.radius*endFrame.up) - cbf):normalized()
		local fwdbf = (cbf - ct):normalized()
		local leftbf = upbf:cross(fwdbf)
		fwdbf = leftbf:cross(upbf)

		-- Compute the effective radius of the parent branch at the extremes of this new branch frame
		local lopoint = (cbf - radius*upbf):projectToLineSeg(startFrame.center, endFrame.center)
		local lot = lopoint:inverseLerp(startFrame.center, endFrame.center)
		local hipoint = (cbf + radius*upbf):projectToLineSeg(startFrame.center, endFrame.center)
		local hit = hipoint:inverseLerp(startFrame.center, endFrame.center)
		local loradius = lerp(startFrame.radius, endFrame.radius, lot)
		local hiradius = lerp(startFrame.radius, endFrame.radius, hit)
		-- Also turn these into outradii
		loradius = loradius/math.cos(math.pi/n)
		hiradius = hiradius/math.cos(math.pi/n)

		return {
			center = cbf,
			forward = fwdbf,
			up = upbf,
			radius = radius
		},
		{
			p0 = lopoint,
			p1 = hipoint,
			r0 = loradius,
			r1 = hiradius
		}
	end


	local vzero = LVec3.new(0, 0, 0)
	local function findSplitFrame(startFrame, endFrame)
		local v = endFrame.forward:projectToPlane(vzero, startFrame.forward):normalized() * startFrame.radius
		local p0 = startFrame.center - v
		local p2 = startFrame.center + v
		local v2 = v:projectToPlane(vzero, endFrame.forward):normalized() * endFrame.radius
		local p1 = endFrame.center - v2
		local t = -(p0-p2):dot(endFrame.forward) / (p1-p0):dot(endFrame.forward)
		local p3 = lerp(p0, p1, t)
		local r = (p3 - p2):norm() * 0.5
		p2 = p2 + 0.1*r*endFrame.forward 	-- fudge factor
		local c = 0.5*(p2 + p3)
		return {
			center = c,
			forward = endFrame.forward,
			up = endFrame.up,
			radius = r
		}
	end

	local N_THETA_SAMPS = 8
	local function estimateThetaDistrib(f0, f1)
		local v = f1.up
		local w = 0.5*(v:dot(worldup) + 1)
		local minweight = w
		local maxweight = w
		local mini = 0
		local maxi = 0
		local rotmat = LTransform.rotate(f1.forward, math.pi*2/N_THETA_SAMPS)
		for i=1,N_THETA_SAMPS-1 do
			v = rotmat:transformVector(v)
			w = 0.5*(v:dot(worldup) + 1)
			if w < minweight then
				minweight = w
				mini = i
			end
			if w > maxweight then
				maxweight = w
				maxi = i
			end
		end
		local wdiff = maxweight - minweight
		local stddev = lerp(math.pi, math.pi/8, wdiff)
		return math.pi*2*(maxi/N_THETA_SAMPS), stddev
	end


	local N_SEGS = geoRes
	assert(N_SEGS >= 6 and (N_SEGS-2)%4 == 0,
		"N_SEGS must be one of 6, 10, 14, 18, ...")

	local function continueProb(depth)
		return math.exp(-0.1*depth)
	end
	local function branchProb(depth, i)
		-- local ifactor = 10 - i
		-- return math.exp(-0.8*depth - 0.05*ifactor)
		return math.exp(-0.75*depth)
	end

	local numprims = 0
	local origradius
	local function branch(frame, depth, prev)
		-- if depth > 2 then return end
		local finished = false
		local i = 0
		repeat
			-- Kill things that get too small to matter
			if frame.radius/origradius < 0.1 then break end

			local uprot = gaussian(0, math.pi/12)
			local leftrot = gaussian(0, math.pi/12)
			local len = uniform(3, 5) * frame.radius
			local endradius = uniform(0.7, 0.9) * frame.radius

			-- Figure out where we need to split the segment
			-- (This is so the part that we branch from is a pure conic section)
			local nextframe = advanceFrame(frame, uprot, leftrot, len, endradius)
			local splitFrame = findSplitFrame(frame, nextframe)

			-- Place geometry
			treeSegment(N_SEGS, prev, frame, splitFrame, nextframe)
			numprims = numprims + 1

			future.create(function(i, frame, prev)
				if flip(branchProb(depth, i)) then
					-- Theta mean/variance based on avg weighted by 'up-facing-ness'
					local theta_mu, theta_sigma = estimateThetaDistrib(splitFrame, nextframe)
					local theta = gaussian(theta_mu, theta_sigma)
					local maxbranchradius = 0.5*(nextframe.center - splitFrame.center):norm()
					local branchradius = math.min(uniform(0.9, 1) * nextframe.radius, maxbranchradius)
					local bframe, prev = branchFrame(splitFrame, nextframe, 0.5, theta, branchradius, N_SEGS)
					branch(bframe, depth+1, prev)
				end
			end, i, frame, prev)
			-- local finished = true
			local finished = flip(1-continueProb(i))
			-- local finished = endradius < 0.2
			i = i + 1
			frame = nextframe
			-- 'Blank' this out, since it only matters for the first segment in a branch
			prev = nil
		until finished
	end

	return function()
		local startFrame = {
			center = LVec3.new(0, 0, 0),
			forward = LVec3.new(0, 1, 0),
			up = LVec3.new(0, 0, -1),
			radius = uniform(1.5, 2)
		}
		origradius = startFrame.radius
		future.create(branch, startFrame, 0, nil)
		future.finishall()
		-- print("numprims:", numprims)
	end
end)



