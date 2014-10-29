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

local softeq = macro(function(val, target, s)
	return `[distrib.gaussian(double)].logprob(val, target, s)
end)

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)

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

local currentlyCompilingProgram = nil

local smc_mt = {}

-- Abstracts an SMC-able program.
local function program(fn)
	fn = S.memoize(fn)
	local obj = {
		compile = S.memoize(function(self)
			local tfn = fn()
			-- Ensure program is compiled whenever we access it,
			--    to make sure that the correct macros get used, etc.
			currentlyCompilingProgram = self
			tfn:compile(function()
				currentlyCompilingProgram = nil
				self.compiled = true
			end)
			return tfn
		end)
	}
	setmetatable(obj, smc_mt)
	return obj
end

local function isSMCProgram(P)
	return getmetatable(P) == smc_mt
end

-----------------------------------------------------------------

local _Particle = S.memoize(function(P)

	assert(isSMCProgram(P), "Particle - P is not an smc.program")
	local p = P:compile()

	local struct Particle(S.Object)
	{
		realchoices: S.Vector(double)
		intchoices: S.Vector(int)
		boolchoices: S.Vector(bool)
		realindex: uint
		intindex: uint
		boolindex: uint
		mesh: Mesh
		tmpmesh: Mesh
		hasSelfIntersections: bool
		grid: BinaryGrid
		outsideTris: uint
		geoindex: uint
		stopindex: uint
		finished: bool
		likelihood: double
	}
	if IMPLEMENTATION == Impl.LONGJMP then Particle.entries:insert({field="jumpEnv", type=C.jmp_buf}) end

	terra Particle:__init()
		self:initmembers()
		self.stopindex = 0
		self.likelihood = 0.0
		self.outsideTris = 0
		self.finished = false
		self.hasSelfIntersections = false
	end

	local USE_WEIGHT_ANNEALING = false
	local ANNEAL_RATE = 0.05
	terra Particle:score(generation: uint)
		-- If we have self-intersections, then score is -inf
		if self.hasSelfIntersections then
			self.likelihood = [-math.huge]
		else
			var percentSame : double
			escape
				if USE_WEIGHT_ANNEALING then
					emit quote
						-- Weight empty cells more than filled cells in the early going, decay
						--    toward default weighting over time.
						-- TODO: Need a final resampling step that uses the final, 'true' weighting?
						var n = tgrid:numCellsPadded()
						var pe = tgrid:numEmptyCellsPadded() / double(n)
						-- var w = pe
						var w = (1.0-pe)*tmath.exp(-ANNEAL_RATE*generation) + pe
						percentSame = lerp(tgrid:percentFilledCellsEqual(&self.grid),
										   tgrid:percentEmptyCellsEqual(&self.grid),
										   w)
					end
				else
					emit quote
						-- Original version that doesn't separate empty from filled.
						percentSame = tgrid:percentCellsEqual(&self.grid)
					end
				end
			end

			var percentOutside = double(self.outsideTris) / self.mesh:numTris()

			self.likelihood = softeq(percentSame, 1.0, 0.01) + softeq(percentOutside, 0.0, 0.01)
		end
	end

	local globalParticle = global(&Particle, 0)
	Particle.globalParticle = globalParticle

	terra Particle:run()
		if not self.finished then
			self.realindex = 0
			self.intindex = 0
			self.boolindex = 0
			self.geoindex = 0

			globalParticle = self

			-- How we run the program depends on the implementation strategy
			escape
				if IMPLEMENTATION == Impl.RETURN or IMPLEMENTATION == Impl.FULLRUN then
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
				end
			end

			globalParticle = nil
		end
	end

	return Particle

end)
-- Much like Quicksand's RandExecTrace type, we must compile the program before we
--    enter the memoized type constructor, otherwise we'll end up recursively entering
--    the type constructor twice, which results in code from two different instantiations
--    of the same type floating around in the system. Bad times.
local function Particle(P)
	P:compile()
	return _Particle(P)
end

-----------------------------------------------------------------

-- Retrieves the global particle for the currently compiling program
local function globalParticle()
	assert(currentlyCompilingProgram ~= nil)
	return Particle(currentlyCompilingProgram).globalParticle
end

-----------------------------------------------------------------

local function makeERP(sampler)
	local T = sampler:gettype().returntype
	return macro(function(...)
		local args = {...}
		local gp = globalParticle()
		-- Figure out which vector of random choices we should look into
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
		return quote
			var res: T
			if gp.geoindex > gp.stopindex then
				-- The only time this happens is if we're in FULLRUN mode and we're just
				--    finishing out the program. In this case, just sample something but
				--    don't record it--we haven't "officially" gotten to this random choice yet
				-- TODO: Try to sample values that will lead to shorter completion runs
				--    (perhaps by providing domains/bounds?)
				res = sampler([args])
			elseif indexq < choiceq:size() then
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
local uniformInt = makeERP(
	terra(lo: int, hi: int)
		return int([distrib.uniform(double)].sample(lo, hi))
	end
)

-----------------------------------------------------------------

local function makeGeoPrim(shapefn)
	return macro(function(mesh, ...)
		local args = {...}
		local gp = globalParticle()
		return quote
			if mesh ~= &gp.mesh then
				shapefn(mesh, [args])
			else
				-- Skip all geo primitives up until the last one for this run.
				if gp.geoindex == gp.stopindex then
					gp.tmpmesh:clear()
					shapefn(&gp.tmpmesh, [args])

					-- Record whether we have any new self-intersections
					-- If not, then go on to voxelize
					gp.hasSelfIntersections = gp.hasSelfIntersections or gp.tmpmesh:intersects(mesh)
					if not gp.hasSelfIntersections then
						gp.grid:resize(tgrid.rows, tgrid.cols, tgrid.slices)
						var nout = gp.tmpmesh:voxelize(&gp.grid, &tbounds, globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
						gp.outsideTris = gp.outsideTris + nout
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
							emit quote
								gp.geoindex = gp.geoindex + 1
							end
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

local C = terralib.includecstring [[
#include <stdio.h>
inline void flushstdout() { fflush(stdout); }
#include <float.h>
inline double getdblmin() { return DBL_MIN; }
]]

local flushstdout = C.flushstdout
local LOG_DBL_MIN = tmath.log(C.getdblmin())

local run = S.memoize(function(P)

	assert(isSMCProgram(P))

	local Particles = S.Vector(Particle(P))

	local terra recordCurrMeshes(particles: &Particles, generations: &Generations)
		var samps = generations:insert()
		samps:init()
		for p in particles do
			var s = samps:insert()
			s.value:copy(&p.mesh)
			s.logprob = p.likelihood
		end
	end

	return terra(nParticles: uint, outgenerations: &Generations, recordHistory: bool, verbose: bool)
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
			var minFiniteScore = [math.huge]
			for i=0,particles:size() do
				var p = particles:get(i)
				p:run()
				p:score(generation)
				if p.finished then
					numFinished = numFinished + 1
				end
				weights(i) = p.likelihood
				if weights(i) ~= [-math.huge] and weights(i) < minFiniteScore then
					minFiniteScore = weights(i)
				end
			end
			var allParticlesFinished = (numFinished == nParticles)
			-- Exponentiate the weights to bring them out of log-space
			-- (Avoid underflow by adding a constant to all scores that
			--  ensures that when we exp them, they will all be representable
			--  doubles).
			var underflowCorrect = 0.0
			if minFiniteScore < LOG_DBL_MIN then
				underflowCorrect = LOG_DBL_MIN - minFiniteScore
			end
			for w in weights do
				w = tmath.exp(w + underflowCorrect)
			end
			if verbose then
				S.printf(" Generation %u: Finished %u/%u particles.\r",
					generation, numFinished, nParticles)
				flushstdout()
			end
			generation = generation + 1
			-- Importance resampling
			-- S.printf("\nWeights: ")
			for i=0,nParticles do
				-- S.printf("  %g", weights(i))
				var index = [distrib.categorical_vector(double)].sample(weights)
				var newp = nextParticles:insert()
				newp:copy(particles:get(index))
			end
			-- S.printf("\n")
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
end)

-----------------------------------------------------------------

return
{
	program = program,
	Sample = Sample,
	flip = flip,
	poisson = poisson,
	uniform = uniform,
	uniformInt = uniformInt,
	makeGeoPrim = makeGeoPrim,
	run = run
}





