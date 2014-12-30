local S = terralib.require("qs.lib.std")
local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Mat4 = terralib.require("linalg.mat")(double, 4, 4)

local flip = prob.flip
local uniform = prob.uniform

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	-- This program interprets geoRes as a flag toggling whether we're doing
	-- lo res or hi res
	local nBevelBox
	local bevAmt
	local nCylinder
	if geoRes == 1 then
		nBevelBox = 1
		bevAmt = 0
		nCylinder = 8
	elseif geoRes == 2 then
		nBevelBox = 16
		bevAmt = 0.05
		nCylinder = 32
	else
		error(string.format("weird_building - unrecognized geoRes flag %d", geoRes))
	end

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBeveledBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen, bevAmt, nBevelBox)
	end)
	local boxcap = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double, taper: double)
		var xform = Mat4.translate(cx, cy, cz) * Mat4.scale(xlen, ylen, zlen) * Mat4.rotateX([-math.pi/2])
		Shapes.addTaperedBoxTransformed(mesh, &xform, Vec3.create(0.0), 1.0, 1.0, 1.0, taper)
	end)
	local cylinder = makeGeoPrim(terra(mesh: &Mesh, bcx: double, bcy: double, bcz: double, radius: double, height: double)
		Shapes.addCylinder(mesh, Vec3.create(bcx, bcy, bcz), height, radius, nCylinder)
	end)
	local cylcap = makeGeoPrim(terra(mesh: &Mesh, bcx: double, bcy: double, bcz: double, baseRad: double, tipRad: double, height: double)
		Shapes.addTaperedCylinder(mesh, Vec3.create(bcx, bcy, bcz), height, baseRad, tipRad, nCylinder)
	end)

	-- Forward declare
	local tower

	local function centralTower(depth, ybot, xmin, xmax, zmin, zmax)
		return tower(depth, ybot, xmin, xmax, zmin, zmax, true, true, true, true)
	end
	local function leftTower(depth, ybot, xmin, xmax, zmin, zmax)
		return tower(depth, ybot, xmin, xmax, zmin, zmax, true, false, true, true)
	end
	local function rightTower(depth, ybot, xmin, xmax, zmin, zmax)
		return tower(depth, ybot, xmin, xmax, zmin, zmax, false, true, true, true)
	end
	local function downTower(depth, ybot, xmin, xmax, zmin, zmax)
		return tower(depth, ybot, xmin, xmax, zmin, zmax, true, true, true, false)
	end
	local function upTower(depth, ybot, xmin, xmax, zmin, zmax)
		return tower(depth, ybot, xmin, xmax, zmin, zmax, true, true, false, true)
	end



	local function stackProb(depth)
		return math.exp(-0.4*depth)
	end

	local function lerp(lo, hi, t) return (1-t)*lo + t*hi end
	local function spreadProb(depth)
		-- return 0.25
		local t = depth/5
		return lerp(0.5, 0.25, t)
	end

	local TowerType = { Box = false, Cylinder = true }

	local function towerSegment(towerType, iter, xmin, xmax, zmin, zmax, ybot, leftok, rightok, downok, upok, taper)
		local maxwidth = xmax-xmin
		local maxdepth = zmax-zmin
		local width, height, depth, radius
		if towerType == TowerType.Box then
			if taper then
				width = maxwidth
				depth = maxdepth
			else
				width = uniform(0.5*maxwidth, maxwidth, "boxwidth")
				depth = uniform(0.5*maxdepth, maxdepth, "boxdepth")
			end
		else
			local maxrad = 0.5*math.min(maxwidth, maxdepth)
			if taper then
				radius = maxrad
			else
				radius = uniform(0.5*maxrad, maxrad, "clrad")
			end
			width = 2*radius
			depth = 2*radius
		end
		if taper then
			height = uniform(0.5, 1.5, "capheight")
		else
			height = uniform(1, 3, "height")
		end
		local cx, cz
		if iter == 0 and not leftok then
			cx = xmin + 0.5*width
		elseif iter == 0 and not rightok then
			cx = xmax - 0.5*width
		else
			cx = 0.5*(xmin+xmax)
		end
		if iter == 0 and not downok then
			cz = zmin + 0.5*depth
		elseif iter == 0 and not upok then
			cz = zmax - 0.5*depth
		else
			cz = 0.5*(zmin+zmax)
		end
		if towerType == TowerType.Box then
			if taper then
				local taperamt = uniform(0.1, 0.5, "taperamt")
				boxcap(cx, ybot + 0.5*height, cz, width, height, depth, taperamt)
			else
				box(cx, ybot + 0.5*height, cz, width, height, depth)
			end
		else
			if taper then
				local toprad = uniform(0.1, 0.5, "taperrad") * radius
				cylcap(cx, ybot, cz, radius, toprad, height)
			else
				cylinder(cx, ybot, cz, radius, height)
			end
		end
		return cx, cz, width, height, depth
	end

	tower = function(depth, ybot, xmin, xmax, zmin, zmax, leftok, rightok, downok, upok)
		local towerType = flip(0.5, "towerType")
		local finished = false
		local iter = 0
		repeat
			prob.setAddressLoopIndex(iter)
			local maxwidth = xmax-xmin
			local maxdepth = zmax-zmin
			prob.pushAddress("seg")
			local cx, cz, width, height, depth =
				towerSegment(towerType, iter, xmin, xmax, zmin, zmax, ybot, leftok, rightok, downok, upok)
			prob.popAddress()
			if iter == 0 then
				if leftok then
					if flip(spreadProb(depth), "leftgen") then
						prob.pushAddress("left")
						leftTower(depth+1, ybot, cx-0.5*width-maxwidth, cx-0.5*width, zmin, zmax)
						prob.popAddress()
					end
				end
				if rightok then
					if flip(spreadProb(depth), "rightgen") then
						prob.pushAddress("right")
						rightTower(depth+1, ybot, cx+0.5*width, cx+0.5*width+maxwidth, zmin, zmax)
						prob.popAddress()
					end
				end
				if downok then
					if flip(spreadProb(depth), "downgen") then
						prob.pushAddress("down")
						downTower(depth+1, ybot, xmin, xmax, cz-0.5*depth-maxdepth, cz-0.5*depth)
						prob.popAddress()
					end
				end
				if upok then
					if flip(spreadProb(depth), "upgen") then
						prob.pushAddress("up")
						upTower(depth+1, ybot, xmin, xmax, cz+0.5*depth, cz+0.5*depth+maxdepth)
						prob.popAddress()
					end
				end
			end
			ybot = ybot + height
			xmin = cx - 0.5*width
			xmax = cx + 0.5*width
			zmin = cz - 0.5*depth
			zmax = cz + 0.5*depth
			finished = flip(1-stackProb(iter), "continue")
			iter = iter + 1
		until finished
		if flip(0.5, "gencap") then
			towerSegment(towerType, iter, xmin, xmax, zmin, zmax, ybot, leftok, rightok, downok, upok, true)
		end
	end

	return function()
		prob.pushAddress("central")
		centralTower(0, 0, -2, 2, -2, 2)
		prob.popAddress()
	end
end)


