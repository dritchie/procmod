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

---------------------------------------------------------------

return function(makeGeoPrim)

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

	local function advanceFrame(frame, uprot, leftrot, len, endradius)
		local c = frame.center
		local fwd = frame.forward
		local up = frame.up
		local left = up:cross(fwd)
		local uprotmat = LTransform.rotate(up, uprot)
		local leftrotmat = LTransform.rotate(left, leftrot)
		local newup = leftrotmat:transformVector(up)
		local newfwd = (leftrotmat*uprotmat):transformVector(fwd)
		local newc = c + len*newfwd
		return {
			center = newc,
			forward = newfwd,
			up = newup,
			radius = endradius
		}
	end

	local function branchFrame(startFrame, endFrame, t, theta, radius)
		-- Construct the frame at the given t value
		local ct = lerp(startFrame.center, endFrame.center, t)
		local rt = lerp(startFrame.radius, endFrame.radius, t)

		-- Construct the branch frame
		local m = LTransform.pivot(endFrame.forward, theta, ct)
		local m1 = LTransform.pivot(endFrame.forward, theta, endFrame.center)
		local cbf = m:transformPoint(ct + rt*endFrame.up)
		local upbf = (m1:transformPoint(endFrame.center + endFrame.radius*endFrame.up) - cbf):normalized()
		local fwdbf = (cbf - ct):normalized()
		local leftbf = upbf:cross(fwdbf)
		fwdbf = leftbf:cross(upbf)

		-- TODO: Actually compute correct 'previous trunk radius' values
		return {
			center = cbf,
			forward = fwdbf,
			up = upbf,
			radius = radius
		}, 0, 0
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
				-- TODO: Theta mean/variance based on avg weighted by 'up-facing-ness'
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
			center = LVec3.new(0, 0, 0),
			forward = LVec3.new(0, 1, 0),
			up = LVec3.new(0, 0, -1),
			radius = uniform(0.5, 1)
		}
		branch(startFrame, -1, -1, 0)
	end
end



