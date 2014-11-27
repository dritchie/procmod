local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Mat4 = terralib.require("linalg.mat")(double, 4, 4)
local util = terralib.require("util")
local S = terralib.require("qs.lib.std")
local cmath = terralib.includec("math.h")

local flip = prob.flip
local uniform = prob.uniform
local gaussian = prob.gaussian

---------------------------------------------------------------

return function(makeGeoPrim)

	local function unpackFrame(frame)
		return frame.center[1], frame.center[2], frame.center[3],
			   frame.forward[1], frame.forward[2], frame.forward[3],
			   frame.up[1], frame.up[2], frame.up[3],
			   frame.radius
	end

	local function packFrame(cx, cy, cz, fx, fy, fz, ux, uy, uz, r)
		return {
			center = {cx, cy, cz},
			forward = {fx, fy, fz},
			up = {ux, uy, uz},
			radius = r
		}
	end

	local terra _advanceFrame(f0_cx: double, f0_cy: double, f0_cz: double,
							  f0_fx: double, f0_fy: double, f0_fz: double,
							  f0_ux: double, f0_uy: double, f0_uz: double,
							  f0_r: double,
							  uprot: double, leftrot: double, len: double, endradius: double)
		var c = Vec3.create(f0_cx, f0_cy, f0_cz)
		var fwd = Vec3.create(f0_fx, f0_fy, f0_fz)
		var up = Vec3.create(f0_ux, f0_uy, f0_uz)
		var left = up:cross(fwd)
		var uprotmat = Mat4.rotate(up, uprot)
		var leftrotmat = Mat4.rotate(left, leftrot)
		var newup = leftrotmat:transformVector(up)
		var newfwd = (leftrotmat*uprotmat):transformVector(fwd)
		-- var newup = up
		-- var newfwd = fwd
		var newc = c + len*newfwd
		return newc(0), newc(1), newc(2),
			   newfwd(0), newfwd(1), newfwd(2),
			   newup(0), newup(1), newup(2),
			   endradius
	end
	local function advanceFrame(frame, uprot, leftrot, len, endradius)
		local args = {unpackFrame(frame)}
		table.insert(args, uprot)
		table.insert(args, leftrot)
		table.insert(args, len)
		table.insert(args, endradius)
		return packFrame(unpacktuple(_advanceFrame(unpack(args))))
	end

	local lerp = macro(function(lo, hi, t) return `(1.0-t)*lo + t*hi end)
	local terra _branchFrame(f0_cx: double, f0_cy: double, f0_cz: double,
						     f0_fx: double, f0_fy: double, f0_fz: double,
						     f0_ux: double, f0_uy: double, f0_uz: double,
						     f0_r: double,
						     f1_cx: double, f1_cy: double, f1_cz: double,
						     f1_fx: double, f1_fy: double, f1_fz: double,
						     f1_ux: double, f1_uy: double, f1_uz: double,
						     f1_r: double,
						     t: double, theta: double, radius: double)
		var c0 = Vec3.create(f0_cx, f0_cy, f0_cz)
		var fwd0 = Vec3.create(f0_fx, f0_fy, f0_fz)
		var up0 = Vec3.create(f0_ux, f0_uy, f0_uz)
		var r0 = f0_r
		var c1 = Vec3.create(f1_cx, f1_cy, f1_cz)
		var fwd1 = Vec3.create(f1_fx, f1_fy, f1_fz)
		var up1 = Vec3.create(f1_ux, f1_uy, f1_uz)
		var r1 = f1_r

		-- Construct the frame at the given t value
		var ct = lerp(c0, c1, t)
		var rt = lerp(r0, r1, t)

		-- Construct the branch frame
		var m = Mat4.rotate(fwd1, theta, ct)
		var m1 = Mat4.rotate(fwd1, theta, c1)
		var cbf = m:transformPoint(ct + up1*rt)
		var upbf = m1:transformPoint(c1 + up1*r1) - cbf; upbf:normalize()
		var fwdbf = cbf - ct; fwdbf:normalize()
		var leftbf = upbf:cross(fwdbf)
		fwdbf = leftbf:cross(upbf)

		-- TODO: Actually compute correct 'previous trunk radius' values
		return cbf(0), cbf(1), cbf(2),
			   fwdbf(0), fwdbf(1), fwdbf(2),
			   upbf(0), upbf(1), upbf(2),
			   radius,
			   0.0, 0.0 
	end
	local function branchFrame(startFrame, endFrame, t, theta, radius)
		local args = {unpackFrame(startFrame)}
		util.appendTable(args, {unpackFrame(endFrame)})
		table.insert(args, t)
		table.insert(args, theta)
		table.insert(args, radius)
		local retvals = {unpacktuple(_branchFrame(unpack(args)))}
		local ptr1 = retvals[#retvals]; retvals[#retvals] = nil
		local ptr0 = retvals[#retvals]; retvals[#retvals] = nil
		return packFrame(unpack(retvals)), ptr0, ptr1
	end

	local terra circleOfVerts(mesh: &Mesh, c: Vec3, up: Vec3, fwd: Vec3, r: double, n: uint)
		var v = c + r*up
		mesh:addVertex(v)
		var rotamt = [2*math.pi]/n
		var m = Mat4.rotate(fwd, rotamt, c)
		for i=1,n do
			v = m:transformPoint(v)
			mesh:addVertex(v)
		end
	end

	local terra cylinderSides(mesh: &Mesh, baseIndex: uint, n: uint)
		var bvi = baseIndex
		for i=0,n do
			Shapes.addQuad(mesh, bvi + i, bvi + (i+1)%n, bvi + n + (i+1)%n, bvi + n + i)
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



	local terra _branchVis(mesh: &Mesh, 
							f0_cx: double, f0_cy: double, f0_cz: double,
						     f0_fx: double, f0_fy: double, f0_fz: double,
						     f0_ux: double, f0_uy: double, f0_uz: double,
						     f0_r: double,
						     f1_cx: double, f1_cy: double, f1_cz: double,
						     f1_fx: double, f1_fy: double, f1_fz: double,
						     f1_ux: double, f1_uy: double, f1_uz: double,
						     f1_r: double)
		var c0 = Vec3.create(f0_cx, f0_cy, f0_cz)
		var fwd0 = Vec3.create(f0_fx, f0_fy, f0_fz)
		var up0 = Vec3.create(f0_ux, f0_uy, f0_uz)
		var r0 = f0_r
		var c1 = Vec3.create(f1_cx, f1_cy, f1_cz)
		var fwd1 = Vec3.create(f1_fx, f1_fy, f1_fz)
		var up1 = Vec3.create(f1_ux, f1_uy, f1_uz)
		var r1 = f1_r

		var t = 0.5
		var theta = 0.0

		-- Construct the frame at the given t value
		var ct = lerp(c0, c1, t)
		var rt = lerp(r0, r1, t)

		-- -- Visualize where this actually is
		var bvi = mesh:numVertices()
		-- circleOfVerts(mesh, ct, up1, fwd1, rt, 10)
		-- cylinderCap(mesh, bvi, 10)

		-- Construct the branch frame
		var m = Mat4.rotate(fwd1, theta, ct)
		var m1 = Mat4.rotate(fwd1, theta, c1)
		var cbf = m:transformPoint(ct + up1*rt)
		var upbf = m1:transformPoint(c1 + up1*r1) - cbf; upbf:normalize()
		var fwdbf = cbf - ct; fwdbf:normalize()
		var leftbf = upbf:cross(fwdbf)
		fwdbf = leftbf:cross(upbf)

		-- Visualize where this actually is
		bvi = mesh:numVertices()
		circleOfVerts(mesh, cbf, upbf, fwdbf, r1*0.7, 10)
		cylinderCap(mesh, bvi, 10)
	end



	local _treeSegment = makeGeoPrim(terra(mesh: &Mesh,
										   nSegs: uint,
										   prevTrunkRadius0: double, prevTrunkRadius1: double,
										   f0_cx: double, f0_cy: double, f0_cz: double,
										   f0_fx: double, f0_fy: double, f0_fz: double,
										   f0_ux: double, f0_uy: double, f0_uz: double,
										   f0_r: double,
										   f1_cx: double, f1_cy: double, f1_cz: double,
										   f1_fx: double, f1_fy: double, f1_fz: double,
										   f1_ux: double, f1_uy: double, f1_uz: double,
										   f1_r: double)
		var c0 = Vec3.create(f0_cx, f0_cy, f0_cz)
		var fwd0 = Vec3.create(f0_fx, f0_fy, f0_fz)
		var up0 = Vec3.create(f0_ux, f0_uy, f0_uz)
		var r0 = f0_r
		var c1 = Vec3.create(f1_cx, f1_cy, f1_cz)
		var fwd1 = Vec3.create(f1_fx, f1_fy, f1_fz)
		var up1 = Vec3.create(f1_ux, f1_uy, f1_uz)
		var r1 = f1_r

		var bvi = mesh:numVertices()

		-- Vertices 0,nSegs are the bottom outline of the cylinder
		-- TODO: Deal with the 'prev trunk radius' stuff
		circleOfVerts(mesh, c0, up0, fwd0, r0, nSegs)
		-- Vertices nSegs+1,2*nSegs are the top outline of the cylinder
		circleOfVerts(mesh, c1, up1, fwd1, r1, nSegs)
		-- Add quads for the outside of the cylinder
		cylinderSides(mesh, bvi, nSegs)
		-- Finally, add quads across the bottom of the cylinder
		cylinderCap(mesh, bvi, nSegs)
		-- ...and add quads across the top of the cylinder
		cylinderCap(mesh, bvi+nSegs, nSegs)

		-- _branchVis(mesh,
		-- 		   f0_cx, f0_cy, f0_cz, f0_fx, f0_fy, f0_fz, f0_ux, f0_uy, f0_uz, f0_r,
		-- 		   f1_cx, f1_cy, f1_cz, f1_fx, f1_fy, f1_fz, f1_ux, f1_uy, f1_uz, f1_r)
	end)
	local function treeSegment(nsegs, prevTrunkRadius0, prevTrunkRadius1, startFrame, endFrame)
		local args = {nsegs, prevTrunkRadius0, prevTrunkRadius1}
		util.appendTable(args, {unpackFrame(startFrame)})
		util.appendTable(args, {unpackFrame(endFrame)})
		_treeSegment(unpack(args))
	end


	
	local function continueProb(depth)
		return math.exp(-0.4*depth)
	end
	local function branchProb(depth)
		return math.exp(-0.4*depth)
	end

	local N_SEGS = 10
	assert(N_SEGS >= 6 and (N_SEGS-2)%4 == 0,
		"N_SEGS must be one of 6, 10, 14, 18, ...")

	local function branch(frame, prevTrunkRadius0, prevTrunkRadius1, depth)
		local finished = false
		local i = 0
		repeat
			local uprot = gaussian(0, math.pi/12)
			local leftrot = gaussian(0, math.pi/12)
			-- TODO: Make len params dependent on the extremity of the chosen rotation
			local len = uniform(0.1, 0.5)
			local endradius = uniform(0.8, 0.99) * frame.radius

			local nextframe = advanceFrame(frame, uprot, leftrot, len, endradius)
			treeSegment(N_SEGS, prevTrunkRadius0, prevTrunkRadius1, frame, nextframe)
			frame = nextframe

			-- TODO: Length params dependent on radius (smaller radius -> shorter branch)
			len = uniform(0.5, 1.5)
			uprot = 0.0
			leftrot = 0.0
			endradius = uniform(0.7, 0.9) * frame.radius

			nextframe = advanceFrame(frame, uprot, leftrot, len, endradius)
			treeSegment(N_SEGS, prevTrunkRadius0, prevTrunkRadius1, frame, nextframe)

			if flip(branchProb(depth)) then
				-- local theta = uniform(0, 2*math.pi)
				local theta = gaussian(0, math.pi/6)
				local branchradius = uniform(0.5, 0.9) * endradius
				local t = 0.5
				local bframe, ptr0, ptr1 = branchFrame(frame, nextframe, t, theta, branchradius)
				branch(bframe, ptr0, ptr1, depth+1)
			end
			-- local finished = true
			local finished = flip(1-continueProb(i))
			-- local finished = endradius < 0.2
			i = i + 1
			frame = nextframe
		until finished
	end

	return function()
		local startFrame = {
			center = {0, 0, 0},
			forward = {0, 1, 0},
			up = {0, 0, -1},
			radius = uniform(0.5, 1)
		}
		branch(startFrame, -1, -1, 0)
	end
end



