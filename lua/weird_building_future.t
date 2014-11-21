local prob = terralib.require("lua.prob")
local Shapes = terralib.require("shapes")(double)
local Mesh = terralib.require("mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)

local flip = prob.flip
local uniform = prob.uniform
local future = prob.future

---------------------------------------------------------------

return function(makeGeoPrim)

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen)
	end)

	-- Forward declare
	local tower

	local function centralTower(ybot, xmin, xmax, zmin, zmax)
		return tower(ybot, xmin, xmax, zmin, zmax, true, true, true, true)
	end
	local function leftTower(ybot, xmin, xmax, zmin, zmax)
		return tower(ybot, xmin, xmax, zmin, zmax, true, false, true, true)
	end
	local function rightTower(ybot, xmin, xmax, zmin, zmax)
		return tower(ybot, xmin, xmax, zmin, zmax, false, true, true, true)
	end
	local function downTower(ybot, xmin, xmax, zmin, zmax)
		return tower(ybot, xmin, xmax, zmin, zmax, true, true, true, false)
	end
	local function upTower(ybot, xmin, xmax, zmin, zmax)
		return tower(ybot, xmin, xmax, zmin, zmax, true, true, false, true)
	end

	local CONTINUE_PROB = 0.5
	local LEFT_PROB = 0.5
	local RIGHT_PROB = 0.5
	local DOWN_PROB = 0.5
	local UP_PROB = 0.5
	-- local CONTINUE_PROB = 1.0
	-- local LEFT_PROB = 1.0
	-- local RIGHT_PROB = 1.0
	-- local DOWN_PROB = 1.0
	-- local UP_PROB = 1.0

	tower = function(ybot, xmin, xmax, zmin, zmax, leftok, rightok, downok, upok)
		local finished = false
		local iter = 0
		repeat
			local maxwidth = xmax-xmin
			local maxdepth = zmax-zmin
			local width = uniform(0.5*maxwidth, maxwidth)
			local depth = uniform(0.5*maxdepth, maxdepth)
			local height = uniform(1, 3)
			local cx, cz
			if iter == 0 and not leftok then
				cx = xmin + 0.5*width
			elseif iter == 0 and not rightok then
				cx = xmax - 0.5*width
			else
				local xmid = 0.5*(xmin+xmax)
				local halfxremaining = 0.5*(maxwidth-width)
				cx = uniform(xmid-halfxremaining, xmid+halfxremaining)
			end
			if iter == 0 and not downok then
				cz = zmin + 0.5*depth
			elseif iter == 0 and not upok then
				cz = zmax - 0.5*depth
			else
				local zmid = 0.5*(zmin+zmax)
				local halfzremaining = 0.5*(maxdepth-depth)
				cz = uniform(zmid-halfzremaining, zmid+halfzremaining)
			end
			box(cx, ybot + 0.5*height, cz, width, height, depth)
			if iter == 0 then
				if leftok then
					future.create(function(ybot, xmin, xmax, zmin, zmax)
						if flip(LEFT_PROB) then
							leftTower(ybot, xmin, xmax, zmin, zmax)
						end
					end, ybot, cx-0.5*width-maxwidth, cx-0.5*width, zmin, zmax)
				end
				if rightok then
					future.create(function(ybot, xmin, xmax, zmin, zmax)
						if flip(RIGHT_PROB) then
							rightTower(ybot, xmin, xmax, zmin, zmax)
						end
					end, ybot, cx+0.5*width, cx+0.5*width+maxwidth, zmin, zmax)
				end
				if downok then
					future.create(function(ybot, xmin, xmax, zmin, zmax)
						if flip(DOWN_PROB) then
							downTower(ybot, xmin, xmax, zmin, zmax)
						end
					end, ybot, xmin, xmax, cz-0.5*depth-maxdepth, cz-0.5*depth)
				end
				if upok then
					future.create(function(ybot, xmin, xmax, zmin, zmax)
						if flip(UP_PROB) then
							upTower(ybot, xmin, xmax, zmin, zmax)
						end
					end, ybot, xmin, xmax, cz+0.5*depth, cz+0.5*depth+maxdepth)
				end
			end
			ybot = ybot + height
			xmin = cx - 0.5*width
			xmax = cx + 0.5*width
			zmin = cz - 0.5*depth
			zmax = cz + 0.5*depth
			finished = flip(1-CONTINUE_PROB)
			iter = iter + 1
		until finished
	end

	return function()
		future.create(centralTower, 0, -2, 2, -2, 2)
		future.finishall()
	end
end


