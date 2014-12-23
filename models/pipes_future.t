local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)

local flip = prob.flip
local uniform = prob.uniform
local future = prob.future

---------------------------------------------------------------

return function(makeGeoPrim)

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen)
	end)

	local function drop(pt,delta,r) 
		box(pt[1]*r,pt[2]*r,pt[3]*r,delta[1]*r,delta[2]*r,delta[3]*r)
	end

	local thickness = .2
	local function drop_pipe(pt,length,dir)
		local newpt = {0,0,0}
		for k=1,3 do newpt[k] = pt[k] + dir[k]*length end 

		local center = {0,0,0}
		for k=1,3 do center[k] = .5*(pt[k]+newpt[k]) end
		local delta = {1,1,1}
		for k=1,3 do 
			if not (dir[k] == 0) then delta[k] = length+1 end
		end

		drop(center,delta,thickness)
		return newpt
	end

	local root_length = 10
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
	local function randdir() 
		return dir(math.floor(uniform(1,7)))
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

	local function genBranches(origin, length_factor) 
		future.create(function(origin,length_factor)

			local length = fake_pois(length_factor)
			if length <= 1 then return end
			origin = drop_pipe(origin,length,randdir())
			if flip(.5) then future.create(genBranches, origin, length_factor * branch_mult) end
			if flip(.9) then future.create(genBranches, origin, length_factor) end

		end, origin,length_factor)
	end

	return function()
		
		future.create(genBranches, {0,0,0}, root_length)
		future.finishall()

	end


	--------


	-- local function genBranches(origin, length_factor) 
	-- 	for dummy=1,100 do
	-- 		future.create(function(origin,length_factor) 
	-- 			local length = fake_pois(length_factor)
	-- 			if length == 0 then return end
	-- 			origin = drop_pipe(origin,length,randdir())
	-- 			--future.create(function() genBranches(origin, length_factor * branch_mult) end)
	-- 			end, origin, length_factor)
	-- 	end
	-- end


end



