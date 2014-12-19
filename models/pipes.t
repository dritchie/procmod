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

	local function drop(pt,r) 
		box(pt[1]*r,pt[2]*r,pt[3]*r,r,r,r)
	end

	local roulette = 3./4.
	local branch = 1./3.

	local function genPath(from, to, r)
		
		local done = false
		if (from[1] > to[1]) and (from[2] > to[2]) and (from[3] > to[3]) then 
			for i=1,3 do
				while from[i] > to[i] do
					drop(from,r)
					from[i] = from[i] - 1
				end
			end
			return
		end

		local index  = math.floor(uniform(1,4))
		local length = math.floor(uniform(1,20))
		local dir = flip(roulette)
		local delta 
		if dir then delta = 1 else delta = -1 end
		print(unpack(from),unpack(to),index,length)

		for i=1,length do
			drop(from,r)
			from[index] = from[index] + delta
		end

		genPath(from,to,r)

	end

	return function()
		local r = .01
		repeat
			genPath({-1000,-1000,-1000},{1000,1000,1000},r)
		until flip(branch)
	end

end



