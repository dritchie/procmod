local S = terralib.require("qs.lib.std")
local gl = terralib.require("gl.gl")
local glutils = terralib.require("gl.glutils")
local Mesh = terralib.require("mesh")
local Vec = terralib.require("linalg.vec")
local BinaryGrid = terralib.require("binaryGrid3d")

local Vec3 = Vec(double, 3)

gl.exposeConstants({
	"GLUT_LEFT_BUTTON",
	"GLUT_MIDDLE_BUTTON",
	"GLUT_RIGHT_BUTTON",
	"GLUT_UP",
	"GLUT_DOWN",
	"GL_POLYGON_OFFSET_FILL"
})


-- Constants
local generateFile = "generate.t"
local INITIAL_RES = 800
local ORBIT_SPEED = 0.01
local DOLLY_SPEED = 0.01
local ZOOM_SPEED = 0.02
local LINE_WIDTH = 2.0
local VOXEL_SIZE = 0.3


-- Globals
local generate = global({&Mesh(double)}->{}, 0)
local mesh = global(Mesh(double))
local camera = global(glutils.Camera(double))
local light = global(glutils.Light(double))
local material = global(glutils.Material(double))
local prevx = global(int)
local prevy = global(int)
local prevbutton = global(int)


-- Lua callback to reload and 'hot swap' the procedural generation code.
local function reloadCode()
	local function doReload()
		local modulefn, err = terralib.loadfile(generateFile)
		if not modulefn then
			error(string.format("Error loading procedural modeling code: %s", err))
		end
		local genfn = modulefn()
		-- TODO: Any way to ensure this doesn't leak?
		generate:set(genfn:getpointer())
	end
	local ok, maybeerr = pcall(doReload)
	if not ok then
		print(string.format("Error compiling procedural modeling code: %s", maybeerr))
		return false
	end
	print("Procedural modeling code reloaded.")
	return true
end
local reload = terralib.cast({}->bool, reloadCode)


local terra regen()
	-- Only generate if the generate fn pointer is not nil.
	if generate ~= nil then
		S.printf("Regenerating.\n")
		generate(&mesh)
		gl.glutPostRedisplay()
	end
end


local terra reloadCodeAndRegen()
	if reload() then regen() end
end


local terra voxelizeMeshAndDisplay()
	S.printf("Voxelizing mesh and displaying.\n")
	var bounds = mesh:bbox()
	var grid = BinaryGrid.salloc():init()
	mesh:voxelize(grid, &bounds, VOXEL_SIZE, false)
	[BinaryGrid.toMesh(double)](grid, &mesh, &bounds)
	gl.glutPostRedisplay()
end


local terra init()
	gl.glClearColor(0.2, 0.2, 0.2, 1.0)
	gl.glEnable(gl.mGL_DEPTH_TEST())
	gl.glEnable(gl.mGL_CULL_FACE())
	gl.glEnable(gl.mGL_NORMALIZE())

	mesh:init()
	camera:init()
	light:init()
	material:init()

	reloadCodeAndRegen()
end


local terra draw()
	mesh:draw()
end


local terra shadingDrawPass()
	gl.glEnable(gl.mGL_LIGHTING())
	gl.glShadeModel(gl.mGL_FLAT())
	gl.glPolygonMode(gl.mGL_FRONT_AND_BACK(), gl.mGL_FILL())
	-- Offset solid face pass so that we can render lines on top
	gl.glEnable(gl.mGL_POLYGON_OFFSET_FILL())
	gl.glPolygonOffset(1.0, 1.0)	-- are these good numbers? maybe use camera zmin/zmax?

	light:setupGLLight(0)
	material:setupGLMaterial()

	draw()
end


local terra wireframeDrawPass()
	gl.glDisable(gl.mGL_POLYGON_OFFSET_FILL())
	gl.glDisable(gl.mGL_LIGHTING())
	gl.glColor4d(0.0, 0.0, 0.0, 1.0)
	gl.glLineWidth(LINE_WIDTH)
	gl.glPolygonMode(gl.mGL_FRONT_AND_BACK(), gl.mGL_LINE())

	draw()
end


local terra display()
	gl.glClear(gl.mGL_COLOR_BUFFER_BIT() or gl.mGL_DEPTH_BUFFER_BIT())

	shadingDrawPass()
	wireframeDrawPass()

	gl.glutSwapBuffers()
end


local terra reshape(w: int, h: int)
	gl.glViewport(0, 0, w, h)
	camera.aspect = double(w) / h
	camera:setupGLPerspectiveView()
	gl.glutPostRedisplay()
end


local terra mouse(button: int, state: int, x: int, y: int)
	if state == gl.mGLUT_DOWN() then
		prevbutton = button
		prevx = x
		prevy = y
	end
end


local terra motion(x: int, y: int)
	var dx = x - prevx
	var dy = y - prevy
	if prevbutton == gl.mGLUT_LEFT_BUTTON() then
		camera:orbitLeft(-dx * ORBIT_SPEED)
		camera:orbitUp(dy * ORBIT_SPEED)
	elseif prevbutton == gl.mGLUT_MIDDLE_BUTTON() then
		camera:dollyLeft(dx * DOLLY_SPEED)
		camera:dollyUp(dy * DOLLY_SPEED)
	elseif prevbutton == gl.mGLUT_RIGHT_BUTTON() then
		var val = dx
		if dy*dy > dx*dx then
			val = dy
		end
		camera:zoom(val * ZOOM_SPEED)
	end
	prevx = x
	prevy = y
	camera:setupGLPerspectiveView()
	gl.glutPostRedisplay()
end

local char = macro(function(str) return `str[0] end)
local terra keyboard(key: uint8, x: int, y: int)
	if key == char('r') then
		regen()
	elseif key == char('l') then
		reloadCodeAndRegen()
	elseif key == char('v') then
		voxelizeMeshAndDisplay()
	end
end


local terra main()

	var argc = 0
	gl.glutInit(&argc, nil)
	gl.glutInitWindowSize(INITIAL_RES, INITIAL_RES)
	gl.glutInitDisplayMode(gl.mGLUT_RGB() or gl.mGLUT_DOUBLE() or gl.mGLUT_DEPTH())
	gl.glutCreateWindow("Procedural Modeling")

	gl.glutReshapeFunc(reshape)
	gl.glutDisplayFunc(display)
	gl.glutMouseFunc(mouse)
	gl.glutMotionFunc(motion)
	gl.glutKeyboardFunc(keyboard)

	init()
	gl.glutMainLoop()

end


main()





