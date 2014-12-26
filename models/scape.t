local S = terralib.require("qs.lib.std")
local prob = terralib.require("prob.prob")
local Shapes = terralib.require("geometry.shapes")(double)
local Mesh = terralib.require("geometry.mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)

local flip = prob.flip
local uniform = prob.uniform
local future = prob.future

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	local box = makeGeoPrim(terra(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen)
	end)

	local quad = makeGeoPrim(terra(mesh: &Mesh, x1: double, y1: double, z1: double, 
												x2: double, y2: double, z2: double, 
												x3: double, y3: double, z3: double, 
												x4: double, y4: double, z4: double)
		Shapes.addQuad(mesh, Vec3.create(x1, y1, z1),
							 Vec3.create(x2, y2, z2),
							 Vec3.create(x3, y3, z3),
							 Vec3.create(x4, y4, z4))
	end)

	local mapscale = 1;
	local function putquad(p1,p2,p3,p4)
		quad(p1[1]*mapscale,p1[2]*mapscale,p1[3]*mapscale,p2[1]*mapscale,p2[2]*mapscale,p2[3]*mapscale,
		     p3[1]*mapscale,p3[2]*mapscale,p3[3]*mapscale,p4[1]*mapscale,p4[2]*mapscale,p4[3]*mapscale)
	end

	local function midpt(p1,p2) 
		return {.5*(p1[1]+p2[1]),.5*(p1[2]+p2[2]),.5*(p1[3]+p2[3])}
	end

	local function zshift(p,d) 
		p[3] = p[3]+d
		return p
	end

	local function scape(ll, ul, lr, ur, scale)
		if scale == 1 then
			putquad(ll,ul,ur,lr)
			return
		end

		local disp = scale * uniform(-1,1)
		local c = midpt(midpt(ll,ul),midpt(lr,ur))
		c[3] = c[3] + disp

		local mnoise = 0;
		local grid = {{ll,zshift(midpt(ll,lr),uniform(-mnoise,mnoise)*scale),lr},
					  {zshift(midpt(ll,ul),uniform(-mnoise,mnoise)*scale),c,zshift(midpt(lr,ur),uniform(-mnoise,mnoise)*scale)},
					  {ul,zshift(midpt(ul,ur),uniform(-mnoise,mnoise)*scale),ur}}

		scale = scale / 2
		for x=0,1 do
			for y=0,1 do
				scape(grid[1+x][1+y],grid[2+x][1+y],grid[1+x][2+y],grid[2+x][2+y],scale)
			end
		end


	end


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
		local scale = 32 
		scape({-scale,-scale,scale*uniform(-.5,.5)},
			  {-scale,scale,scale*uniform(-.5,.5)},
			  {scale,-scale,scale*uniform(-.5,.5)},
			  {scale,scale,scale*uniform(-.5,.5)},
			  scale)
	end

end)



