local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("mesh")(double)
local Shapes = terralib.require("shapes")(double)
local BinaryGrid = terralib.require("binaryGrid3d")
local Vec3 = terralib.require("linalg.vec")(double, 3)
local BBox3 = terralib.require("bbox")(Vec3)
local globals = terralib.require("globals")
local distrib = terralib.require("qs.distrib")
local tmath = terralib.require("qs.lib.tmath")

-----------------------------------------------------------------

local Program = {&Mesh} -> {bool}

-----------------------------------------------------------------

local struct Particle(S.Object)
{
	realchoices: S.Vector(double)
	intchoices: S.Vector(int)
	boolchoices: S.Vector(bool)
	realindex: uint
	intindex: uint
	boolindex: uint
	likelihood: double
	mesh: Mesh
	tmpmesh: Mesh
	grid: BinaryGrid
	outsideTris: uint
	geoindex: uint
	stopindex: uint
	finished: bool
}

local gp = global(&Particle, nil)

terra Particle:__init()
	self:initmembers()
	self.stopindex = 0
	self.likelihood = 0.0
	self.outsideTris = 0
	self.finished = false
end

terra Particle:run(p: Program)
	if not self.finished then
		self.realindex = 0
		self.intindex = 0
		self.boolindex = 0
		self.geoindex = 0
		gp = self
		if not p(&self.mesh) then
			self.stopindex = self.stopindex + 1
		else
			self.finished = true
		end
		gp = nil
	end
end

-----------------------------------------------------------------

local tgrid = global(BinaryGrid)
local tbounds = global(BBox3)
local terra initglobals()
	tbounds = globals.targetMesh:bbox()
	tbounds:expand(globals.BOUNDS_EXPAND)
	tgrid:init()
	globals.targetMesh:voxelize(&tgrid, &tbounds, globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
end
initglobals()

-----------------------------------------------------------------

local function makeERP(sampler)
	local T = sampler:gettype().returntype
	local indexq, choiceq
	if T == bool then
		indexq = `gp.boolindex
		choiceq = `gp.boolchoices
	elseif T == int then
		indexq = `gp.intindex
		choiceq = `gp.intchoices
	elseif T == double then
		indexq = `gp.realindex
		choiceq = `gp.realchoices
	else
		error("makeERP: sampler must return bool, int, or double.")
	end
	return macro(function(...)
		local args = {...}
		return quote
			var res: T
			if indexq < choiceq:size() then
				res = choiceq(indexq)
			else
				res = sampler([args])
				choiceq:insert(res)
			end
			indexq = indexq + 1
		in
			res
		end
	end)
end

local flip = makeERP(distrib.bernoulli(double).sample)
local poisson = makeERP(distrib.poisson(double).sample)
local uniform = makeERP(distrib.uniform(double).sample)

-----------------------------------------------------------------

local softeq = macro(function(val, target, s)
	return `[distrib.gaussian(double)].logprob(val, target, s)
end)

local function makeGeoPrim(shapefn)
	return macro(function(mesh, ...)
		local args = {...}
		return quote
			if mesh ~= &gp.mesh then
				shapefn(mesh, [args])
			else
				if gp.geoindex == gp.stopindex then
					gp.tmpmesh:clear()
					shapefn(&gp.tmpmesh, [args])

					-- If likelihood is already -inf, then leave it that way
					-- (With resampling enabled, this shouldn't happen--we should always discard these particles)
					if gp.likelihood ~= [-math.huge] then
						-- If self-intersections, then set likelihood to -inf
						if gp.tmpmesh:intersects(mesh) then
							gp.likelihood = [-math.huge]
						-- Otherwise, do the voxel stuff
						else
							gp.grid:resize(tgrid.rows, tgrid.cols, tgrid.slices)
							var n = gp.tmpmesh:voxelize(&gp.grid, &tbounds, globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
							gp.outsideTris = gp.outsideTris + n
							var numTris = mesh:numTris() + gp.tmpmesh:numTris()
							var percentSame = gp.grid:percentCellsEqual(&tgrid)
							var percentOutside = double(gp.outsideTris) / numTris
							gp.likelihood = softeq(percentSame, 1.0, 0.01) + softeq(percentOutside, 0.0, 0.01)
						end
					end

					mesh:append(&gp.tmpmesh)

					-- TODO: Only works if Program has no subroutines. Replace with setjmp/longjmp?
					--    (Note that this will also require me to explicitly destruct tmpmesh, since longjmp
					--     won't invoke the deferred destruct statements.)
					--    (Also, any other heap allocated memory used by the program will leak...)
					-- ALTERNATIVELY: could just run the program through to completion...
					return false
				else
					gp.geoindex = gp.geoindex + 1
				end
			end
		end
	end)
end

local addBox = makeGeoPrim(Shapes.addBox)

-----------------------------------------------------------------

-- Need to use Quicksand's Sample type for compatibility with other code
local Sample = terralib.require("qs").Sample(Mesh)

local terra run(prog: Program, nParticles: uint, outsamps: &S.Vector(Sample))
	-- Init particles
	var particles = [S.Vector(Particle)].salloc():init()
	var nextParticles = [S.Vector(Particle)].salloc():init()
	var weights = [S.Vector(double)].salloc():init()
	for i=0,nParticles do
		var p = particles:insert()
		p:init()
		weights:insert(0.0)
	end
	-- Run particles step-by-step (read: geo prim by geo prim)
	--   until all particles are finished
	repeat
		var allParticlesFinished = true
		for i=0,particles:size() do
			var p = particles:get(i)
			p:run(prog)
			allParticlesFinished = allParticlesFinished and p.finished
			weights(i) = tmath.exp(p.likelihood)
		end
		-- -- Importance resampling
		-- for i=0,nParticles do
		-- 	var index = [distrib.categorical_vector(double)].sample(weights)
		-- 	var newp = nextParticles:insert()
		-- 	newp:copy(particles:get(index))
		-- end
		-- var tmp = particles
		-- particles = nextParticles
		-- nextParticles = tmp
		-- nextParticles:clear()
	until allParticlesFinished
	-- Fill in the list of output samples
	for p in particles do
		var s = outsamps:insert()
		s.value:copy(&p.mesh)
		s.logprob = p.likelihood
	end
end

-----------------------------------------------------------------

return
{
	Sample = Sample,
	flip = flip,
	poisson = poisson,
	uniform = uniform,
	addBox = addBox,
	run = run
}





