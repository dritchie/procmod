local S = terralib.require("qs.lib.std")
local smc = terralib.require("smc.smc")
local Mesh = terralib.require("mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Shapes = terralib.require("shapes")(double)


-- NOTE: subroutines are currently not allowed, so helper functions must be macros.


terralib.require("qs").initrand()

local spaceship = smc.program(function()

	local lerp = macro(function(lo, hi, t)
		return `(1.0-t)*lo + t*hi
	end)

	local addBox = smc.makeGeoPrim(Shapes.addBox)

	local addWingSeg = smc.makeGeoPrim(terra(mesh: &Mesh, xbase: double, zbase: double, xlen: double, ylen: double, zlen: double)
		Shapes.addBox(mesh, Vec3.create(xbase + 0.5*xlen, 0.0, zbase), xlen, ylen, zlen)
		Shapes.addBox(mesh, Vec3.create(-(xbase + 0.5*xlen), 0.0, zbase), xlen, ylen, zlen)
	end)

	-- Wings are just a horizontally-symmetric stack of boxes
	local genWing = macro(function(mesh, xbase, zlo, zhi)
		return quote
			var nboxes = smc.poisson(5) + 1
			for i=0,nboxes do
				var zbase = smc.uniform(zlo, zhi)
				var xlen = smc.uniform(0.25, 2.0)
				var ylen = smc.uniform(0.25, 1.25)
				var zlen = smc.uniform(0.5, 4.0)
				addWingSeg(mesh, xbase, zbase, xlen, ylen, zlen)
				xbase = xbase + xlen
				zlo = zbase - 0.5*zlen
				zhi = zbase + 0.5*zlen
			end
		end
	end)

	-- Fins protrude up from ship body segments
	local genFin = macro(function(mesh, ybase, zlo, zhi, xmax)
		return quote
			var nboxes = smc.poisson(2) + 1
			for i=0,nboxes do
				var xlen = smc.uniform(0.5, 1.0) * xmax
				xmax = xlen
				var ylen = smc.uniform(0.1, 0.5)
				var zlen = smc.uniform(0.5, 1.0) * (zhi - zlo)
				var zbase = 0.5*(zlo+zhi)
				addBox(mesh, Vec3.create(0.0, ybase + 0.5*ylen, zbase), xlen, ylen, zlen)
				ybase = ybase + ylen
				zlo = zbase - 0.5*zlen
				zhi = zbase + 0.5*zlen
			end
		end
	end)

	-- The ship body is a forward-protruding stack of boxes
	-- Wings and fins are randomly attached to different body segments
	local genShip = macro(function(mesh, rearz)
		return quote
			var nboxes = smc.poisson(4) + 1
			for i=0,nboxes do
				var xlen = smc.uniform(1.0, 3.0)
				var ylen = smc.uniform(0.5, 1.0) * xlen
				var zlen = smc.uniform(2.0, 5.0)
				addBox(mesh, Vec3.create(0.0, 0.0, rearz + 0.5*zlen), xlen, ylen, zlen)
				rearz = rearz + zlen
				-- Gen wing?
				var wingprob = lerp(0.4, 0.0, i/double(nboxes))
				if smc.flip(wingprob) then
					var xbase = 0.5*xlen
					var zlo = rearz - zlen + 0.5
					var zhi = rearz - 0.5
					genWing(mesh, xbase, zlo, zhi)
				end
				-- Gen fin?
				var finprob = 0.7
				if smc.flip(finprob) then
					var ybase = 0.5*ylen
					var zlo = rearz - zlen
					var zhi = rearz
					var xmax = 0.6*xlen
					genFin(mesh, ybase, zlo, zhi, xmax)
				end
			end
		end
	end)

	return terra(mesh: &Mesh)
		var rearz = -5.0
		genShip(mesh, rearz)
	end
end)

local N_PARTICLES = 200
local RECORD_HISTORY = true
local run = smc.run(spaceship)
return terra(generations: &S.Vector(S.Vector(smc.Sample)))
	generations:clear()
	run(spaceship, N_PARTICLES, generations, RECORD_HISTORY, true)
end





