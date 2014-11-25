local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local Mesh = terralib.require("mesh")(double)
local Vec = terralib.require("linalg.vec")
local BBox = terralib.require("bbox")
local BinaryGrid = terralib.require("binaryGrid3d")
local prob = terralib.require("lua.prob")
local smc = terralib.require("lua.smc")
local mcmc = terralib.require("lua.mcmc")
local distrib = terralib.require("qs.distrib")


local Vec3 = Vec(double, 3)
local BBox3 = BBox(Vec3)

local globals = terralib.require("globals")

---------------------------------------------------------------

local VOXEL_FACTOR_WEIGHT = 0.02
-- local VOXEL_FILLED_FACTOR_WEIGHT = 0.01
-- local VOXEL_EMPTY_FACTOR_WEIGHT = 0.08
local OUTSIDE_FACTOR_WEIGHT = 0.02

---------------------------------------------------------------

local softeq = macro(function(val, target, s)
	return `[distrib.gaussian(double)].logprob(val, target, s)
end)

---------------------------------------------------------------

-- The procedural-modeling specific state that gets cached with
--    every particle/trace. Stores the mesh-so-far and the
--    grid-so-far, etc.
local struct State(S.Object)
{
	mesh: Mesh
	grid: BinaryGrid
	hasSelfIntersections: bool
	score: double
}
-- Also give the State class all the lua.std metatype stuff
LS.Object(State)

terra State:__init()
	self:initmembers()
	self:clear()
end

terra State:clear()
	self.mesh:clear()
	self.grid:clear()
	self.hasSelfIntersections = false
	self.score = 0.0
end

terra State:prepareForRun() end

State.methods.doUpdate = terra(newmesh: &Mesh, mesh: &Mesh, grid: &BinaryGrid, hasSelfIntersections: bool, updateScore: bool)
	if updateScore then
		hasSelfIntersections = hasSelfIntersections or newmesh:intersects(mesh)
		if not hasSelfIntersections then
			grid:resize(globals.targetGrid.rows,
						globals.targetGrid.cols,
						globals.targetGrid.slices)
			newmesh:voxelize(grid, &globals.targetBounds, globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
		end
	end
	mesh:append(newmesh)
	var score = 0.0
	if updateScore then
		-- Compute score
		if hasSelfIntersections then
			score = [-math.huge]
		else
			var meshbb = mesh:bbox()
			var targetext = globals.targetBounds:extents()
			var extralo = (globals.targetBounds.mins - meshbb.mins):max(Vec3.create(0.0)) / targetext
			var extrahi = (meshbb.maxs - globals.targetBounds.maxs):max(Vec3.create(0.0)) / targetext
			var percentOutside = extralo(0) + extralo(1) + extralo(2) + extrahi(0) + extrahi(1) + extrahi(2)
			var percentSame = globals.targetGrid:percentCellsEqualPadded(grid)
			score = softeq(percentSame, 1.0, VOXEL_FACTOR_WEIGHT) +
				   	softeq(percentOutside, 0.0, OUTSIDE_FACTOR_WEIGHT)
			-- var percentSameFilled = globals.targetGrid:percentFilledCellsEqualPadded(grid)
			-- var percentSameEmpty = globals.targetGrid:percentEmptyCellsEqualPadded(grid)
			-- score = softeq(percentSameFilled, 1.0, VOXEL_FILLED_FACTOR_WEIGHT) +
			-- 			 softeq(percentSameEmpty, 1.0, VOXEL_EMPTY_FACTOR_WEIGHT) +
			-- 			 softeq(percentOutside, 0.0, OUTSIDE_FACTOR_WEIGHT)
		end
	end
	return hasSelfIntersections, score
end

terra State:update(newmesh: &Mesh, updateScore: bool)
	var hasSelfIntersections, score = State.doUpdate(newmesh, &self.mesh, &self.grid, self.hasSelfIntersections, updateScore)
	if updateScore then
		self.hasSelfIntersections = hasSelfIntersections
		self.score = score
	end
end

terra State:predictScore(newmesh: &Mesh)
	var meshcopy = Mesh.salloc():copy(&self.mesh)
	var gridcopy = BinaryGrid.salloc():copy(&self.grid)
	var hasSelfIntersections, score = State.doUpdate(newmesh, meshcopy, gridcopy, self.hasSelfIntersections, true)
	return score
end

terra State:currentScore()
	return self.score
end

---------------------------------------------------------------

-- A State object designed to work with MH
-- After a proposal, it'll recompute everything that happens after that variable
--    in runtime order.
local struct MHState(S.Object)
{
	-- TODO: I really should use a tree structured according to the address stack...
	states: S.Vector(State)
	currIndex: uint
}
LS.Object(MHState)

terra MHState:prepareForRun()
	self.currIndex = 0
end

terra MHState:update(newmesh: &Mesh)
	var state : &State
	-- We're either adding a new state, or we're overwriting something
	--    we've already done.
	if self.currIndex == self.states:size() then
		state = self.states:insert()
	else
		state = self.states:get(self.currIndex)
		state:destruct()
	end
	-- If this is the first state in runtime order, then we initialize it fresh
	-- Otherwise, we start by copying the previous state.
	if self.currIndex == 0 then
		state:init()
	else
		state:copy(self.states:get(self.currIndex-1))
	end
	-- Finally, we add the new geometry and update
	state:update(newmesh, true)
end

terra MHState:currentScore()
	return self.states(self.currIndex):currentScore()
end

terra MHState:getMesh()
	return &self.states(self.currIndex-1).mesh
end

terra MHState:advance()
	self.currIndex = self.currIndex + 1
end

---------------------------------------------------------------

-- A global variable for a given type of State
local globalState = S.memoize(function(StateType)
	return global(&StateType, 0)
end)

-- Wrap a generative procedural modeling function such that it takes
--    a State as an argument and does the right thing with it.
local function statewrap(fn, StateType)
	return function(state)
		local prevstate = globalState(StateType):get()
		globalState(StateType):set(state)
		state:prepareForRun()
		local succ, err = pcall(fn)
		globalState(StateType):set(prevstate)
		if not succ then
			error(err)
		end
	end
end

-- Generate symbols for the arguments to a geo prim function
local function geofnargs(geofn)
	local paramtypes = geofn:gettype().parameters
	local asyms = terralib.newlist()
	for i=2,#paramtypes do 	 -- Skip first arg (the mesh itself)
		asyms:insert(symbol(paramtypes[i]))
	end
	return asyms
end

---------------------------------------------------------------

-- Run sequential importance sampling on a procedural modeling program,
--    saving the generated meshes
-- 'outgenerations' is a cdata Vector(Vector(Sample(Mesh)))
-- Options are:
--    * recordHistory: record meshes all the way through, not just the final ones
--    * any other options recognized by smc.SIR
local function SIR(module, outgenerations, opts)

	local globState = globalState(State)

	local function makeGeoPrim(geofn)
		-- First, we make a Terra function that does all the perf-critical stuff:
		--    creates new geometry, tests for intersections, voxelizes, etc.
		local args = geofnargs(geofn)
		local terra update([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globState:update(tmpmesh, true)
		end
		args = geofnargs(geofn)
		local terra predictScore([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			return globState:predictScore(tmpmesh)
		end
		-- Now we wrap this in a Lua function that checks whether this work
		--    needs to be done at all
		return function(...)
			-- smc.sync()
			-- prob.future.yield()
			if not smc.isReplaying() then
				-- smc.sync()
				-- local score = predictScore(...)
				-- prob.future.yield(score)
				update(...)
			-- else
			-- 	smc.sync()
			-- 	prob.future.yield()
			end
			prob.likelihood(globState:get():currentScore())
			smc.sync()
			prob.future.yield()
		end
	end

	-- Copy meshes from a Lua table of smc Particles to a cdata Vector of Sample(Mesh)
	local function copyMeshes(particles, outgenerations)
		local newgeneration = outgenerations:insert()
		LS.luainit(newgeneration)
		for _,p in ipairs(particles) do
			local samp = newgeneration:insert()
			-- The first arg of the particle's trace is the procmod State object.
			-- This is a bit funky, but I think it's the best way to get a this data.
			samp.value:copy(p.trace.args[1].mesh)
			-- samp.logprob = p.trace.logposterior
			-- samp.loglikelihood = p.trace.loglikelihood
			samp.logprob = p.trace.loglikelihood
		end
	end

	-- Install the SMC geo prim generator
	local program = module(makeGeoPrim)
	-- Wrap program so that it takes procmod State as argument
	program = statewrap(program, State)
	-- Create the beforeResample, afterResample, and exit callbacks
	local function dorecord(particles)
		copyMeshes(particles, outgenerations)
	end
	local newopts = LS.copytable(opts)
	newopts.exit = dorecord
	if opts.recordHistory then
		newopts.beforeResample = dorecord
		newopts.afterResample = dorecord
	end
	-- Run smc.SIR with an initial empty State object as argument
	local initstate = State.luaalloc():luainit()
	smc.SIR(program, {initstate}, newopts)
end

---------------------------------------------------------------

-- Metropolis hastings inference
-- IMPORTANT: Don't use this with future-ized versions of programs: the co-routine
--    switching will mess up the address stack (this is fixable, but I don't see a
--    reason to bother with it right now)
local function MH(module, outgenerations, opts)

	local globState = globalState(MHState)

	local function makeGeoPrim(geofn)
		local args = geofnargs(geofn)
		local terra update([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globState:update(tmpmesh)
		end
		return function(...)
			if not mcmc.isReplaying() then
				update(...)
			end
			local gstate = globState:get()
			prob.likelihood(gstate:currentScore())
			gstate:advance()
		end
	end

	local function recordSample(trace)
		if outgenerations:size() == 0 then
			local v = outgenerations:insert()
			LS.luainit(v)
		end
		local v = outgenerations:get(0)
		local samp = v:insert()
		samp.value:copy(trace.args[1]:getMesh())
		samp.logprob = trace.loglikelihood
		---------------------------------------------
		-- local v = outgenerations:insert()
		-- LS.luainit(v)
		-- local state = trace.args[1]
		-- for i=0,tonumber(state.states:size()-1) do
		-- 	local sstate = state.states:get(i)
		-- 	local samp = v:insert()
		-- 	samp.value:copy(sstate.mesh)
		-- 	samp.logprob = trace.loglikelihood
		-- end
	end

	local program = statewrap(module(makeGeoPrim), MHState)
	local newopts = LS.copytable(opts)
	newopts.onSample = recordSample
	local initstate = MHState.luaalloc():luainit()
	mcmc.MH(program, {initstate}, newopts)
end


---------------------------------------------------------------

-- Just run the program forward without enforcing any constraints
-- Useful for development and debugging
local function ForwardSample(module, outgenerations, numsamples)

	local globState = globalState(State)

	local function makeGeoPrim(geofn)
		local args = geofnargs(geofn)
		return terra([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globState:update(tmpmesh, false)
		end
	end

	local program = statewrap(module(makeGeoPrim), State)
	local state = State.luaalloc():luainit()
	local samples = outgenerations:insert()
	LS.luainit(samples)
	for i=1,numsamples do
		program(state)
		local samp = samples:insert()
		samp.value:copy(state.mesh)
		samp.logprob = 0.0
		state:clear()
	end
end

---------------------------------------------------------------

-- Like forward sampling, but reject any 0-probability samples
-- Keep running until numsamples have been accumulated
local function RejectionSample(module, outgenerations, numsamples)

	local globState = globalState(State)
	
	local function makeGeoPrim(geofn)
		local args = geofnargs(geofn)
		return terra([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globState:update(tmpmesh, true)
		end
	end

	local program = statewrap(module(makeGeoPrim), State)
	local state = State.luaalloc():luainit()
	local samples = outgenerations:insert()
	LS.luainit(samples)
	while samples:size() < numsamples do
		program(state)
		if state.score > -math.huge then
			local samp = samples:insert()
			samp.value:copy(state.mesh)
			samp.logprob = state.score
		end
		state:clear()
	end
end

---------------------------------------------------------------

return
{
	Sample = terralib.require("qs").Sample(Mesh),
	SIR = SIR,
	MH = MH,
	ForwardSample = ForwardSample,
	RejectionSample = RejectionSample
}





