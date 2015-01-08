local S = terralib.require("qs.lib.std")
local LS = terralib.require("std")
local Mesh = terralib.require("geometry.mesh")(double)
local Vec = terralib.require("linalg.vec")
local Mat = terralib.require("linalg.mat")
local BBox = terralib.require("geometry.bbox")
local BinaryGrid3D = terralib.require("geometry.binaryGrid3d")
local BinaryGrid2D = terralib.require("geometry.binaryGrid2d")
local prob = terralib.require("prob.prob")
local trace = terralib.require("prob.trace")
local smc = terralib.require("prob.smc")
local mcmc = terralib.require("prob.mcmc")
local distrib = terralib.require("qs.distrib")
local globals = terralib.require("globals")

local gl = terralib.require("gl.gl")
local glutils = terralib.require("gl.glutils")
local shadowmap = terralib.require("shadowmap")

local Vec3 = Vec(double, 3)
local BBox3 = BBox(Vec3)
local Mat4 = Mat(double, 4, 4)

---------------------------------------------------------------

local softeq = macro(function(val, target, s)
	return `[distrib.gaussian(double)].logprob(val, target, s)
end)

---------------------------------------------------------------

-- The procedural-modeling specific state that gets cached with
--    every particle/trace.
-- Stores data needed to compute scores for whatever objectives the config file specifies
--    (e.g. volume matching)
local State = S.memoize(function(checkSelfIntersections, doVolumeMatch, doVolumeAvoid,
								 doImageMatch, doShadowMatch)

	local struct State(S.Object)
	{
		mesh: Mesh
		prims: S.Vector(Mesh)	-- For collision checks
		score: double
		freedmemory: bool
	}
	if doVolumeMatch then
		State.entries:insert({field="matchGrid", type=BinaryGrid3D})
	end
	if doVolumeAvoid then
		State.entries:insert({field="avoidGrid", type=BinaryGrid3D})
	end
	if doImageMatch then
		State.entries:insert({field="matchImage", type=BinaryGrid2D})
		State.entries:insert({field="matchImagePixelData", type=S.Vector(Vec(uint8, 4))})
	end
	if doShadowMatch then
		State.entries:insert({field="shadowMatchImage", type=BinaryGrid2D})
		State.entries:insert({field="shadowMatchImagePixelData", type=S.Vector(Vec(uint8, 4))})
	end
	-- Also give the State class all the lua.std metatype stuff
	LS.Object(State)

	terra State:__init()
		self:initmembers()
		self:clear()
		self.freedmemory = false
	end

	terra State:clear()
		escape
			for _,e in ipairs(State.entries) do
				if e.type:isstruct() and e.type:getmethod("clear") then
					emit quote self.[e.field]:clear() end
				end
			end
		end
		self.score = 0.0
	end

	terra State:__destructmembers()
		if not self.freedmemory then
			self.freedmemory = true
			escape
				for _,e in ipairs(State.entries) do
					if e.type:isstruct() and e.type:getmethod("destruct") then
						emit quote self.[e.field]:destruct() end
					end
				end
			end
		end
	end

	terra State:freeMemory()
		self:__destructmembers()
	end

	terra State:prepareForRun() end

	terra State:update(newmesh: &Mesh, updateScore: bool)
		if updateScore then
			escape
				if checkSelfIntersections then
					emit quote
						if self.score ~= [-math.huge] and newmesh:intersects(&self.prims) then
							self.score = [-math.huge]
						end
					end
				end
			end
		end
		self.mesh:append(newmesh)
		self.prims:insert():copy(newmesh)
		if updateScore then
			if self.score ~= [-math.huge] then
				self.score = 0.0
			end
			escape
				-- Volume avoidance score contribution
				if doVolumeAvoid then
					emit quote
						if self.score ~= [-math.huge] then
							-- Implemented as a hard constraint, for now
							var floor = [globals.config.avoidFloor or -math.huge]
							var meshbb = self.mesh:bbox()
							if meshbb.mins(1) < floor then
								self.score = [-math.huge]
							else
								self.avoidGrid:resize(globals.avoidTargetGrid.rows,
											 	  	  globals.avoidTargetGrid.cols,
											 	  	  globals.avoidTargetGrid.slices)
								newmesh:voxelize(&self.avoidGrid, &globals.avoidTargetBounds, globals.config.voxelSize, globals.config.solidVoxelize)
								if self.avoidGrid:numFilledCellsEqualPadded(&globals.avoidTargetGrid) > 0 then
									self.score = [-math.huge]
								end
							end
						end
					end
				end
				-- Volume matching score contribution
				if doVolumeMatch then
					emit quote
						if self.score ~= [-math.huge] then
							self.matchGrid:resize(globals.matchTargetGrid.rows,
											 	  globals.matchTargetGrid.cols,
												  globals.matchTargetGrid.slices)
							newmesh:voxelize(&self.matchGrid, &globals.matchTargetBounds, globals.config.voxelSize, globals.config.solidVoxelize)
							var meshbb = self.mesh:bbox()
							var targetext = globals.matchTargetBounds:extents()
							var extralo = (globals.matchTargetBounds.mins - meshbb.mins):max(Vec3.create(0.0)) / targetext
							var extrahi = (meshbb.maxs - globals.matchTargetBounds.maxs):max(Vec3.create(0.0)) / targetext
							var percentOutside = extralo(0) + extralo(1) + extralo(2) + extrahi(0) + extrahi(1) + extrahi(2)
							var percentSame = globals.matchTargetGrid:percentCellsEqualPadded(&self.matchGrid)
							self.score = self.score + softeq(percentSame, 1.0, [globals.config.matchVoxelFactorWeight]) +
										 			  softeq(percentOutside, 0.0, [globals.config.matchOutsideFactorWeight])
			 			end
					end
				end
				-- Image matching score contribution
				if doImageMatch then
					emit quote
						if self.score ~= [-math.huge] then
							-- Render
							gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, globals.getMatchRenderFBO())
							var w = globals.matchTargetImage.cols
							var h = globals.matchTargetImage.rows
							var viewport : int[4]
							gl.glGetIntegerv(gl.GL_VIEWPORT, viewport)
							gl.glViewport(0, 0, w, h)
							gl.glClearColor(0.0, 0.0, 0.0, 1.0)
							gl.glClear(gl.GL_COLOR_BUFFER_BIT or gl.GL_DEPTH_BUFFER_BIT)
							gl.glColor4f(1.0, 1.0, 1.0, 1.0)
							globals.config.matchCamera.aspect = double(w)/h
							globals.config.matchCamera:setupGLPerspectiveView()
							self.mesh:draw()
							gl.glFlush()
							-- Read pixels, convert to binary grid, and compare
							self.matchImagePixelData:resize(w*h)
							gl.glReadPixels(0, 0, w, h, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &(self.matchImagePixelData(0)))
							self.matchImage:clear()
							self.matchImage:resize(h, w)
							for y=0,h do
								for x=0,w do
									var c = self.matchImagePixelData(y*w + x)
									if c(0) > 0 then
										self.matchImage:setPixel(y, x)
									end
								end
							end

							-- var percentSame = globals.matchTargetImage:percentCellsEqualPadded(&self.matchImage)

							var weightedSum = 0.0
							var totalWeight = 0.0
							for row=0,self.matchImage.rows do
								for col=0,self.matchImage.cols do
									var w = globals.matchWeightImage(col, row)(0)
									weightedSum = weightedSum +
										w*float(self.matchImage:isPixelSet(row,col) == globals.matchTargetImage:isPixelSet(row,col))
									totalWeight = totalWeight + w
								end
							end
							var percentSame = weightedSum / totalWeight

							self.score = self.score + softeq(percentSame, 1.0, [globals.config.matchPixelFactorWeight])
							-- Clean up
							gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0)
							gl.glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
						end
					end
				end
				-- Shadow matching score contribution
				if doShadowMatch then
					emit quote
						if self.score ~= [-math.huge] then
							[shadowmap.renderShadowMask(false)](&self.mesh, &self.shadowMatchImage, &self.shadowMatchImagePixelData)

							-- var percentSame = globals.shadowTargetImage:percentCellsEqualPadded(&self.shadowMatchImage)

							var weightedSum = 0.0
							var totalWeight = 0.0

							var outside = 0.0
							var outsideSum = 0.0

							var unfilled = 0.0
							var fillSum = 0.0

							for row=0,self.shadowMatchImage.rows do
								for col=0,self.shadowMatchImage.cols do
									var w = globals.shadowWeightImage(col, row)(0)
									weightedSum = weightedSum +
										w*float(self.shadowMatchImage:isPixelSet(row,col) == globals.shadowTargetImage:isPixelSet(row,col))
									totalWeight = totalWeight + w

									if self.shadowMatchImage:isPixelSet(row,col) and not globals.shadowTargetImage:isPixelSet(row,col) then
										outside = outside + 1
									end
									outsideSum = outsideSum + 1

									if globals.shadowTargetImage:isPixelSet(row,col) then
										if not self.shadowMatchImage:isPixelSet(row,col) then
											unfilled = unfilled + 1
										end
										fillSum = fillSum + 1
									end

								end
							end
							var percentSame = weightedSum / totalWeight
							var percentOutside = outside / outsideSum
							var percentUnfilled = unfilled / fillSum

							var diag = self.mesh:bbox():extents():norm()

							self.score = self.score + softeq(percentSame, 1.0, [globals.config.matchPixelFactorWeight])

							if globals.config.orthoShadow then
								var outsidePenalty = softeq(percentOutside, 0.0, [globals.config.outsideShadowPenalty])
								var fillPenalty = softeq(percentUnfilled, 0.0, [globals.config.notFilledPenalty])
								self.score = self.score + outsidePenalty + fillPenalty 
								--S.printf("%f %f %f\n\n", outsidePenalty, fillPenalty, diag(1))
							end
						end
					end
				end
			end
		end
	end

	terra State:currentScore()
		return self.score
	end

	terra State:getMesh()
		return &self.mesh
	end

	return State

end)

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
		-- S.printf("\nPREPARING FOR RUN               \n------------------------\n")
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
		-- S.printf("   score: %g\n", self.states(self.currIndex):currentScore())
		return self.states(self.currIndex):currentScore()
	end

	terra MHState:getMesh()
		return &self.states(self.currIndex-1).mesh
	end

	terra MHState:advance()
		self.currIndex = self.currIndex + 1
	end


	-- -- Non-incremental version (to use this, mcmc.isReplaying must always return false)
	-- local struct MHState(S.Object)
	-- {
	-- 	state: State
	-- }
	-- LS.Object(MHState)

	-- terra MHState:freeMemory()
	-- 	self.state:destruct()
	-- end

	-- terra MHState:prepareForRun()
	-- 	self.state:clear()
	-- end

	-- terra MHState:update(newmesh: &Mesh)
	-- 	self.state:update(newmesh, true)
	-- end

	-- terra MHState:currentScore()
	-- 	return self.state:currentScore()
	-- end

	-- terra MHState:getMesh()
	-- 	return &self.state.mesh
	-- end

	-- terra MHState:advance()
	-- end


	return MHState
end)

---------------------------------------------------------------

-- Retrieve the State type specified by the global config settings
local function GetStateType()
	local StateType = State(globals.config.checkSelfIntersections,
							globals.config.doVolumeMatch,
							globals.config.doVolumeAvoid,
							globals.config.doImageMatch,
							globals.config.doShadowMatch)
	if globals.config.method == "mh" then
		StateType = MHState(StateType)
	end
	return StateType
end

-- A global variable for a given type of State
local globalState = S.memoize(function(StateType)
	return global(&StateType, 0)
end)

-- A record of the final set of traces generated by the most recent
--    run of any inference algorithm.
-- For MH, these will be the traces for all recorded samples
-- For SMC, these will be the traces for the final set of particles
local recordedTraces = {}

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

-- A function that, given a geometry resolution value, will spit out
--    a version of the last program used by any inference method,
--    but specialized to that geometry resolution
local programForGeoRes = nil

-- Turn a procedural modeling program module into a function that can
--    be executed by an inference method.
local function prepProgram(module, makeGeoPrim, StateType)
	programForGeoRes = function(geoRes)
		return statewrap(module(makeGeoPrim, geoRes), StateType)
	end
	return programForGeoRes(globals.config.loRes)
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

	local program = prepProgram(module, makeGeoPrim, StateType)
	-- Create the beforeResample, afterResample, and exit callbacks
	local function dorecord(particles)
		copyMeshes(particles, outgenerations)
	end
	local newopts = LS.copytable(opts)
	if opts.recordHistory then
		newopts.beforeResample = dorecord
		newopts.afterResample = dorecord
	end
	if globals.config.recordTraces then
		newopts.exit = function(particles)
			dorecord(particles)
			recordedTraces = {}
			for _,p in ipairs(particles) do
				p.trace.args[1] = nil  -- Allow the state to be GC'ed
				table.insert(recordedTraces, p.trace)
			end
		end
	else
		newopts.exit = dorecord
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

	local StateType = GetStateType()
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

	if globals.config.recordTraces then 
		recordedTraces = {}
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
		if globals.config.recordTraces then
			table.insert(recordedTraces, trace)
		end
	end

	local program = prepProgram(module, makeGeoPrim, StateType)
	local newopts = LS.copytable(opts)
	newopts.onSample = recordSample
	local initstate = StateType.luaalloc():luainit()
	if opts.parallelTempering then
		mcmc.MHPT(program, {initstate}, newopts)
	else
		mcmc.MH(program, {initstate}, newopts)
	end
	if globals.config.recordTraces then
		-- Allow the states for all recorded traces to be GC'ed
		for _,trace in ipairs(recordedTraces) do
			trace.args[1] = nil
		end
	end
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

	local program = prepProgram(module, makeGeoPrim, StateType)
	local state = StateType.luaalloc():luainit()
	local samples = outgenerations:insert()
	LS.luainit(samples)
	if globals.config.recordTraces then
		recordedTraces = {}
	end
	for i=1,numsamples do
		local tr = trace.FlatValueTrace.alloc():init(program, state)
		tr:run()
		local samp = samples:insert()
		samp.value:copy(state.mesh)
		samp.logprob = 0.0
		state:clear()
		tr.args[1] = nil
		if globals.config.recordTraces then
			table.insert(recordedTraces, tr)
		end
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

	local program = prepProgram(module, makeGeoPrim, StateType)
	local state = StateType.luaalloc():luainit()
	local samples = outgenerations:insert()
	LS.luainit(samples)
	if globals.config.recordTraces then
		recordedTraces = {}
	end
	while samples:size() < numsamples do
		local tr = trace.FlatValueTrace.alloc():init(program, state)
		tr:run()
		if state.score > -math.huge then
			local samp = samples:insert()
			samp.value:copy(state.mesh)
			samp.logprob = state.score
			if globals.config.recordTraces then
				table.insert(recordedTraces, tr)
			end
		end
		state:clear()
		tr.args[1] = nil
	end
end

---------------------------------------------------------------

-- Re-run a recorded trace at high geometric resolution
-- Assume index is passed in as zero-based
local function HighResRerunRecordedTrace(outgenerations, index)
	local lindex = index + 1
	-- Only possible if we enabled trace recording
	if not globals.config.recordTraces then
		print("WARNING: Attempt to re-rerun a trace when trace recording has not been enabled. Ignoring.")
	elseif #recordedTraces < lindex then
		print(string.format("WARNING: Attempt to re-rerun trace #%d, but there are only %d recorded traces. Ignoring.",
			lindex, #recordedTraces))
	else
		local StateType = GetStateType()
		local program = programForGeoRes(globals.config.hiRes)

		local trace = recordedTraces[lindex]
		-- Set the trace's program to be the new, high-res program
		trace.program = program
		-- Give the trace a blank, new State to fill in.
		local state = StateType.luaalloc():luainit()
		trace.args[1] = state
		-- Rerun
		trace:run()
		-- Overwrite old sample value in the generations vector
		local sample = outgenerations:get(tonumber(outgenerations:size())-1):get(index)
		sample.value:copy(state:getMesh())
		-- Allow the state to be GC'ed
		trace.args[1] = nil
	end
end

---------------------------------------------------------------

return
{
	Sample = terralib.require("qs").Sample(Mesh),
	SIR = SIR,
	MH = MH,
	ForwardSample = ForwardSample,
	RejectionSample = RejectionSample,
	HighResRerunRecordedTrace = HighResRerunRecordedTrace
}





