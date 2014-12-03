local S = terralib.require("qs.lib.std")
local LS = terralib.require("std")
local Mesh = terralib.require("geometry.mesh")(double)
local BinaryGrid = terralib.require("geometry.binaryGrid3d")
local Vec3 = terralib.require("linalg.vec")(double, 3)
local BBox3 = terralib.require("geometry.bbox")(Vec3)
local Config = terralib.require("config")
local glutils = terralib.require("gl.glutils")



-- Anything that needs to be global to multiple files goes in here

local G = {}

-- Global config object which governs system behavior
G.config = Config.alloc():init()

-- Add a custom config parser rule for parsing camera parameters
-- (Any line whose first item contains the word 'camera' and which
--    has the requisite number of following parameters)
G.config:addrule(function(self, tokens)
	local key = tokens[1]
	if (string.find(key, "camera") or string.find(key, "Camera")) and #tokens == 17 then
		local eye_x = tonumber(tokens[2])
		local eye_y = tonumber(tokens[3])
		local eye_z = tonumber(tokens[4])
		local target_x = tonumber(tokens[5])
		local target_y = tonumber(tokens[6])
		local target_z = tonumber(tokens[7])
		local up_x = tonumber(tokens[8])
		local up_y = tonumber(tokens[9])
		local up_z = tonumber(tokens[10])
		local wup_x = tonumber(tokens[11])
		local wup_y = tonumber(tokens[12])
		local wup_z = tonumber(tokens[13])
		local fovy = tonumber(tokens[14])
		local aspect = tonumber(tokens[15])
		local znear = tonumber(tokens[16])
		local zfar = tonumber(tokens[17])
		local Camera = glutils.Camera(double)
		self[key] = LS.luainit(LS.luaalloc(Camera),
							   eye_x, eye_y, eye_z,
							   target_x, target_y, target_z,
							   up_x, up_y, up_z,
							   wup_x, wup_y, wup_z,
							   fovy, aspect, znear, zfar)
		return true
	else
		return false
	end
end)

-- We load a config file from the first command line argument, if provided, otherwise
--    we look for configs/scratch.txt
G.config:load(arg[1] or "configs/scratch.txt")


-- Volume match globals
if G.config.doVolumeMatch then
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
end


return G