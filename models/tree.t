local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Mat4 = terralib.require("linalg.mat")(double, 4, 4)
local util = terralib.require("util")
local S = terralib.require("qs.lib.std")

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

	local terra _branchFrame(f0_cx: double, f0_cy: double, f0_cz: double,
						     f0_fx: double, f0_fy: double, f0_fz: double,
						     f0_ux: double, f0_uy: double, f0_uz: double,
						     f0_r: double,
						     f1_cx: double, f1_cy: double, f1_cz: double,
						     f1_fx: double, f1_fy: double, f1_fz: double,
						     f1_ux: double, f1_uy: double, f1_uz: double,
						     f1_r: double,
						     t: double, theta: double, radius: double)
		--
	end
	local function branchFrame(startFrame, endFrame, t, theta, radius)
		local args = {unpackFrame(startFrame)}
		util.appendTable(args, {unpackFrame(endFrame)})
		table.insert(args, t)
		table.insert(args, theta)
		table.insert(args, radius)
		local retvals = unpacktuple(_branchFrame(unpack(args)))
		local ptr0 = revals[#retvals-1]; retvals[#retvals-1] = nil
		local ptr1 = revals[#retvals]; retvals[#retvals] = nil
		return packFrame(unpack(retvals)), ptr0, ptr1
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
		var v = c0 + r0*up0
		mesh:addVertex(v)
		var rotamt = [2*math.pi]/nSegs
		var m = Mat4.rotate(fwd0, rotamt, c0)
		for i=1,nSegs do
			v = m:transformPoint(v)
			mesh:addVertex(v)
		end
		-- Vertices nSegs+1,2*nSegs are the top outline of the cylinder
		v = c1 + r1*up1
		mesh:addVertex(v)
		m = Mat4.rotate(fwd1, rotamt, c1)
		for i=1,nSegs do
			v = m:transformPoint(v)
			mesh:addVertex(v)
		end
		-- Add quads for the outside of the cylinder
		for i=0,nSegs do
			Shapes.addQuad(mesh, bvi + i, bvi + (i+1)%nSegs, bvi + nSegs + (i+1)%nSegs, bvi + nSegs + i)
		end
		-- Finally, add quads across the bottom of the cylinder
		var nStrips = (nSegs-2)/2
		for i=0,nStrips/2 do
			Shapes.addQuad(mesh, bvi + i, bvi + i+1, bvi + (nSegs/2)-i-1, bvi + (nSegs/2)-i)
		end
		for i=0,nStrips/2 do
			Shapes.addQuad(mesh, bvi + (nSegs/2)+i, bvi + (nSegs/2)+i+1, bvi + nSegs-i-1, bvi + (nSegs-i)%nSegs)
		end
		-- ...and add quads across the top of the cylinder
		for i=0,nStrips/2 do
			Shapes.addQuad(mesh, bvi + nSegs + i, bvi + nSegs + i+1, bvi + nSegs + (nSegs/2)-i-1, bvi + nSegs + (nSegs/2)-i)
		end
		for i=0,nStrips/2 do
			Shapes.addQuad(mesh, bvi + nSegs + (nSegs/2)+i, bvi + nSegs + (nSegs/2)+i+1, bvi + nSegs + nSegs-i-1, bvi + nSegs + (nSegs-i)%nSegs)
		end
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
			local len = uniform(1, 4)
			local uprot = gaussian(0, math.pi/12)
			local leftrot = gaussian(0, math.pi/12)
			local endradius = uniform(0.7, 0.9) * frame.radius

			local nextframe = advanceFrame(frame, uprot, leftrot, len, endradius)
			treeSegment(N_SEGS, prevTrunkRadius0, prevTrunkRadius1, frame, nextframe)
			-- if branchProb then
			-- 	local wherearound = math.uniform(0, 2*math.pi)
			-- 	local branchradius = math.uniform(0.4, 0.8) * frame.radius
			-- 	local t = 0.5
			-- 	local bframe, ptr0, ptr1 = branchFrame(frame, nextframe, wherearound, branchradius)
			-- 	branch(bframe, ptr0, ptr1, depth+1)
			-- end
			local finished = true
			local finished = flip(1-continueProb(i))
			i = i + 1
			frame = nextframe
		until finished
	end

	return function()
		local startFrame = {
			center = {0, 0, 0},
			forward = {0, 1, 0},
			up = {0, 0, -1},
			radius = uniform(0.5, 2.5)
		}
		branch(startFrame, -1, -1, 0)
	end
end



