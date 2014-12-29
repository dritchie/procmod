local S = terralib.require("qs.lib.std")
local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Mat4 = terralib.require("linalg.mat")(double, 4, 4)

local flip = prob.flip
local uniform = prob.uniform
local multinomial = prob.multinomial
local future = prob.future

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
		nBevelBox = 10
		bevAmt = 0.15
		nCylinder = 32
	else
		error(string.format("spaceship - unrecognized geoRes flag %d", geoRes))
	end

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBeveledBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen, bevAmt, nBevelBox)
	end)
	local taperedbox = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double, taper: double)
		Shapes.addTaperedBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen, taper)
	end)
	local wingseg = makeGeoPrim(terra(mesh: &Mesh, xbase: double, zbase: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBeveledBox(mesh, Vec3.create(xbase + 0.5*xlen, 0.0, zbase), xlen, ylen, zlen, bevAmt, nBevelBox)
		Shapes.addBeveledBox(mesh, Vec3.create(-(xbase + 0.5*xlen), 0.0, zbase), xlen, ylen, zlen, bevAmt, nBevelBox)
	end)
	local bodycyl = makeGeoPrim(terra(mesh: &Mesh, zbase: double, radius: double, length: double)
		var xform = Mat4.translate(0.0, 0.0, 0.5*length + zbase) * Mat4.rotateX([math.pi/2]) * Mat4.translate(0.0, -0.5*length, 0.0)
		Shapes.addCylinderTransformed(mesh, &xform, Vec3.create(0.0), length, radius, nCylinder)
	end)
	local bodycylcluster = makeGeoPrim(terra(mesh: &Mesh, zbase: double, radius: double, length: double)
		var tmpmesh = Mesh.salloc():init()
		Shapes.addCylinder(tmpmesh, Vec3.create(0.0), length, radius, nCylinder)
		var finishxform = Mat4.translate(0.0, 0.0, 0.5*length + zbase) * Mat4.rotateX([math.pi/2]) * Mat4.translate(0.0, -0.5*length, 0.0)
		var xform : Mat4
		xform = finishxform * Mat4.translate(-radius, 0.0, -radius)
		mesh:appendTransformed(tmpmesh, &xform)
		xform = finishxform * Mat4.translate(-radius, 0.0, radius)
		mesh:appendTransformed(tmpmesh, &xform)
		xform = finishxform * Mat4.translate(radius, 0.0, -radius)
		mesh:appendTransformed(tmpmesh, &xform)
		xform = finishxform * Mat4.translate(radius, 0.0, radius)
		mesh:appendTransformed(tmpmesh, &xform)
	end)
	local wingcyls = makeGeoPrim(terra(mesh: &Mesh, xbase: double, zbase: double, radius: double, length: double)
		var tmpmesh = Mesh.salloc():init()
		Shapes.addCylinder(tmpmesh, Vec3.create(0.0), length, radius, nCylinder)
		var firstxform = Mat4.rotateX([math.pi/2]) * Mat4.translate(0.0, -0.5*length, 0.0)
		var xform = Mat4.translate(-xbase - radius, 0.0, zbase) * firstxform
		mesh:appendTransformed(tmpmesh, &xform)
		xform = Mat4.translate(xbase + radius, 0.0, zbase) * firstxform
		mesh:appendTransformed(tmpmesh, &xform)
	end)
	local wingguns = makeGeoPrim(terra(mesh: &Mesh, xbase: double, ybase: double, zbase: double, length: double)
		var gunRadius = 0.15
		var tipRadius = 0.03
		var tipLength = 0.4
		var tmpMesh = Mesh.salloc():init()
		Shapes.addCylinder(tmpMesh, Vec3.create(0.0), length, gunRadius, nCylinder)
		Shapes.addTaperedCylinder(tmpMesh, Vec3.create(0.0, length, 0.0), tipLength, gunRadius, tipRadius, nCylinder)
		var firstTransform = Mat4.rotateX([math.pi/2]) * Mat4.translate(0.0, -length*0.5, 0.0)
		var xform : Mat4
		xform = Mat4.translate(-xbase, -ybase-gunRadius, zbase) * firstTransform
		mesh:appendTransformed(tmpMesh, &xform)
		xform = Mat4.translate(-xbase, ybase+gunRadius, zbase) * firstTransform
		mesh:appendTransformed(tmpMesh, &xform)
		xform = Mat4.translate(xbase, -ybase-gunRadius, zbase) * firstTransform
		mesh:appendTransformed(tmpMesh, &xform)
		xform = Mat4.translate(xbase, ybase+gunRadius, zbase) * firstTransform
		mesh:appendTransformed(tmpMesh, &xform)
	end)

	local function wi(i, w)
		return math.exp(-w*i)
	end

	-- What type of wing segment to generate
	local WingSegType =
	{
		Box = 1,
		Cylinder = 2
	}
	local wingSegTypeWeights = {}
	for _,_ in pairs(WingSegType) do table.insert(wingSegTypeWeights, 1) end

	local function genBoxWingSeg(xbase, zlo, zhi)
		local zbase = uniform(zlo, zhi)
		local xlen = uniform(0.25, 2.0)
		local ylen = uniform(0.25, 1.25)
		local zlen = uniform(0.5, 4.0)
		wingseg(xbase, zbase, xlen, ylen, zlen)
		future.create(function()
			if flip(0.5) then
				local gunlen = uniform(1.0, 1.2)*zlen
				local gunxbase = xbase + 0.5*xlen
				local gunybase = 0.5*ylen
				wingguns(gunxbase, gunybase, zbase, gunlen)
			end
		end)
		return xlen, ylen, zlen, zbase
	end

	local function genCylWingSeg(xbase, zlo, zhi)
		local zbase = uniform(zlo, zhi)
		local radius = uniform(0.15, 0.7)
		local xlen = 2*radius
		local ylen = 2*radius
		local zlen = uniform(1.0, 5.0)
		wingcyls(xbase, zbase, radius, zlen)
		return xlen, ylen, zlen, zbase
	end

	local function genWingSeg(xbase, zlo, zhi)
		local segType = multinomial(wingSegTypeWeights)
		local xlen, ylen, zlen, zbase
		if segType == WingSegType.Box then
			xlen, ylen, zlen, zbase = genBoxWingSeg(xbase, zlo, zhi)
		elseif segType == WingSegType.Cylinder then
			xlen, ylen, zlen, zbase = genCylWingSeg(xbase, zlo, zhi)
		end
		return xlen, ylen, zlen, zbase
	end

	local function genWing(xbase, zlo, zhi)
		local i = 0
		repeat
			local xlen, ylen, zlen, zbase = genWingSeg(xbase, zlo, zhi)
			xbase = xbase + xlen
			zlo = zbase - 0.5*zlen
			zhi = zbase + 0.5*zlen
			local keepGenerating = flip(wi(i, 0.6))
			i = i + 1
		until not keepGenerating
	end

	local function genFin(ybase, zlo, zhi, xmax)
		local i = 0
		repeat
			local xlen = uniform(0.5, 1.0) * xmax
			xmax = xlen
			local ylen = uniform(0.1, 0.5)
			local zlen = uniform(0.5, 1.0) * (zhi - zlo)
			local zbase = 0.5*(zlo + zhi)
			box(0.0, ybase + 0.5*ylen, zbase, xlen, ylen, zlen)
			ybase = ybase + ylen
			zlo = zbase - 0.5*zlen
			zhi = zbase + 0.5*zlen
			local keepGenerating = flip(wi(i, 0.2))
			i = i + 1
		until not keepGenerating
	end

	-- What type of body segment to generate
	local BodySegType = 
	{
		Box = 1,
		Cylinder = 2,
		CylCluster = 3
	}
	local segTypeWeights = {}
	for _,_ in pairs(BodySegType) do table.insert(segTypeWeights, 1) end

	local function genBoxBodySeg(rearz, prev, taper)
		local xlen = uniform(1.0, 3.0)
		local ylen = uniform(0.5, 1.0) * xlen
		local zlen
		-- Must be bigger than the previous segment, if the previous
		--   segment was not a box (i.e. was a cylinder-type thing)
		if prev.segType ~= BodySegType.Box then
			xlen = math.max(xlen, prev.xlen)
			ylen = math.max(ylen, prev.ylen)
		end
		if taper then
			zlen = uniform(1.0, 3.0)
			local taper = uniform(0.3, 1.0)
			taperedbox(0.0, 0.0, rearz + 0.5*zlen, xlen, ylen, zlen, taper)
		else
			zlen = uniform(2.0, 5.0)
			box(0.0, 0.0, rearz + 0.5*zlen, xlen, ylen, zlen)
		end
		return xlen, ylen, zlen
	end

	local function genCylinderBodySeg(rearz, prev)
		local minrad = 0.3
		local maxrad = 1.25
		-- Must be smaller than the previous segment, if the previous
		--    segment was a box
		if prev.segType == BodySegType.Box then
			local limitrad = 0.5*math.min(prev.xlen, prev.ylen)
			minrad = 0.4*limitrad
			maxrad = limitrad
		end
		local radius = uniform(minrad, maxrad)
		local xlen = radius*2
		local ylen = radius*2
		local zlen = uniform(2.0, 5.0)
		bodycyl(rearz, radius, zlen)
		return xlen, ylen, zlen
	end

	local function genCylClusterBodySeg(rearz, prev)
		local minrad = 0.5*0.3
		local maxrad = 0.5*1.25
		-- Must be smaller than the previous segment, if the previous
		--    segment was a box
		if prev.segType == BodySegType.Box then
			local limitrad = 0.25*math.min(prev.xlen, prev.ylen)
			minrad = 0.4*limitrad
			maxrad = limitrad
		end
		local radius = uniform(minrad, maxrad)
		local xlen = radius*4
		local ylen = radius*4
		local zlen = uniform(2.0, 5.0)
		bodycylcluster(rearz, radius, zlen)
		return xlen, ylen, zlen
	end

	local function genBodySeg(rearz, prev)
		local xlen
		local ylen
		local zlen
		local segType = multinomial(segTypeWeights)
		if segType == BodySegType.Box then
			xlen, ylen, zlen = genBoxBodySeg(rearz, prev)
		elseif segType == BodySegType.Cylinder then
			xlen, ylen, zlen = genCylinderBodySeg(rearz, prev)
		elseif segType == BodySegType.CylCluster then
			xlen, ylen, zlen = genCylClusterBodySeg(rearz, prev)
		end
		return segType, xlen, ylen, zlen
	end

	local function genShip(rearz)
		local i = 0
		local prev = 
		{
			segType = 0,
			xlen = -1,
			ylen = -1
		}
		repeat
			local segType, xlen, ylen, zlen = genBodySeg(rearz, prev)
			rearz = rearz + zlen
			-- Gen wing?
			local wingprob = wi(i+1, 0.5)
			future.create(function(rearz)
				if flip(wingprob) then
					local xbase = 0.5*xlen
					local zlo = rearz - zlen + 0.5
					local zhi = rearz - 0.5
					genWing(xbase, zlo, zhi)
				end
			end, rearz)
			-- Gen fin?
			local finprob = 0.7
			future.create(function(rearz)
				if flip(finprob) then
					local ybase = 0.5*ylen
					local zlo = rearz - zlen
					local zhi = rearz
					local xmax = 0.6*xlen
					genFin(ybase, zlo, zhi, xmax)
				end
			end, rearz)
			local keepGenerating = flip(wi(i, 0.4))
			prev.segType = segType
			prev.xlen = xlen
			prev.ylen = ylen
			i = i + 1
		until not keepGenerating
		if flip(0.75) then
			-- Generate tapered nose
			genBoxBodySeg(rearz, prev, true)
		end
	end

	return function()
		future.create(genShip, -5.0)
		future.finishall()
	end

end)



