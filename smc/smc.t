local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("mesh")(double)
local BinaryGrid = terralib.require("binaryGrid3d")
local Vec3 = terralib.require("linalg.vec")(double, 3)
local BBox3 = terralib.require("bbox")(Vec3)
local globals = terralib.require("globals")
local distrib = terralib.require("qs.distrib")
local tmath = terralib.require("qs.lib.tmath")

-----------------------------------------------------------------

-- Different strategies for implementing SMC inference semantics
local Impl = 
{
	-- Early out by inserting a 'return' statement.
	-- Does not work if the program has subroutines, but will fire deferred destructors
	RETURN = 0,
	-- Early out by longjmp-ing out of the program.
	-- Works for any program, but will *not* fire deferred destructors, so memory may leak
	--    (unless we provide a special managed 'pool' for user-allocated memory).
	LONGJMP = 1,
	-- Run the program through to completion every time, just don't do any random choices/factors
	--    past the current 'stop' point.
	-- Works for any program and will not leak, but might be noticably slower.
	FULLRUN = 2
}

local IMPLEMENTATION = Impl.RETURN

local C
if IMPLEMENTATION == Impl.LONGJMP then
	C = terralib.includecstring [[
	#include <setjmp.h>
	]]
end

-----------------------------------------------------------------

local Program = {&Mesh} -> {}

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
if IMPLEMENTATION == Impl.LONGJMP then Particle.entries:insert({field="jumpEnv", type=C.jmp_buf}) end

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

		-- How we run the program depends on the implementation strategy
		escape
			if IMPLEMENTATION == Impl.RETURN then
				emit quote
					p(&self.mesh)
					if self.geoindex < self.stopindex then
						self.finished = true
					else
						self.stopindex = self.stopindex + 1
					end
				end
			elseif IMPLEMENTATION == Impl.LONGJMP then
				emit quote
					if C.setjmp(self.jumpEnv) == 0 then
						p(&self.mesh)
						self.finished = true
					end
					self.stopindex = self.stopindex + 1
				end
			elseif IMPLEMENTATION == Impl.FULLRUN then
				-- TODO: FILL IN
			end
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

					-- What we do next depends on the implementation strategy
					escape
						if IMPLEMENTATION == Impl.RETURN then
							emit quote
								return
							end
						elseif IMPLEMENTATION == Impl.LONGJMP then
							emit quote
								C.longjmp(gp.jumpEnv, 1)
							end
						elseif IMPLEMENTATION == Impl.FULLRUN then
							-- TODO: FILL IN
						end
					end

				else
					gp.geoindex = gp.geoindex + 1
				end
			end
		end
	end)
end

-----------------------------------------------------------------

-- Need to use Quicksand's Sample type for compatibility with other code
local Sample = terralib.require("qs").Sample(Mesh)
local Samples = S.Vector(Sample)
local Generations = S.Vector(Samples)
local Particles = S.Vector(Particle)

local flushstdout = terralib.includecstring([[
#include <stdio.h>
inline void flushstdout() { fflush(stdout); }
]]).flushstdout

local terra recordCurrMeshes(particles: &Particles, generations: &Generations)
	var samps = generations:insert()
	samps:init()
	for p in particles do
		var s = samps:insert()
		s.value:copy(&p.mesh)
		s.logprob = p.likelihood
	end
end

local terra run(prog: Program, nParticles: uint, outgenerations: &Generations, recordHistory: bool, verbose: bool)
	-- Init particles
	var particles = Particles.salloc():init()
	var nextParticles = Particles.salloc():init()
	var weights = [S.Vector(double)].salloc():init()
	for i=0,nParticles do
		var p = particles:insert()
		p:init()
		weights:insert(0.0)
	end
	-- Run particles step-by-step (read: geo prim by geo prim)
	--   until all particles are finished
	var generation = 0
	repeat
		var numFinished = 0
		for i=0,particles:size() do
			var p = particles:get(i)
			p:run(prog)
			if p.finished then
				numFinished = numFinished + 1
			end
			weights(i) = tmath.exp(p.likelihood)
		end
		var allParticlesFinished = (numFinished == nParticles)
		if verbose then
			S.printf(" Generation %u: Finished %u/%u particles.\r",
				generation, numFinished, nParticles)
			flushstdout()
		end
		generation = generation + 1
		-- Importance resampling
		for i=0,nParticles do
			var index = [distrib.categorical_vector(double)].sample(weights)
			var newp = nextParticles:insert()
			newp:copy(particles:get(index))
		end
		-- Record meshes *BEFORE* resampling
		if recordHistory then
			recordCurrMeshes(particles, outgenerations)
		end
		var tmp = particles
		particles = nextParticles
		nextParticles = tmp
		nextParticles:clear()
		-- Record meshes *AFTER* resampling
		if recordHistory or allParticlesFinished then
			recordCurrMeshes(particles, outgenerations)
		end
	until allParticlesFinished
	if verbose then S.printf("\n") end
end

-----------------------------------------------------------------

return
{
	Sample = Sample,
	flip = flip,
	poisson = poisson,
	uniform = uniform,
	makeGeoPrim = makeGeoPrim,
	run = run
}





