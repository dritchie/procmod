local S = require("qs.lib.std")
local prob = require("prob.prob")
local Shapes = require("geometry.shapes")(double)
local Mesh = require("geometry.mesh")(double)
local Vec3 = require("linalg.vec")(double, 3)

local flip = prob.flip
local uniform = prob.uniform
local future = prob.future

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen)
	end)

	local function drop(pt,delta,r) 
		box(pt[1]*r,pt[2]*r,pt[3]*r,delta[1]*r,delta[2]*r,delta[3]*r)
	end

	local thickness = .01
	local function drop_pipe(pt,length,dir)
		local newpt = {0,0,0}
		local shiftpt = {0,0,0}
		for k=1,3 do 
			newpt[k] = pt[k] + dir[k]*length 
			shiftpt[k] = pt[k] + dir[k]
		end 

		local center = {0,0,0}
		for k=1,3 do center[k] = .5*(shiftpt[k]+newpt[k]) end
		local delta = {1,1,1}
		for k=1,3 do 
			if not (dir[k] == 0) then delta[k] = length end
		end

		drop(center,delta,thickness)
		return newpt
	end

	local root_length = 20
	local branch_mult = .5

	local dirs = 6
	local function dir(i)
		local ret = {0,0,0}
		if i <= 3 then 
			ret[i] = 1
		else
			ret[i-3] = -1 
		end
		return ret
	end
	local function randdiri() 
		return math.floor(uniform(1,7))
	end

	local function fake_pois(lambda)
		local summand = math.exp(-lambda)
		local sum = summand
		local i = 0
		local u = uniform(0,1)
		while u > sum do
			i = i + 1
			summand = summand * lambda / i
			sum = sum + summand
		end
		return i
	end

	local function genBranches(origin, length_factor, notdir) 
		while flip(.9) do
			local length = fake_pois(length_factor)
			if length <= 3 then return end
			local diri
			repeat diri = randdiri() until diri ~= notdir
			origin = drop_pipe(origin,length,dir(diri))
			notdir = (diri+3)%6
			genBranches(origin, length_factor * branch_mult, notdir)
		end
	end

	return function()
		
		genBranches({0,0,0}, root_length, -1)

	end

end)



