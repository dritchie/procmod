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


	local roulette = 1./6.
	local ratio = 1./2.

	local function genCube(xc, yc, zc, r, p, gen)
		print(xc, yc, zc, r)
		local pn = {true,true,true,true,true,true}
		local xn = {1,0,0,-1,0,0}
		local yn = {0,1,0,0,-1,0}
		local zn = {0,0,1,0,0,-1}
		box(xc,yc,zc,2*r,2*r,2*r)
		-- local counter = 0
		-- local N = 1000
		-- for j=1,N do
		-- 	if flip(roulette) then counter = counter + 1 end
		-- end
		-- print("100 trials: ", counter / N)
		if gen < 3 then 
			for i=1,6 do 
				pn[i] = false
				if i > 1 then pn[i-1] = true end
				if (flip(1-roulette) and p[i]) and r > .001 then 
					genCube(xc+xn[i]*r*(1+ratio), yc+yn[i]*r*(1+ratio), zc+zn[i]*r*(1+ratio), r*ratio, pn, gen + 1)
				end
			end
		end
	end

	return function()
		local p = {true,true,true,true,true,true}
		genCube(0,0,0,1,p,0)
	end

end)



