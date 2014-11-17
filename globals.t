local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("mesh")(double)
local BinaryGrid = terralib.require("binaryGrid3d")
local Vec3 = terralib.require("linalg.vec")(double, 3)
local BBox3 = terralib.require("bbox")(Vec3)

-- Anything that needs to be global to multiple files

local G = {}


-- Constants
G.VOXEL_SIZE = 0.25
G.BOUNDS_EXPAND = 0.1
G.SOLID_VOXELIZE = true
-- local TARGET_MESH = "geom/shipProxy1.obj"
local TARGET_MESH = "geom/shipProxy2.obj"


-- Globals
G.targetMesh = global(Mesh)
G.targetGrid = global(BinaryGrid)
G.targetBounds = global(BBox3)


local terra initglobals()
	G.targetMesh:init()
	G.targetMesh:loadOBJ(TARGET_MESH)
	G.targetBounds = G.targetMesh:bbox()

	-- -- TEST
	-- var paddedBounds, gridres, targetGridBounds = BinaryGrid.paddedGridBounds(&G.targetBounds, 0.5, G.VOXEL_SIZE)
	-- S.printf("targetBounds: (%g, %g, %g) to (%g, %g, %g)\n",
	-- 	G.targetBounds.mins(0), G.targetBounds.mins(1), G.targetBounds.mins(2),
	-- 	G.targetBounds.maxs(0), G.targetBounds.maxs(1), G.targetBounds.maxs(2))
	-- S.printf("paddedBounds: (%g, %g, %g) to (%g, %g, %g)\n",
	-- 	paddedBounds.mins(0), paddedBounds.mins(1), paddedBounds.mins(2),
	-- 	paddedBounds.maxs(0), paddedBounds.maxs(1), paddedBounds.maxs(2))
	-- S.printf("gridres: %u, %u, %u\n", gridres(0), gridres(1), gridres(2))
	-- S.printf("targetGridBounds: (%u, %u, %u) to (%u, %u, %u)\n",
	-- 	targetGridBounds.mins(0), targetGridBounds.mins(1), targetGridBounds.mins(2),
	-- 	targetGridBounds.maxs(0), targetGridBounds.maxs(1), targetGridBounds.maxs(2))

	G.targetBounds:expand(G.BOUNDS_EXPAND)
	G.targetGrid:init()
	G.targetMesh:voxelize(&G.targetGrid, &G.targetBounds, G.VOXEL_SIZE, G.SOLID_VOXELIZE)

end
initglobals()


return G