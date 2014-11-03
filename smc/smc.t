local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("mesh")(double)
local BinaryGrid = terralib.require("binaryGrid3d")
local Vec3 = terralib.require("linalg.vec")(double, 3)
local BBox3 = terralib.require("bbox")(Vec3)
local globals = terralib.require("globals")
local distrib = terralib.require("qs.distrib")
local tmath = terralib.require("qs.lib.tmath")

-- Quicksand interop stuff
local qs = terralib.require("qs")
local trace = terralib.require("qs.trace")

local C = terralib.includecstring [[
#include <setjmp.h>
]]

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

-- Different particle resampling algorithms
local Resample = 
{
	MULTINOMIAL = 0,
	STRATIFIED = 1,
	SYSTEMATIC = 2,
	REJECTION = 3,
	METROPOLIS = 4
}

-- Parameters that control the overall SMC behavior
local IMPLEMENTATION = Impl.RETURN
local VOXEL_FACTOR_WEIGHT = 0.01
local OUTSIDE_FACTOR_WEIGHT = 0.01
local USE_WEIGHT_ANNEALING = false
local ANNEAL_RATE = 0.05
local USE_QUICKSAND_TRACE = false
local RESAMPLING_ALG = Resample.MULTINOMIAL
local METROPOLIS_RESAMPLE_EPS = 0.001

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

-- Abstracts an SMC-able program.
local currentlyCompilingProgram = nil
local smc_mt = {}
local function program(fn)
	if USE_QUICKSAND_TRACE then
		fn = qs.program(fn)
	else
		fn = S.memoize(fn)
	end
	local obj = {
		compile = S.memoize(function(self)
			currentlyCompilingProgram = self
			local tfn
			if USE_QUICKSAND_TRACE then
				tfn = fn:compile()
			else
				tfn = fn()
			end
			-- In the Quicksand version, tfn is actually already being compiled. But we still
			--    need to register the continuation that sets currentlyCompilingProgram back to nil.
			tfn:compile(function()
				currentlyCompilingProgram = nil
			end)
			return tfn
		end)
	}
	if USE_QUICKSAND_TRACE then
		obj.__qsprog = fn
		obj.qsprog = function(self) return obj.__qsprog end
	end
	setmetatable(obj, smc_mt)
	return obj
end

local function isSMCProgram(P)
	return getmetatable(P) == smc_mt
end

-- Forward declaration (see 'main' below)
local isSMCMainFunction

-----------------------------------------------------------------

-- A simple version of a probabilistic program trace that does not
--    record any structural information--just stores flat lists that
--    can be consulted to re-execute a program in a particular way.
-- MCMC is, generally, not possible with this representation.
local _SimpleTrace = S.memoize(function(P)

	assert(isSMCProgram(P), "SimpleTrace - program P is not an smc.program")
	local p = P:compile()
	assert(isSMCMainFunction(p), "SimpleTrace - program P must return an smc.main function")

	local struct SimpleTrace(S.Object)
	{
		realchoices: S.Vector(double)
		intchoices: S.Vector(int)
		boolchoices: S.Vector(bool)
		realindex: uint
		intindex: uint
		boolindex: uint
	}

	-- Global trace (analagous to Quicksand's)
	local globalTrace = global(&SimpleTrace, 0)
	SimpleTrace.globalTrace = globalTrace

	-- Stand-in for qs RandExecTrace update method
	-- The bool arg isn't used, but is needed for type signature compatibility
	terra SimpleTrace:update(canStructureChange: bool)
		self.realindex = 0
		self.intindex = 0
		self.boolindex = 0
		globalTrace = self
		p()
		globalTrace = nil
	end

	return SimpleTrace
end)
-- Much like Quicksand's RandExecTrace type, we must compile the program before we
--    enter the memoized type constructor, otherwise we'll end up recursively entering
--    the type constructor twice, which results in code from two different instantiations
--    of the same type floating around in the system. Bad times.
local function SimpleTrace(P)
	P:compile()
	return _SimpleTrace(P)
end

-- Retrieve the global trace for the currently compiling program
local function globalTrace()
	assert(currentlyCompilingProgram ~= nil)
	return SimpleTrace(currentlyCompilingProgram).globalTrace
end

-----------------------------------------------------------------

-- Wrapper around the Quicksand version of trace that is made safe for use with SMC.
local function QSTrace(P)
	P:compile()
	return trace.RandExecTrace(P:qsprog(), double)
end


-----------------------------------------------------------------

-- Simple ERP creation for when we're not using Quicksand traces
local function makeERP(sampler)
	local T = sampler:gettype().returntype
	return macro(function(...)
		local args = {...}
		local gt = globalTrace()
		-- Figure out which vector of random choices we should look into
		local indexq, choiceq
		if T == bool then
			indexq = `gt.boolindex
			choiceq = `gt.boolchoices
		elseif T == int then
			indexq = `gt.intindex
			choiceq = `gt.intchoices
		elseif T == double then
			indexq = `gt.realindex
			choiceq = `gt.realchoices
		else
			error("makeERP: sampler must return bool, int, or double.")
		end
		return quote
			var res: T
			-- If global trace is nil, just sample a value
			if gt == nil then
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

local flip
local poisson
local uniform
local uniformInt
if USE_QUICKSAND_TRACE then
	flip = qs.flip
	poisson = qs.poisson
	uniform = qs.uniform
	uniformInt = qs.uniformInt
else
	flip = makeERP(distrib.bernoulli(double).sample)
	poisson = makeERP(distrib.poisson(double).sample)
	uniform = makeERP(distrib.uniform(double).sample)
	uniformInt = makeERP(
		terra(lo: int, hi: int)
			return int([distrib.uniform(double)].sample(lo, hi))
		end
	)
end

-----------------------------------------------------------------

local Particle = S.memoize(function(Trace)

	local struct Particle(S.Object)
	{
		trace: Trace
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

			self.likelihood = softeq(percentSame, 1.0, VOXEL_FACTOR_WEIGHT) +
							  softeq(percentOutside, 0.0, OUTSIDE_FACTOR_WEIGHT)
		end
	end

	-- Analagous to the 'global trace' in Quicksand
	local globalParticle = global(&Particle, 0)
	Particle.globalParticle = globalParticle

	terra Particle:run()
		if not self.finished then
			self.geoindex = 0

			globalParticle = self

			-- How we run the program depends on the implementation strategy
			escape
				if IMPLEMENTATION == Impl.RETURN or IMPLEMENTATION == Impl.FULLRUN then
					emit quote
						self.trace:update(true)
						if self.geoindex < self.stopindex then
							self.finished = true
						else
							self.stopindex = self.stopindex + 1
						end
					end
				elseif IMPLEMENTATION == Impl.LONGJMP then
					emit quote
						if C.setjmp(self.jumpEnv) == 0 then
							self.trace:update(true)
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

-----------------------------------------------------------------

local function TraceType(P)
	if USE_QUICKSAND_TRACE then
		return QSTrace(P)
	else
		return SimpleTrace(P)
	end
end

-----------------------------------------------------------------

-- Retrieves the global particle for the currently compiling program
local function globalParticle()
	assert(currentlyCompilingProgram ~= nil)
	return Particle(TraceType(currentlyCompilingProgram)).globalParticle
end

-- Macro that needs access to the global particle.
-- Second argument is the function that generates alternate code in compilation contexts
--    where it is not safe to access the global particle (i.e. Quicksand's
--    type detection pass)
-- Second arg defaults to a function returning the empty quote
local function gpmacro(fn, altfn)
	altfn = altfn or function() return quote end end
	return macro(function(...)
		if USE_QUICKSAND_TRACE and trace.compilation.isDoingTypeDetectionPass() then
			return altfn(...)
		else
			return fn(...)
		end
	end)
end

-----------------------------------------------------------------

-- Denotes the 'main' function of an SMC program.
-- Should be used to wrap the function returned by an smc.program.
local function main(fn)
	if IMPLEMENTATION == Impl.RETURN then
		-- This won't prevent all errors (because any subroutine could fail to be a macro),
		--    but hopefully it catches some common ones.
		assert(terralib.ismacro(fn),
			"smc.main: argument must be a Terra macro to use RETURN semantics")
	end
	-- Reach into the global particle to get the mesh-so-far.
	-- (I've implemented things this way mostly as a concession to Quicksand,
	--    whose programs don't take arguments)
	local globalMesh = gpmacro(
		function() return `&[globalParticle()].mesh end,
		function() return `nil end
	)
	local terra mainfn()
		var meshptr = globalMesh()
		fn(meshptr)
	end
	mainfn.__is_smc_main__ = true
	return mainfn
end

isSMCMainFunction = function(p)
	return p.__is_smc_main__
end

-----------------------------------------------------------------

-- Set the global trace to nil
local nilGlobalTrace = macro(function()
	if USE_QUICKSAND_TRACE then
		return quote trace.__UNSAFE_setGlobalTrace(nil) end
	else
		return quote [globalTrace()] = nil end
	end
end)

local function makeGeoPrim(shapefn)
	return gpmacro(function(mesh, ...)
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
								-- So that the trace doesn't record any random choices past this point.
								nilGlobalTrace()
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
local Sample = qs.Sample(Mesh)
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

	local Particles = S.Vector(Particle(TraceType(P)))

	local terra recordCurrMeshes(particles: &Particles, generations: &Generations)
		var samps = generations:insert()
		samps:init()
		for p in particles do
			var s = samps:insert()
			s.value:copy(&p.mesh)
			s.logprob = p.likelihood
		end
	end

	local terra resampleMultinomial(weights: &S.Vector(double), pcurr: &Particles, pnext: &Particles)
		pnext:clear()
		var nParticles = pcurr:size()
		for i=0,nParticles do
			var index = [distrib.categorical_vector(double)].sample(weights)
			var newp = pnext:insert()
			newp:copy(pcurr:get(index))
		end
	end

	-- See http://arxiv.org/abs/1301.4019
	local terra resampleStratified(weights: &S.Vector(double), pcurr: &Particles, pnext: &Particles, systematic: bool)
		pnext:clear()
		var N = pcurr:size()
		var u : double
		if systematic then
			u = [distrib.uniform(double)].sample(0.0, 1.0)
		end
		-- Compute CDF of weight distribution
		var weightCDF = [S.Vector(double)].salloc():init()
		weightCDF:insert(weights(0))
		for i=1,N do
			var wprev = weightCDF(weightCDF:size()-1)
			weightCDF:insert(wprev + weights(i))
		end
		-- Resample
		var cumNumOffspring = 0
		var checkCum = 0
		var numinserts = 0
		for i=0,N do
			var ri = N * weightCDF(i) / weightCDF(N-1)
			var ki = int(tmath.floor(ri)) + 1
			if ki > N then ki = N end
			if not systematic then
				u = [distrib.uniform(double)].sample(0.0, 1.0)
			end
			var oi = int(tmath.floor(ri + u))
			if oi > N then oi = N end
			-- cumNumOffspring should be non-decreasing.
			-- I think this can happen due to the random offset?
			if oi < cumNumOffspring then oi = cumNumOffspring end
			var numOffspring = oi - cumNumOffspring
			checkCum = checkCum + numOffspring
			cumNumOffspring = oi
			var localNumInserts = 0
			for j=0,numOffspring do
				numinserts = numinserts + 1
				localNumInserts = localNumInserts + 1
				var newp = pnext:insert()
				newp:copy(pcurr:get(i))
			end
		end
	end

	-- See http://arxiv.org/abs/1301.4019
	local terra resampleRejection(weights: &S.Vector(double), pcurr: &Particles, pnext: &Particles)
		pnext:clear()
		var N = pcurr:size()
		-- find max weight
		var maxweight = [-math.huge]
		for w in weights do
			maxweight = tmath.fmax(w, maxweight)
		end
		-- resample
		for i=0,N do
			var j = i
			var u = [distrib.uniform(double)].sample(0.0, 1.0)
			while u > weights(j)/maxweight do
				j = [distrib.uniformInt(double)].sample(0, N-1)
				u = [distrib.uniform(double)].sample(0.0, 1.0)
			end
			var newp = pnext:insert()
			newp:copy(pcurr:get(j))
		end
	end

	-- See http://arxiv.org/abs/1301.4019
	local terra resampleMetropolis(weights: &S.Vector(double), pcurr: &Particles, pnext: &Particles, eps: double)
		pnext:clear()
		var N = pcurr:size()
		-- find max weight and mean weight
		var maxweight = [-math.huge]
		var meanweight = 0.0
		for w in weights do
			maxweight = tmath.fmax(w, maxweight)
			meanweight = meanweight + w
		end
		meanweight = meanweight / N
		-- Calculate the number of MH iterations to use to guarantee a bias bound
		--    of eps
		var beta = meanweight / maxweight
		var nIters = int(tmath.log(eps) / tmath.log(1 - beta))
		-- resample
		for i=0,N do
			var k = i
			for b=0,nIters do
				var u = [distrib.uniform(double)].sample(0.0, 1.0)
				var j = [distrib.uniformInt(double)].sample(0, N-1)
				if u < weights(j) / weights(k) then
					k = j
				end
			end
			var newp = pnext:insert()
			newp:copy(pcurr:get(k))
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
			-- TODO: Resampling in-place?
			escape
				if RESAMPLING_ALG == Resample.MULTINOMIAL then
					emit `resampleMultinomial(weights, particles, nextParticles)
				elseif RESAMPLING_ALG == Resample.STRATIFIED then
					emit `resampleStratified(weights, particles, nextParticles, false)
				elseif RESAMPLING_ALG == Resample.SYSTEMATIC then
					emit `resampleStratified(weights, particles, nextParticles, true)
				elseif RESAMPLING_ALG == Resample.REJECTION then
					emit `resampleRejection(weights, particles, nextParticles)
				elseif RESAMPLING_ALG == Resample.METROPOLIS then
					emit `resampleMetropolis(weights, particles, nextParticles, METROPOLIS_RESAMPLE_EPS)
				end
			end
			-- Record meshes *BEFORE* resampling
			if recordHistory then
				recordCurrMeshes(particles, outgenerations)
			end
			-- Swap old and new particle sets
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
	main = main,
	Sample = Sample,
	flip = flip,
	poisson = poisson,
	uniform = uniform,
	uniformInt = uniformInt,
	makeGeoPrim = makeGeoPrim,
	run = run
}





