local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local Mesh = terralib.require("mesh")(double)
local Vec3 = terralib.require("linalg.vec")(double, 3)
local BBox3 = terralib.require("bbox")(Vec3)
local BinaryGrid = terralib.require("binaryGrid3d")
local smc = terralib.require("lua.smc")

-- Still using the same global config, for now
local globals = terralib.require("globals")

---------------------------------------------------------------

-- The procedural-modeling specific state that gets cached with
--    every particle/trace. Stores the mesh-so-far and the
--    grid-so-far, etc.
local struct State(S.Object)
{
	mesh: Mesh
	tmpmesh: Mesh
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

terra State:update(newgeo: &Mesh)
	self.hasSelfIntersections =
		self.hasSelfIntersections or newgeo:intersects(self.mesh)
	if not self.hasSelfIntersections then
		self.grid:resize(globals.targetGrid.rows,
						 globals.targetGrid.cols,
						 globals.targetGrid.slices)
		var nout = newgeo:voxelize(&self.grid, &globals.targetBounds,
								   globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
		self.outsideTris = self.outsideTris + nout
	end
	self.mesh:append(newgeo)
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
		var tmpmesh = Mesh.salloc():init()
		geofn(tmpmesh, [asyms])
		globalState:update(tmpmesh)
	end
	-- Now we wrap this in a Lua function that checks whether this work
	--    needs to be done at all
	return function(...)
		if smc.willStopAtNextSync() then
			dowork(...)
		end
		smc.sync()
	end
end

---------------------------------------------------------------

-- Wrap a generative procedural modeling function such that it takes
--    a State as an argument and does the right thing with it.
local function program(fn)
	return function(state)
		local prevstate = globalState:get()
		globalState:set(state)
		fn()
		globalState:set(prevstate)
	end
end

---------------------------------------------------------------

-- Run sequential importance sampling on a procedural modeling program,
--    saving the generated meshes




