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

	local function genPath(xc, yc, zc, r, p, gen, length, dx, dy, dz)
		if gen > 1000 then return end
		-- print(xc, yc, zc, gen, unpack(p))
		local pn = {true,true,true,true,true,true}
		local xn = {1,0,0,-1,0,0}
		local yn = {0,1,0,0,-1,0}
		local zn = {0,0,1,0,0,-1}

		local pos = {xc,yc,zc}
		local j 
		for j = 1,length do
			pos[1] = pos[1]+dx
			pos[2] = pos[2]+dy
			pos[3] = pos[3]+dz
			box(pos[1],pos[2],pos[3],2*r,2*r,2*r)
		end

		local l = uniform(1,10)
		local i = math.floor(uniform(1,6))
		if not p[i] then i = 6 end
		pn[(i+3)%6] = false
		genPath(pos[1],pos[2],pos[3], r, pn, gen + 1, l, xn[i]*r*2, yn[i]*r*2, zn[i]*r*2)


	end

	return function()
		local p = {true,true,true,true,true,true}
		local r = .1
		genPath(0,0,0,r,p,0,1,r*2,0,0)
	end

end



