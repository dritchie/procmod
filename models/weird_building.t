local S = terralib.require("qs.lib.std")
local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)

local flip = prob.flip
local uniform = prob.uniform

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen)
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

	local function spreadProb(depth)
		return math.exp(-0.4*depth)
	end

	tower = function(depth, ybot, xmin, xmax, zmin, zmax, leftok, rightok, downok, upok)
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
					if flip(spreadProb(depth)) then
						leftTower(depth+1, ybot, xmin, xmax, zmin, zmax)
					end
				end
				if rightok then
					if flip(spreadProb(depth)) then
						rightTower(depth+1, ybot, xmin, xmax, zmin, zmax)
					end
				end
				if downok then
					if flip(spreadProb(depth)) then
						downTower(depth+1, ybot, xmin, xmax, zmin, zmax)
					end
				end
				if upok then
					if flip(spreadProb(depth)) then
						upTower(depth+1, ybot, xmin, xmax, zmin, zmax)
					end
				end
			end
			ybot = ybot + height
			xmin = cx - 0.5*width
			xmax = cx + 0.5*width
			zmin = cz - 0.5*depth
			zmax = cz + 0.5*depth
			finished = flip(1-stackProb(iter))
			iter = iter + 1
		until finished
	end

	return function()
		centralTower(0, 0, -2, 2, -2, 2)
	end
end)


