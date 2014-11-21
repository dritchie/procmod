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


	local roulette = 1./3.

	local function genPath(xc, yc, zc, r, p, gen)
		if gen > 100 then return end
		print(xc, yc, zc, gen, unpack(p))
		local pn = {true,true,true,true,true,true}
		local xn = {1,0,0,-1,0,0}
		local yn = {0,1,0,0,-1,0}
		local zn = {0,0,1,0,0,-1}
		box(xc,yc,zc,2*r,2*r,2*r)

		local i = math.floor(uniform(1,6))
		if not p[i] then i = 6 end
		pn[(i+3)%6] = false
		genPath(xc+xn[i]*r*2, yc+yn[i]*r*2, zc+zn[i]*r*2, r, pn, gen + 1)


	end

	return function()
		local p = {true,true,true,true,true,true}
		genPath(0,0,0,.1,p,0)
	end

end



