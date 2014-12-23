local S = terralib.require("qs.lib.std")
local LS = terralib.require("std")
local Mesh = terralib.require("geometry.mesh")(double)
local BinaryGrid3D = terralib.require("geometry.binaryGrid3d")
local BinaryGrid2D = terralib.require("geometry.binaryGrid2d")
local Vec = terralib.require("linalg.vec")
local Vec3 = Vec(double, 3)
local BBox3 = terralib.require("geometry.bbox")(Vec3)
local Config = terralib.require("config")
local gl = terralib.require("gl.gl")
local glutils = terralib.require("gl.glutils")



-- Anything that needs to be global to multiple files goes in here

local G = {}

-- Global config object which governs system behavior
G.config = Config.alloc():init()

-- Add a custom config parser rule parsing vector parameters
G.config:addrule(function(self, tokens)
	local key = tokens[1]
	if tokens[2] == "vec" then
		local x = tonumber(tokens[3])
		local y = tonumber(tokens[4])
		local z = tonumber(tokens[5])
		self[key] = LS.luainit(LS.luaalloc(Vec3), x, y, z)
		return true
	else
		return false
	end
end)

-- Add a custom config parser rule for parsing camera parameters
G.config:addrule(function(self, tokens)
	local key = tokens[1]
	if tokens[2] == "camera" then
		local eye_x = tonumber(tokens[3])
		local eye_y = tonumber(tokens[4])
		local eye_z = tonumber(tokens[5])
		local target_x = tonumber(tokens[6])
		local target_y = tonumber(tokens[7])
		local target_z = tonumber(tokens[8])
		local up_x = tonumber(tokens[9])
		local up_y = tonumber(tokens[10])
		local up_z = tonumber(tokens[11])
		local wup_x = tonumber(tokens[12])
		local wup_y = tonumber(tokens[13])
		local wup_z = tonumber(tokens[14])
		local fovy = tonumber(tokens[15])
		local aspect = tonumber(tokens[16])
		local znear = tonumber(tokens[17])
		local zfar = tonumber(tokens[18])
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
G.config:load(arg[1] or "configs/scratch.config")

--------------------------------------------------------------------------
-- We declare all possible globals and do the minimum initialization here.
--------------------------------------------------------------------------
-- Volume matching
G.matchTargetMesh = global(Mesh)
G.matchTargetGrid = global(BinaryGrid3D)
G.matchTargetBounds = global(BBox3)
-- Volume avoidance
G.avoidTargetMesh = global(Mesh)
G.avoidTargetGrid = global(BinaryGrid3D)
G.avoidTargetBounds = global(BBox3)
-- Image matching
G.matchTargetImage = global(BinaryGrid2D)
-- Shadow matching
G.shadowTargetImage = global(BinaryGrid2D)
G.shadowReceiverGeo = global(Mesh)
local terra initglobals()
	G.matchTargetMesh:init()
	G.matchTargetGrid:init()
	G.matchTargetBounds:init()
	G.avoidTargetMesh:init()
	G.avoidTargetGrid:init()
	G.avoidTargetBounds:init()
	G.matchTargetImage:init()
	G.shadowTargetImage:init()
	G.shadowReceiverGeo:init()
end
initglobals()
--------------------------------------------------------------------------

-- Set up volume matching globals
if G.config.doVolumeMatch then
	local terra initglobals()
		G.matchTargetMesh:loadOBJ(G.config.matchTargetMesh)
		G.matchTargetBounds = G.matchTargetMesh:bbox()
		G.matchTargetBounds:expand(G.config.boundsExpand)
		G.matchTargetMesh:voxelize(&G.matchTargetGrid, &G.matchTargetBounds, G.config.voxelSize, G.config.solidVoxelize)
	end
	initglobals()
end

-- Set up volume avoidance globals
if G.config.doVolumeAvoid then
	local terra initglobals()
		G.avoidTargetMesh:loadOBJ(G.config.avoidTargetMesh)
		G.avoidTargetBounds = G.avoidTargetMesh:bbox()
		G.avoidTargetBounds:expand(G.config.boundsExpand)
		G.avoidTargetMesh:voxelize(&G.avoidTargetGrid, &G.avoidTargetBounds, G.config.voxelSize, G.config.solidVoxelize)
	end
	initglobals()
end

-- Utility for image/shadow matching stuff
local terra makeFBO(w: uint, h: uint)
	-- Color buffer
	var colorTex : uint
	gl.glGenTextures(1, &colorTex)
	gl.glBindTexture(gl.GL_TEXTURE_2D, colorTex)
	gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA,
					w, h,
					0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, nil)
	gl.glBindTexture(gl.GL_TEXTURE_2D, 0)
	-- Depth buffer
	var depthTex: uint
	gl.glGenTextures(1, &depthTex)
	gl.glBindTexture(gl.GL_TEXTURE_2D, depthTex)
	gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_DEPTH_COMPONENT,
					w, h,
					0, gl.GL_DEPTH_COMPONENT, gl.GL_FLOAT, nil)
	gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
	gl.glBindTexture(gl.GL_TEXTURE_2D, 0)
	-- Framebuffer
	var fbo : uint
	gl.glGenFramebuffers(1, &fbo)
	gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo)
	gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER,
							  gl.GL_COLOR_ATTACHMENT0,
							  gl.GL_TEXTURE_2D,
							  colorTex, 0)
	gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER,
							  gl.GL_DEPTH_ATTACHMENT,
							  gl.GL_TEXTURE_2D,
							  depthTex, 0)
	gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0)
	return fbo
end

-- Set up image matching globals
if G.config.doImageMatch then
	-- Delay import of image module until here, because other people have trouble getting FreeImage to work.
	local image = terralib.require("image")
	local terra initglobals()
		-- We assume the target image is specified as an 8-bit RGB PNG file.
		var img = [image.Image(uint8, 3)].salloc():init(image.Format.PNG, G.config.matchTargetImage)
		-- Convert the image into a binary grid by quantizing pixels to 1 bit
		G.matchTargetImage:resize(img.height, img.width)
		for row=0,img.height do
			for col=0,img.width do
				if img(col, row)(0) > 0 then
					G.matchTargetImage:setPixel(row, col)
				end
			end
		end
	end
	initglobals()
	-- Provide a special framebuffer that image matching can use
	-- Have to defer initialization of this framebuffer until after the
	--    OpenGL context has been set up.
	local matchRenderFBO = global(uint)
	local matchRenderFBOisInitialized = global(bool, 0)
	G.getMatchRenderFBO = macro(function()
		return quote
			if not matchRenderFBOisInitialized then
				matchRenderFBOisInitialized = true
				matchRenderFBO = makeFBO(G.matchTargetImage.cols, G.matchTargetImage.rows)
			end
		in
			matchRenderFBO
		end
	end)
end

-- Compile a shader program given paths to a vertex and fragment shader
local terra compileShader(srcfile: rawstring, typ: int)
	-- Load source from file
	var f = S.fopen(srcfile, "rb")
	S.fseek(f, 0, S.SEEK_END)
	var fsize = S.ftell(f)
	S.fseek(f, 0, S.SEEK_SET)
	var src = rawstring(S.malloc(fsize+1))
	S.fread(src, fsize, 1, f)
	S.fclose(f)
	src[fsize] = 0

	-- Create shader
	var shader = gl.glCreateShader(typ)
	-- Send src to GL
	gl.glShaderSource(shader, 1, &src, nil)
	-- Compile
	gl.glCompileShader(shader)
	S.free(src)

	-- Error checking
	var isCompiled = 0
	gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &isCompiled)
	if isCompiled == gl.GL_FALSE then
		var maxLength = 0
		gl.glGetShaderiv(shader, gl.GL_INFO_LOG_LENGTH, &maxLength)
		var infoLog = rawstring(S.malloc(maxLength))
		gl.glGetShaderInfoLog(shader, maxLength, &maxLength, infoLog)
		gl.glDeleteShader(shader)
		S.printf("Error compiling shader '%s':\n%s\n", srcfile, infoLog)
		S.free(infoLog)
		S.assert(false)
	end

	return shader
end
local terra compileShaderProgram(vertfile: rawstring, fragfile: rawstring)
	-- Compile vertex shader
	var vertexShader = compileShader(vertfile, gl.GL_VERTEX_SHADER)
	-- Compile fragment shader
	var fragmentShader = compileShader(fragfile, gl.GL_FRAGMENT_SHADER)

	-- Create program
	var program  = gl.glCreateProgram()
	-- Attach shaders to program
	gl.glAttachShader(program, vertexShader)
	gl.glAttachShader(program, fragmentShader)
	-- Link program
	gl.glLinkProgram(program)

	-- Error checking
	var isLinked = 0
	gl.glGetProgramiv(program, gl.GL_LINK_STATUS, &isLinked)
	if isLinked == gl.GL_FALSE then
		var maxLength = 0
		gl.glGetProgramiv(program, gl.GL_INFO_LOG_LENGTH, &maxLength)
		var infoLog = rawstring(S.malloc(maxLength))
		gl.glGetProgramInfoLog(program, maxLength, &maxLength, infoLog)
		gl.glDeleteProgram(program)
		gl.glDeleteShader(vertexShader)
		gl.glDeleteShader(fragmentShader)
		S.printf("Error linking shader program:\n%s\n", infoLog)
		S.free(infoLog)
		S.assert(false)
	end

	gl.glDetachShader(program, vertexShader)
	gl.glDetachShader(program, fragmentShader)
	gl.glDeleteShader(vertexShader)
	gl.glDeleteShader(fragmentShader)

	return program
end

-- Set up shadow matching globals
if G.config.doShadowMatch then
	-- Delay import of image module until here, because other people have trouble getting FreeImage to work.
	local image = terralib.require("image")
	G.shadowWeightImage = global(image.Image(float, 1))
	local terra initglobals()
		-- We assume the target image is specified as an 8-bit RGB PNG file.
		var img = [image.Image(uint8, 3)].salloc():init(image.Format.PNG, G.config.shadowTargetImage)
		-- Convert the image into a binary grid by quantizing pixels to 1 bit
		G.shadowTargetImage:resize(img.height, img.width)
		for row=0,img.height do
			for col=0,img.width do
				if img(col, row)(0) > 0 then
					G.shadowTargetImage:setPixel(row, col)
				end
			end
		end
		-- If specified, load up an image containing weights for the target image.
		escape
			if G.config.shadowWeightImage then
				emit quote
					G.shadowWeightImage:init(image.Format.PNG, G.config.shadowWeightImage)
					for y=0,G.shadowWeightImage.height do
						for x=0,G.shadowWeightImage.width do
							var val = G.shadowWeightImage(x,y)(0)
							G.shadowWeightImage(x,y)(0) = 1.0 + G.config.shadowWeightMult*val
						end
					end
				end
			else
				emit quote
					G.shadowWeightImage:init(img.width, img.height, [Vec(float, 1)].create(1.0))
				end
			end
		end
		-- Also load up the receiver geometry
		G.shadowReceiverGeo:loadOBJ(G.config.shadowReceiverGeo)
	end
	initglobals()
	-- Setup FBO for shadow maps
	local shadowMapFBO = global(uint)
	local shadowMapFBOisInitialized = global(bool, 0)
	G.getShadowMapFBO = macro(function()
		return quote
			if not shadowMapFBOisInitialized then
				shadowMapFBOisInitialized = true
				shadowMapFBO = makeFBO(G.config.shadowMapRes, G.config.shadowMapRes)
			end
		in
			shadowMapFBO
		end
	end)
	-- Setup FBO for shadow matching
	local shadowMatchFBO = global(uint)
	local shadowMatchFBOisInitialized = global(bool, 0)
	G.getShadowMatchFBO = macro(function()
		return quote
			if not shadowMatchFBOisInitialized then
				shadowMatchFBOisInitialized = true
				shadowMatchFBO = makeFBO(G.shadowTargetImage.cols, G.shadowTargetImage.rows)
			end
		in
			shadowMatchFBO
		end
	end)
	-- Setup shader program for the rendering pass
	local renderProgram = global(uint)
	local renderProgramIsInitialized = global(bool, 0)
	G.getShadowRenderProgram = macro(function()
		return quote
			renderProgramIsInitialized = true
			renderProgram = compileShaderProgram("shaders/shadowRender.vert", "shaders/shadowRender.frag")
		in
			renderProgram
		end
	end)
end


return G




