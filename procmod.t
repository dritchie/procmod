local S = terralib.require("qs.lib.std")
local LS = terralib.require("std")
local Mesh = terralib.require("geometry.mesh")(double)
local Vec = terralib.require("linalg.vec")
local BBox = terralib.require("geometry.bbox")
local BinaryGrid = terralib.require("geometry.binaryGrid3d")
local prob = terralib.require("prob.prob")
local smc = terralib.require("prob.smc")
local mcmc = terralib.require("prob.mcmc")
local distrib = terralib.require("qs.distrib")
local globals = terralib.require("globals")


local Vec3 = Vec(double, 3)
local BBox3 = BBox(Vec3)

---------------------------------------------------------------

local softeq = macro(function(val, target, s)
	return `[distrib.gaussian(double)].logprob(val, target, s)
end)

---------------------------------------------------------------

-- The procedural-modeling specific state that gets cached with
--    every particle/trace.
-- Stores data needed to compute scores for whatever objectives the config file specifies
--    (e.g. volume matching)
local State = S.memoize(function(doVolumeMatch)

	local struct State(S.Object)
	{
		mesh: Mesh
		prims: S.Vector(Mesh)	-- For collision checks
		hasSelfIntersections: bool
		score: double
	}
	if doVolumeMatch then
		State.entries:insert({field="grid", type=BinaryGrid})
	end
	-- Also give the State class all the lua.std metatype stuff
	LS.Object(State)

	terra State:__init()
		self:initmembers()
		self:clear()
	end

	terra State:clear()
		self.mesh:clear()
		self.prims:clear()
		[doVolumeMatch and quote self.grid:clear() end or quote end]
		self.hasSelfIntersections = false
		self.score = 0.0
	end

	terra State:freeMemory()
		self:clear()
	end

	terra State:prepareForRun() end

	terra State:update(newmesh: &Mesh, updateScore: bool)
		if updateScore then
			self.hasSelfIntersections = self.hasSelfIntersections or newmesh:intersects(&self.prims)
			escape
				if doVolumeMatch then
					emit quote
						if not self.hasSelfIntersections then
							self.grid:resize(globals.targetGrid.rows,
											 globals.targetGrid.cols,
											 globals.targetGrid.slices)
							newmesh:voxelize(&self.grid, &globals.targetBounds, globals.config.voxelSize, globals.config.solidVoxelize)
						end
					end
				end
			end
		end
		self.mesh:append(newmesh)
		self.prims:insert():copy(newmesh)
		if updateScore then
			-- Compute score
			if self.hasSelfIntersections then
				self.score = [-math.huge]
			else
				self.score = 0.0
				escape
					if doVolumeMatch then
						emit quote
							var meshbb = self.mesh:bbox()
							var targetext = globals.targetBounds:extents()
							var extralo = (globals.targetBounds.mins - meshbb.mins):max(Vec3.create(0.0)) / targetext
							var extrahi = (meshbb.maxs - globals.targetBounds.maxs):max(Vec3.create(0.0)) / targetext
							var percentOutside = extralo(0) + extralo(1) + extralo(2) + extrahi(0) + extrahi(1) + extrahi(2)
							var percentSame = globals.targetGrid:percentCellsEqualPadded(&self.grid)
							self.score = self.score + softeq(percentSame, 1.0, [globals.config.voxelFactorWeight]) +
										 			  softeq(percentOutside, 0.0, [globals.config.outsideFactorWeight])
						end
					end
				end
			end
		end
	end

	terra State:currentScore()
		return self.score
	end

	return State

end)

-- Retrieve the State type specified by the global config settings
local function GetStateType()
	return State(globals.config.doVolumeMatch)
end

---------------------------------------------------------------

-- A State object designed to work with MH
-- After a proposal, it'll recompute everything that happens after that variable
--    in runtime order.
local MHState = S.memoize(function(State)

	local struct MHState(S.Object)
	{
		states: S.Vector(State)
		currIndex: uint
	}
	LS.Object(MHState)

	terra MHState:freeMemory()
		self.states:destruct()
	end

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

	return MHState
end)

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
local function SIR(module, outgenerations, opts)

	local StateType = GetStateType()
	local globState = globalState(StateType)

	local function makeGeoPrim(geofn)
		-- First, we make a Terra function that does all the perf-critical stuff:
		--    creates new geometry, tests for intersections, voxelizes, etc.
		local args = geofnargs(geofn)
		local terra update([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globState:update(tmpmesh, true)
		end
		-- Now we wrap this in a Lua function that checks whether this work
		--    needs to be done at all
		return function(...)
			if not smc.isReplaying() then
				update(...)
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
			if opts.saveSampleValues then
				samp.value:copy(p.trace.args[1].mesh)
			else
				LS.luainit(samp.value)
			end
			samp.logprob = p.trace.loglikelihood
		end
	end

	-- Install the SMC geo prim generator
	local program = module(makeGeoPrim)
	-- Wrap program so that it takes procmod State as argument
	program = statewrap(program, StateType)
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
	local initstate = StateType.luaalloc():luainit()
	smc.SIR(program, {initstate}, newopts)
end

---------------------------------------------------------------

-- Metropolis hastings inference
-- IMPORTANT: Don't use this with future-ized versions of programs: the co-routine
--    switching will mess up the address stack (this is fixable, but I don't see a
--    reason to bother with it right now)
local function MH(module, outgenerations, opts)

	local StateType = MHState(GetStateType())
	local globState = globalState(StateType)

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
			local score = gstate:currentScore()
			prob.likelihood(score)
			gstate:advance()
			-- Stop running this trace b/c we know we're going to reject it.
			if score == -math.huge then
				prob.throwZeroProbabilityError()
			end
		end
	end

	local function recordSample(trace)
		if outgenerations:size() == 0 then
			local v = outgenerations:insert()
			LS.luainit(v)
		end
		local v = outgenerations:get(0)
		local samp = v:insert()
		if opts.saveSampleValues then
			samp.value:copy(trace.args[1]:getMesh())
		else
			LS.luainit(samp.value)
		end
		samp.logprob = trace.loglikelihood
	end

	local program = statewrap(module(makeGeoPrim), StateType)
	local newopts = LS.copytable(opts)
	newopts.onSample = recordSample
	local initstate = StateType.luaalloc():luainit()
	mcmc.MH(program, {initstate}, newopts)
end


---------------------------------------------------------------

-- Just run the program forward without enforcing any constraints
-- Useful for development and debugging
local function ForwardSample(module, outgenerations, numsamples)

	local StateType = GetStateType()
	local globState = globalState(StateType)

	local function makeGeoPrim(geofn)
		local args = geofnargs(geofn)
		return terra([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globState:update(tmpmesh, false)
		end
	end

	local program = statewrap(module(makeGeoPrim), StateType)
	local state = StateType.luaalloc():luainit()
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

	local StateType = GetStateType()
	local globState = globalState(StateType)
	
	local function makeGeoPrim(geofn)
		local args = geofnargs(geofn)
		return terra([args])
			var tmpmesh = Mesh.salloc():init()
			geofn(tmpmesh, [args])
			globState:update(tmpmesh, true)
		end
	end

	local program = statewrap(module(makeGeoPrim), StateType)
	local state = StateType.luaalloc():luainit()
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





