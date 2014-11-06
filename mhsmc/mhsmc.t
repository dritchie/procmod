local S = terralib.require("qs.lib.std")
local tmath = terralib.require("qs.lib.tmath")

-- Quicksand interop stuff
local qs = terralib.require("qs")
local trace = terralib.require("qs.trace")
local distrib = terralib.require("qs.distrib")

local C = terralib.includecstring [[
#include <stdio.h>
inline void flushstdout() { fflush(stdout); }
#include <float.h>
inline double getdblmin() { return DBL_MIN; }
]]

local flushstdout = C.flushstdout
local LOG_DBL_MIN = tmath.log(C.getdblmin())



-- Different particle resampling algorithms
local Resample = 
{
	MULTINOMIAL = 0,
	STRATIFIED = 1,
	SYSTEMATIC = 2,
	REJECTION = 3,
	METROPOLIS = 4
}

local RESAMPLING_ALG = Resample.MULTINOMIAL


local run = S.memoize(function(P)

	local Trace = trace.RandExecTrace(P, double)
	local Traces = S.Vector(Trace)

	-- Need to use Quicksand's Sample type for compatibility with other code
	local Sample = qs.SampleType(P)
	local Samples = S.Vector(Sample)
	local Generations = S.Vector(Samples)

	local terra recordCurrMeshes(particles: &Traces, generations: &Generations)
		var samps = generations:insert()
		samps:init()
		for p in particles do
			var s = samps:insert()
			s.value:copy(&p.returnValue)
			s.logprob = p.logprob
		end
	end

	local terra resampleMultinomial(weights: &S.Vector(double), pcurr: &Traces, pnext: &Traces)
		pnext:clear()
		var nParticles = pcurr:size()
		for i=0,nParticles do
			var index = [distrib.categorical_vector(double)].sample(weights)
			var newp = pnext:insert()
			newp:copy(pcurr:get(index))
		end
	end

	-- See http://arxiv.org/abs/1301.4019
	local terra resampleStratified(weights: &S.Vector(double), pcurr: &Traces, pnext: &Traces, systematic: bool)
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
	local terra resampleRejection(weights: &S.Vector(double), pcurr: &Traces, pnext: &Traces)
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
	local terra resampleMetropolis(weights: &S.Vector(double), pcurr: &Traces, pnext: &Traces, eps: double)
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

	return terra(nParticles: uint, nGenerations: uint, outgenerations: &Generations, recordHistory: bool, verbose: bool)
		-- Init particles
		var particles = Traces.salloc():init()
		var nextParticles = Traces.salloc():init()
		var weights = [S.Vector(double)].salloc():init()
		for i=0,nParticles do
			var p = particles:insert()
			p:init(true)
			weights:insert(0.0)
		end
		-- Repeatedly do MH proposals, then resample.
		-- var mhkernel = [qs.TraceMHKernel()(Trace)].salloc():init()
		for g=0,nGenerations do
			var minFiniteScore = [math.huge]
			for i=0,particles:size() do
				var p = particles:get(i)

				-- mhkernel:next(p, 0, 1)

				var numchoices = [Trace.countChoices()](p)
				var randindex = [distrib.uniform(double)].sample(0.0, 1.0) * numchoices
				var rc = [Trace.getChoice()](p, randindex)
				rc:proposal()
				p:update(rc:getIsStructural())

				weights(i) = p.logprob
				-- Violated hard constraints --> 0 probability
				if not p.conditionsSatisfied then weights(i) = [-math.huge] end
				if weights(i) ~= [-math.huge] and weights(i) < minFiniteScore then
					minFiniteScore = weights(i)
				end
			end
			-- Exponentiate the weights to bring them out of log-space
			-- (Avoid underflow by adding a constant to all scores that
			--  ensures that when we exp them, they will all be representable
			--  doubles).
			var underflowCorrect = 0.0
			-- KLUDGE: With this scheme, initial particles have a huge range of scores. This just tries to make
			--    sure we don't exp our higher scores up to +inf. Really, I ought to do something smarter than this, but
			--    I don't give a shit right now.
			if minFiniteScore < -1000.0 then minFiniteScore = -1000.0 end
			if minFiniteScore < LOG_DBL_MIN then
				underflowCorrect = LOG_DBL_MIN - minFiniteScore
			end
			for w in weights do
				w = tmath.exp(w + underflowCorrect)
			end
			-- S.printf("Weights: ")
			-- for i=0,weights:size() do
			-- 	S.printf("%u: %g    ", i, weights(i))
			-- end
			-- S.printf("\n")
			if verbose then
				S.printf(" Generation %u\r", g+1)
				flushstdout()
			end
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
			if recordHistory or g == nGenerations-1 then
				recordCurrMeshes(particles, outgenerations)
			end
		end
		if verbose then S.printf("\n") end
	end
end)



return 
{
	run = run
}



