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
	G.targetBounds:expand(G.BOUNDS_EXPAND)
	G.targetGrid:init()
	G.targetMesh:voxelize(&G.targetGrid, &G.targetBounds, G.VOXEL_SIZE, G.SOLID_VOXELIZE)

end
initglobals()


return G