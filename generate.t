local Mesh = terralib.require("mesh")
local Vec = terralib.require("linalg.vec")
local Shapes = terralib.require("shapes")
local qs = terralib.require("qs")


-- Main will call the function returned by this module


local p = qs.program(function()
	local Vec3 = Vec(qs.real, 3)
	local Shape = Shapes(qs.real)
	local MeshT = Mesh(qs.real)

	local lerp = macro(function(lo, hi, t)
		return `(1.0-t)*lo + t*hi
	end)
	-- So ranges stay synced during MH proposals.
	local uniform = macro(function(lo, hi)
		return quote
			var u = qs.uniform(0.0, 1.0, {struc=false})
		in
			lerp(lo, hi, u)
		end
	end)

	-- Wings are just a horizontally-symmetric stack of boxes
	local genWing = qs.func(terra(mesh: &MeshT, xbase: qs.real, zlo: qs.real, zhi: qs.real)
		var nboxes = qs.poisson(5) + 1
		for i=0,nboxes do
			var zbase = uniform(zlo, zhi)
			var xlen = uniform(0.25, 2.0)
			var ylen = uniform(0.25, 2.0)
			var zlen = uniform(0.5, 4.0)
			Shape.addBox(mesh, Vec3.create(xbase + 0.5*xlen, 0.0, zbase), xlen, ylen, zlen)
			Shape.addBox(mesh, Vec3.create(-(xbase + 0.5*xlen), 0.0, zbase), xlen, ylen, zlen)
			xbase = xbase + xlen
			zlo = zbase - 0.5*zlen
			zhi = zbase + 0.5*zlen
		end
	end)

	-- The ship body is a forward-protruding stack of boxes
	local genBody = qs.func(terra(mesh: &MeshT, rearz: qs.real)

	end)

	return terra()
		var mesh : MeshT
		mesh:init()
		var xbase = 0.0
		var zlo = -5.0
		var zhi = 5.0
		genWing(&mesh, xbase, zlo, zhi)
		return mesh
	end
end)
local gen = p:compile()
return terra(mesh: &Mesh(double))
	mesh:destruct()
	@mesh = gen()
end

