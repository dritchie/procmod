local Mesh = terralib.require("mesh")

-- Anything that needs to be global to multiple files

local G = {}


-- Constants
G.VOXEL_SIZE = 0.25
G.BOUNDS_EXPAND = 0.1
G.SOLID_VOXELIZE = true
-- local TARGET_MESH = "geom/shipProxy1.obj"
local TARGET_MESH = "geom/shipProxy2.obj"


-- Globals
G.targetMesh = global(Mesh(double))


local terra initglobals()
	G.targetMesh:init()
	G.targetMesh:loadOBJ(TARGET_MESH)
end
initglobals()


return G