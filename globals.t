local S = terralib.require("qs.lib.std")
local Mesh = terralib.require("geometry.mesh")(double)
local BinaryGrid = terralib.require("geometry.binaryGrid3d")
local Vec3 = terralib.require("linalg.vec")(double, 3)
local BBox3 = terralib.require("geometry.bbox")(Vec3)
local Config = terralib.require("config")



-- Anything that needs to be global to multiple files goes in here

local G = {}

-- We load a config file from the first command line argument, if provided, otherwise
--    we look for configs/scratch.txt
G.config = Config.alloc():init(arg[1] or "configs/scratch.txt")

-- Globals
G.targetMesh = global(Mesh)
G.targetGrid = global(BinaryGrid)
G.targetBounds = global(BBox3)


local terra initglobals()
	G.targetMesh:init()
	G.targetMesh:loadOBJ(G.config.targetMesh)
	G.targetBounds = G.targetMesh:bbox()
	G.targetBounds:expand(G.config.boundsExpand)
	G.targetGrid:init()
	G.targetMesh:voxelize(&G.targetGrid, &G.targetBounds, G.config.voxelSize, G.config.solidVoxelize)

end
initglobals()


return G