local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local Mesh = terralib.require("mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local BBox3 = terralib.require("bbox")(Vec3)
local BinaryGrid = terralib.require("binaryGrid3d")
local trace = terralib.require("lua.trace")
local smc = terralib.require("lua.smc")
local distrib = terralib.require("qs.distrib")

-- Still using the same global config, for now
local globals = terralib.require("globals")

---------------------------------------------------------------

local VOXEL_FACTOR_WEIGHT = 0.01
local OUTSIDE_FACTOR_WEIGHT = 0.01

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
	addmesh: Mesh
	grid: BinaryGrid
	outsideTris: uint
	hasSelfIntersections: bool
}
-- Also give the State class all the lua.std metatype stuff
LS.Object(State)

terra State:__init()
	self:initmembers()
	self.outsideTris = 0
	self.hasSelfIntersections = false
end

-- Returns the new score
terra State:update()
	self.hasSelfIntersections =
		self.hasSelfIntersections or self.addmesh:intersects(&self.mesh)
	if not self.hasSelfIntersections then
		self.grid:resize(globals.targetGrid.rows,
						 globals.targetGrid.cols,
						 globals.targetGrid.slices)
		var nout = self.addmesh:voxelize(&self.grid, &globals.targetBounds,
								   globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
		self.outsideTris = self.outsideTris + nout
	end
	self.mesh:append(&self.addmesh)
	-- Compute and return score
	if self.hasSelfIntersections then
		return [-math.huge]
	else
		var percentSame = globals.targetGrid:percentCellsEqual(&self.grid)
		var percentOutside = double(self.outsideTris) / self.mesh:numTris()
		return softeq(percentSame, 1.0, VOXEL_FACTOR_WEIGHT) +
			   softeq(percentOutside, 0.0, OUTSIDE_FACTOR_WEIGHT)
	end
end

-- State for the currently executing program
local globalState = global(&State, 0)

---------------------------------------------------------------

-- Make a new SMC-integrated geometry primitive out of a function that
--    takes a mesh (plus some other primitive-type args) and adds geometry
--    to that mesh.
local function makeGeoPrim(geofn)
	-- First, we make a Terra function that does all the perf-critical stuff:
	--    creates new geometry, tests for intersections, voxelizes, etc.
	local paramtypes = geofn:gettype().parameters
	local asyms = terralib.newlist()
	for i=2,#paramtypes do 	 -- Skip first arg (the mesh itself)
		asyms:insert(symbol(paramtypes[i]))
	end
	local terra dowork([asyms])
		globalState.addmesh:clear()
		geofn(&globalState.addmesh, [asyms])
		return globalState:update()
	end
	-- Now we wrap this in a Lua function that checks whether this work
	--    needs to be done at all
	return function(...)
		if smc.willStopAtNextSync() then
			local score = dowork(...)
			trace.likelihood(score)
		end
		smc.sync()
	end
end

---------------------------------------------------------------

-- Wrap a generative procedural modeling function such that it takes
--    a State as an argument and does the right thing with it.
local function statewrap(fn)
	return function(state)
		local prevstate = globalState:get()
		globalState:set(state)
		fn()
		globalState:set(prevstate)
	end
end

---------------------------------------------------------------

-- Copy meshes from a Lua table of smc Particles to a cdata Vector of Sample(Mesh)
local function copyMeshes(particles, outgenerations)
	local newgeneration = outgenerations:insert()
	LS.luainit(newgeneration)
	for _,p in ipairs(particles) do
		local samp = newgeneration:insert()
		-- The first arg of the particle's trace is the procmod State object.
		-- This is a bit funky, but I think it's the best way to get a this data.
		samp.value:copy(p.trace.args[1].mesh)
		samp.logprob = p.trace.logposterior
		samp.loglikelihood = p.trace.loglikelihood
	end
end

-- Run sequential importance sampling on a procedural modeling program,
--    saving the generated meshes
-- 'outgenerations' is a cdata Vector(Vector(Sample(Mesh)))
-- Options are:
--    * recordHistory: record meshes all the way through, not just the final ones
--    * any other options recognized by smc.SIR
local function SIR(program, outgenerations, opts)
	-- Wrap program so that it takes procmod State as argument
	program = statewrap(program)
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
	smc.SIR(program, {State.luaalloc():luainit()}, newopts)
end

---------------------------------------------------------------

return
{
	-- State = State,
	Sample = terralib.require("qs").Sample(Mesh),
	makeGeoPrim = makeGeoPrim,
	SIR = SIR
}





