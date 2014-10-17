local S = terralib.require("qs.lib.std")
local qs = terralib.require("qs")
local globals = terralib.require("globals")
local gl = terralib.require("gl.gl")
local glutils = terralib.require("gl.glutils")
local Mesh = terralib.require("mesh")
local Vec = terralib.require("linalg.vec")
local BinaryGrid = terralib.require("binaryGrid3d")
local BBox = terralib.require("bbox")


local C = terralib.includecstring [[
#include <string.h>
]]

gl.exposeConstants({
	"GLUT_LEFT_BUTTON",
	"GLUT_MIDDLE_BUTTON",
	"GLUT_RIGHT_BUTTON",
	"GLUT_UP",
	"GLUT_DOWN",
	"GL_POLYGON_OFFSET_FILL",
	"GLUT_ACTIVE_ALT",
	"GL_VIEWPORT",
	"GLUT_KEY_LEFT",
	"GLUT_KEY_RIGHT",
	{"GLUT_BITMAP_HELVETICA_18", "void*"}
})


-- Typedefs
local Vec3 = Vec(double, 3)
local BBox3 = BBox(Vec3)
local Sample = qs.Sample(Mesh(double))
local Samples = S.Vector(Sample)

-- Constants
local GENERATE_FILE = "generate.t"
local INITIAL_RES = 800
local ORBIT_SPEED = 0.01
local DOLLY_SPEED = 0.01
local ZOOM_SPEED = 0.02
local LINE_WIDTH = 2.0
local TEXT_FONT = gl.mGLUT_BITMAP_HELVETICA_18()
local TEXT_COLOR = {1.0, 1.0, 1.0}

-- Globals
local generate = global({&Samples}->{}, 0)
local samples = global(Samples)
local currSampleIndex = global(int, 0)
local voxelMesh = global(Mesh(double))
local displayMesh = global(&Mesh(double), 0)
local bounds = global(BBox3)
local camera = global(glutils.Camera(double))
local light = global(glutils.Light(double))
local material = global(glutils.Material(double))
local prevx = global(int)
local prevy = global(int)
local alt = global(bool, 0)
local prevbutton = global(int)
local shouldDrawGrid = global(bool, 0)
local shouldDrawText = global(bool, 1)


local terra updateBounds()
	bounds = displayMesh:bbox()
	bounds:expand(globals.BOUNDS_EXPAND)
end


local terra displayTargetMesh()
	displayMesh = &globals.targetMesh
	updateBounds()
	gl.glutPostRedisplay()
end


local terra displayNormalMesh()
	displayMesh = &(samples(currSampleIndex).value)
	updateBounds()
	gl.glutPostRedisplay()
end


local terra displayVoxelMesh()
	-- Don't do this if the display mesh is nil.
	-- Don't do this if the voxel mesh is currently displayed, because
	--    that would lead to wonky double voxelization
	if displayMesh ~= nil and displayMesh ~= &voxelMesh then
		var grid = BinaryGrid.salloc():init()
		displayMesh:voxelize(grid, &bounds, globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
		[BinaryGrid.toMesh(double)](grid, &voxelMesh, &bounds)
		displayMesh = &voxelMesh
		gl.glutPostRedisplay()
	end
end


-- Lua callback to reload and 'hot swap' the procedural generation code.
local function reloadCode()
	local function doReload()
		local modulefn, err = terralib.loadfile(GENERATE_FILE)
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
	-- print("Procedural modeling code reloaded.")
	return true
end
local reload = terralib.cast({}->bool, reloadCode)


local terra regen()
	-- Only generate if the generate fn pointer is not nil.
	if generate ~= nil then
		samples:clear()
		generate(&samples)
		-- Set the curr mesh index to that of the MAP sample
		var bestscore = [-math.huge]
		for i=0,samples:size() do
			var s = samples:get(i)
			if s.logprob > bestscore then
				bestscore = s.logprob
				currSampleIndex = i
			end
		end
		displayNormalMesh()
	end
end


local terra reloadCodeAndRegen()
	if reload() then regen() end
end


local terra init()
	gl.glClearColor(0.2, 0.2, 0.2, 1.0)
	gl.glEnable(gl.mGL_DEPTH_TEST())
	-- gl.glEnable(gl.mGL_CULL_FACE())
	gl.glEnable(gl.mGL_NORMALIZE())

	samples:init()
	voxelMesh:init()
	camera:init()
	light:init()
	material:init()

	reload()
end


local terra shadingMeshDrawPass()
	gl.glEnable(gl.mGL_LIGHTING())
	gl.glShadeModel(gl.mGL_FLAT())
	gl.glPolygonMode(gl.mGL_FRONT_AND_BACK(), gl.mGL_FILL())
	-- Offset solid face pass so that we can render lines on top
	gl.glEnable(gl.mGL_POLYGON_OFFSET_FILL())
	gl.glPolygonOffset(1.0, 1.0)	-- are these good numbers? maybe use camera zmin/zmax?

	light:setupGLLight(0)
	material:setupGLMaterial()

	displayMesh:draw()
end


local terra wireframeMeshDrawPass()
	gl.glDisable(gl.mGL_POLYGON_OFFSET_FILL())
	gl.glDisable(gl.mGL_LIGHTING())
	gl.glColor4d(0.0, 0.0, 0.0, 1.0)
	gl.glLineWidth(LINE_WIDTH)
	gl.glPolygonMode(gl.mGL_FRONT_AND_BACK(), gl.mGL_LINE())

	displayMesh:draw()
end

local terra drawGrid()
	gl.glDisable(gl.mGL_POLYGON_OFFSET_FILL())
	gl.glDisable(gl.mGL_LIGHTING())
	gl.glColor4d(1.0, 0.0, 0.0, 1.0)
	gl.glLineWidth(LINE_WIDTH)
	gl.glPolygonMode(gl.mGL_FRONT_AND_BACK(), gl.mGL_LINE())
	var extents = bounds:extents()
	var numvox = (extents / globals.VOXEL_SIZE):ceil()
	var xsize = extents(0) / numvox(0)
	var ysize = extents(1) / numvox(1)
	var zsize = extents(2) / numvox(2)
	gl.glMatrixMode(gl.mGL_MODELVIEW())
	gl.glPushMatrix()
	gl.glTranslated(bounds.mins(0), bounds.mins(1), bounds.mins(2))
	gl.glScaled(xsize, ysize, zsize)
	for xi=0,uint(numvox(0)) do
		var x = double(xi)
		for yi=0,uint(numvox(1)) do
			var y = double(yi)
			for zi=0,uint(numvox(2)) do
				var z = double(zi)
				gl.glBegin(gl.mGL_QUADS())
					-- Face
					gl.glVertex3d(x, y, z)
					gl.glVertex3d(x, y, z+1)
					gl.glVertex3d(x, y+1, z+1)
					gl.glVertex3d(x, y+1, z)
					-- Face
					gl.glVertex3d(x, y, z)
					gl.glVertex3d(x, y, z+1)
					gl.glVertex3d(x+1, y, z+1)
					gl.glVertex3d(x+1, y, z)
					-- Face
					gl.glVertex3d(x, y, z)
					gl.glVertex3d(x, y+1, z)
					gl.glVertex3d(x+1, y+1, z)
					gl.glVertex3d(x+1, y, z)
					-- Face
					gl.glVertex3d(x+1, y+1, z+1)
					gl.glVertex3d(x+1, y+1, z)
					gl.glVertex3d(x+1, y, z)
					gl.glVertex3d(x+1, y, z+1)
					-- Face
					gl.glVertex3d(x+1, y+1, z+1)
					gl.glVertex3d(x+1, y+1, z)
					gl.glVertex3d(x, y+1, z)
					gl.glVertex3d(x, y+1, z+1)
					-- Face
					gl.glVertex3d(x+1, y+1, z+1)
					gl.glVertex3d(x+1, y, z+1)
					gl.glVertex3d(x, y, z+1)
					gl.glVertex3d(x, y+1, z+1)
				gl.glEnd()
			end
		end
	end
	gl.glPopMatrix()
end


local terra toggleGrid()
	if displayMesh ~= nil then
		shouldDrawGrid = not shouldDrawGrid
		gl.glutPostRedisplay()
	end
end

local terra displayString(font: &opaque, str: rawstring, x: int, y: int)
	if str ~= nil and C.strlen(str) > 0 then
		gl.glRasterPos2f(x, y)
		while @str ~= 0 do
			gl.glutBitmapCharacter(font, @str)
			str = str + 1
		end
	end
end

local terra drawText()
	-- Set up the viewing transform
	gl.glMatrixMode(gl.mGL_PROJECTION())
	gl.glPushMatrix()
	gl.glLoadIdentity()
	var viewport : int[4]
	gl.glGetIntegerv(gl.mGL_VIEWPORT(), viewport)
	gl.gluOrtho2D(double(viewport[0]), double(viewport[2]), double(viewport[1]), double(viewport[3]))
	gl.glMatrixMode(gl.mGL_MODELVIEW())
	gl.glPushMatrix()
	gl.glLoadIdentity()
	-- Prep some convenient 'local' coordinates
	var xstart = 10
	var ystart = viewport[1] + viewport[3] - 25
	-- Display the mesh index
	var str : int8[64]
	if displayMesh == &globals.targetMesh then
		S.sprintf(str, "Target Shape")
	elseif displayMesh == &voxelMesh then
		S.sprintf(str, "Voxelization")
	elseif samples:size() == 0 then
		S.sprintf(str, "<No Active Mesh>")
	else
		S.sprintf(str, "Sample %d/%u", currSampleIndex+1, samples:size())
	end
	gl.glColor3f([TEXT_COLOR])
	displayString(TEXT_FONT, str, xstart, ystart)
	gl.glPopMatrix()
	gl.glMatrixMode(gl.mGL_PROJECTION())
	gl.glPopMatrix()
end


local terra toggleText()
	shouldDrawText = not shouldDrawText
	gl.glutPostRedisplay()
end


local terra display()
	gl.glClear(gl.mGL_COLOR_BUFFER_BIT() or gl.mGL_DEPTH_BUFFER_BIT())

	if displayMesh ~= nil then
		shadingMeshDrawPass()
		wireframeMeshDrawPass()
	end
	if shouldDrawGrid then
		drawGrid()
	end
	if shouldDrawText then
		drawText()
	end

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
		alt = (gl.glutGetModifiers() == gl.mGLUT_ACTIVE_ALT())
	end
end


local terra cameraMotion(x: int, y: int)
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


local terra setSampleIndex(i: int)
	if i < 0 then i = 0 end
	if i >= samples:size() then i = samples:size()-1 end
	currSampleIndex = i
	displayNormalMesh()
end


local terra sampleIndexScrub(x: int, y: int)
	if prevbutton == gl.mGLUT_LEFT_BUTTON() and samples:size() > 0 then
		var viewport : int[4]
		gl.glGetIntegerv(gl.mGL_VIEWPORT(), viewport)
		var w = viewport[2]
		if x < 0 then x = 0 end
		if x >= w then x = w-1 end
		var t = double(x)/w
		var i = uint(t*samples:size())
		setSampleIndex(i)
	end
end


local terra motion(x: int, y: int)
	-- If Alt is down, then we use horizontal position to select
	--    currSampleIndex.
	if alt then
		sampleIndexScrub(x, y)
	-- Otherwise, we do mouse movement
	else
		cameraMotion(x, y)
	end
end

local char = macro(function(str) return `str[0] end)
local terra keyboard(key: uint8, x: int, y: int)
	if key == char('r') then
		regen()
	elseif key == char('l') then
		reloadCodeAndRegen()
	elseif key == char('g') then
		toggleGrid()
	elseif key == char('n') then
		displayNormalMesh()
	elseif key == char('v') then
		displayVoxelMesh()
	elseif key == char('t') then
		displayTargetMesh()
	end
end


local terra special(key: int, x: int, y: int)
	if key == gl.mGLUT_KEY_LEFT() then
		setSampleIndex(currSampleIndex - 1)
	elseif key == gl.mGLUT_KEY_RIGHT() then
		setSampleIndex(currSampleIndex + 1)
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
	gl.glutSpecialFunc(special)

	init()
	gl.glutMainLoop()

end


main()





