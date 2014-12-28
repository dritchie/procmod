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

	local box = makeGeoPrim(terra(mesh: &Mesh, rotamt: double, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		var xform = Mat4.translate(cx, cy, cz) * Mat4.rotateY(rotamt)
		Shapes.addBoxTransformed(mesh, &xform, Vec3.create(0.0), xlen, ylen, zlen)
	end)

	local vcyl = makeGeoPrim(terra(mesh: &Mesh, bcx: double, bcy: double, bcz: double, height: double, radius: double, n: uint)
		Shapes.addCylinder(mesh, Vec3.create(bcx, bcy, bcz), height, radius, n)
	end)

	local hcyl = makeGeoPrim(terra(mesh: &Mesh, rotamt: double, bcx: double, bcy: double, bcz: double, height: double, radius: double, n: uint)
		var xform = Mat4.translate(bcx, bcy, bcz) * Mat4.rotateY(rotamt) * Mat4.translate(0.0, radius, 0.0) * Mat4.rotateX([math.pi/2]) * Mat4.translate(0.0, -0.5*height, 0.0)
		Shapes.addCylinderTransformed(mesh, &xform, Vec3.create(0.0), height, radius, n)
	end)

	local ShapeType = {
		Box = false,
		Cylinder = true
	}

	local CylinderOrientation = {
		Vertical = false,
		Horizontal = true
	}

	local n = geoRes
	local coord_min = -9
	local coord_max = 9
	local box_dim_min = 0.25
	local box_dim_max = 2.0
	local cyl_height_min = 0.25
	local cyl_height_max = 4.0
	local cyl_rad_min = 0.25
	local cyl_rad_max = 1.0

	local function wi(i, w)
		return math.exp(-w*i)
	end

	return function()
		local iters = 0
		repeat
			local stype = flip(0.5)
			if stype == ShapeType.Box then
				local xlen = uniform(box_dim_min, box_dim_max)
				local ylen = uniform(box_dim_min, box_dim_max)
				local zlen = uniform(box_dim_min, box_dim_max)
				local cx = uniform(coord_min, coord_max)
				local cz = uniform(coord_min, coord_max)
				local cy = 0.5*ylen
				local rotamt = uniform(0.0, 2*math.pi)
				box(rotamt, cx, cy, cz, xlen, ylen, zlen)
			elseif stype == ShapeType.Cylinder then
				local height = uniform(cyl_height_min, cyl_height_max)
				local radius = uniform(cyl_rad_min, cyl_rad_max)
				local bcx = uniform(coord_min, coord_max)
				local bcz = uniform(coord_min, coord_max)
				local bcy = 0.0
				local orient = flip(0.5)
				if orient == CylinderOrientation.Vertical then
					vcyl(bcx, bcy, bcz, height, radius, n)
				elseif orient == CylinderOrientation.Horizontal then
					local rotamt = uniform(0.0, 2*math.pi)
					hcyl(rotamt, bcx, bcy, bcz, height, radius, n)
				end
			end
			local keepgoing = flip(wi(iters, 0.0075)) 
			iters = iters + 1
		until not keepgoing
	end

end)



