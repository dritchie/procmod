local S = require("qs.lib.std")
local qs = require("qs")
local globals = require("globals")
local gl = require("gl.gl")
local glutils = require("gl.glutils")
local Mesh = require("geometry.mesh")
local Vec = require("linalg.vec")
local BinaryGrid = require("geometry.binaryGrid3d")
local BBox = require("geometry.bbox")
local shadowmap = require("shadowmap")


local C = terralib.includecstring [[
#include <string.h>
]]

gl.exposeConstants({
	{"GLUT_BITMAP_HELVETICA_18", "void*"}
})


-- Typedefs
local Vec3 = Vec(double, 3)
local BBox3 = BBox(Vec3)
local Sample = qs.Sample(Mesh(double))
local Samples = S.Vector(Sample)
local Generations = S.Vector(Samples)

-- Constants
local GENERATE_FILE = "generate.t"
local INITIAL_RES = 800
local ORBIT_SPEED = 0.01
local DOLLY_SPEED = 0.01
local ZOOM_SPEED = 0.02
local LINE_WIDTH = 2.0
local TEXT_FONT = gl.mGLUT_BITMAP_HELVETICA_18()
local TEXT_COLOR = {1.0, 1.0, 1.0}
local MIN_SCORE_COLOR = {1.0, 0.0, 0.0}
local MAX_SCORE_COLOR = {0.0, 1.0, 0.0}

-- Globals
local generate = global({&Generations}->{}, nil)
local highResRegen = global({&Generations, uint}->{}, nil)
local generations = global(Generations)
local currGenIndex = global(int, 0)
local samples = global(&Samples, nil)
local currSampleIndex = global(int, 0)
local MAPIndex = global(int)
local displayMesh = global(&Mesh(double), nil)
local voxelMesh = global(Mesh(double))
local voxelAvoidMesh = global(Mesh(double))
local checkingForSelfIntersections = global(bool, false)
local intersectionMesh = global(Mesh(double))
local meshSelfIntersects = global(bool, false)
local bounds = global(BBox3)
local camera = global(glutils.Camera(double))
local light = global(glutils.Light(double))
local material = global(glutils.Material(double))
local prevx = global(int)
local prevy = global(int)
local alt = global(bool, false)
local prevbutton = global(int)
local shouldDrawGrid = global(bool, false)
local shouldDrawOverlay = global(bool, true)
local shouldDrawAvoidMesh = global(bool, false)
local minScore = global(double)
local maxScore = global(double)
local voxelizeUsingTargetBounds = global(bool, false)




local terra updateBounds()
	if voxelizeUsingTargetBounds then
		bounds = globals.matchTargetMesh:bbox()
	else
		bounds = displayMesh:bbox()
	end
	bounds:expand(globals.config.boundsExpand)
	-- var dims = bounds:extents()
	-- S.printf("dims: %g, %g, %g\n", dims(0), dims(1), dims(2))
end


local terra displayTargetMesh()
	displayMesh = &globals.matchTargetMesh
	updateBounds()
	gl.glutPostRedisplay()
end

local terra displayNormalMesh()
	if samples ~= nil then
		displayMesh = &(samples(currSampleIndex).value)
		updateBounds()
	else
		displayMesh = nil
	end
	voxelAvoidMesh:clear()
	gl.glutPostRedisplay()
end


local terra displayIntersectionMesh()
	displayMesh = &intersectionMesh
	updateBounds()
	gl.glutPostRedisplay()
end


local terra displayVoxelMesh()
	-- Don't do this if the display mesh is nil.
	-- Don't do this if the voxel mesh is currently displayed, because
	--    that would lead to wonky double voxelization
	if displayMesh ~= nil and displayMesh ~= &voxelMesh then
		var grid = BinaryGrid.salloc():init()
		var vbounds = bounds
		-- If we're displaying the avoid mesh, it's more informative to voxelize the display mesh
		--    against those bounds than against its own.
		if shouldDrawAvoidMesh and globals.avoidTargetMesh:numTris() > 0 then
			vbounds = globals.avoidTargetMesh:bbox()
			vbounds:expand(globals.config.boundsExpand)
		end
		displayMesh:voxelize(grid, &vbounds, globals.config.voxelSize, globals.config.solidVoxelize)
		[BinaryGrid.toMesh(double)](grid, &voxelMesh, &vbounds)
		displayMesh = &voxelMesh
		gl.glutPostRedisplay()
	end
	-- Also voxelize the avoid mesh, if we're displaying it and it has contents.
	if shouldDrawAvoidMesh and globals.avoidTargetMesh:numTris() > 0 then
		var bounds = globals.avoidTargetMesh:bbox()
		bounds:expand(globals.config.boundsExpand)
		var grid = BinaryGrid.salloc():init()
		globals.avoidTargetMesh:voxelize(grid, &bounds, globals.config.voxelSize, globals.config.solidVoxelize)
		[BinaryGrid.toMesh(double)](grid, &voxelAvoidMesh, &bounds)
		gl.glutPostRedisplay()
	end
end


local terra setSampleIndex(i: int)
	if samples ~= nil then
		if i < 0 then i = samples:size()-1 end
		if i >= samples:size() then i = 0 end
		currSampleIndex = i
		if checkingForSelfIntersections then
			intersectionMesh:clear()
			meshSelfIntersects = samples(currSampleIndex).value:findAllSelfIntersectingTris(&intersectionMesh)
		end
		displayNormalMesh()
	end
end


local terra setGenerationIndex(i: int, setSampIndexToMAP: bool)
	if generations:size() > 0 then
		if i < 0 then i = generations:size()-1 end
		if i >= generations:size() then i = 0 end
		currGenIndex = i
		samples = generations:get(i)

		-- Set the curr mesh index to that of the MAP sample
		maxScore = [-math.huge]
		minScore = [math.huge]
		for i=0,samples:size() do
			var s = samples:get(i)
			if s.logprob > maxScore then
				maxScore = s.logprob
				MAPIndex = i
			end
			if s.logprob < minScore then
				minScore = s.logprob
			end
		end
		if setSampIndexToMAP then
			currSampleIndex = MAPIndex
		end
		setSampleIndex(currSampleIndex)
	end
end

-- Lua callback to reload and 'hot swap' the procedural generation code.
local genref = nil
local hiresref = nil
local function reloadCode()
	local function doReload()
		local modulefn, err = terralib.loadfile(GENERATE_FILE)
		if not modulefn then
			error(string.format("Error loading procedural modeling code: %s", err))
		end
		local mod = modulefn()
		genref = mod.generate
		generate:set(genref:getpointer())
		hiresref = mod.highResRerun
		highResRegen:set(hiresref:getpointer())
	end
	local ok, maybeerr = pcall(doReload)
	if not ok then
		print("--------------------------------")
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
		generate(&generations)
		setGenerationIndex(generations:size()-1, true)
	end
end


local terra reloadCodeAndRegen()
	if reload() then regen() end
end


local terra regenCurrMeshAtHighRes()
	if displayMesh ~= nil and generations:size() > 0 then
		highResRegen(&generations, currSampleIndex)
		displayNormalMesh()
	end
end


local terra init()
	gl.glEnable(gl.GL_DEPTH_TEST)
	-- gl.glEnable(gl.GL_CULL_FACE)
	gl.glEnable(gl.GL_NORMALIZE)

	generations:init()
	voxelMesh:init()
	voxelAvoidMesh:init()
	intersectionMesh:init()
	light:init()
	material:init()
	escape
		if globals.config.viewCamera then
			emit quote camera:copy(globals.config.viewCamera) end
		else
			emit quote camera:init() end
		end
	end

	reload()
end


local terra shadingMeshDrawPass(mesh: &Mesh(double))
	gl.glEnable(gl.GL_LIGHTING)
	gl.glShadeModel(gl.GL_FLAT)
	gl.glPolygonMode(gl.GL_FRONT_AND_BACK, gl.GL_FILL)
	-- Offset solid face pass so that we can render lines on top
	gl.glEnable(gl.GL_POLYGON_OFFSET_FILL)
	gl.glPolygonOffset(1.0, 1.0)	-- are these good numbers? maybe use camera zmin/zmax?

	light:setupGLLight(0)
	material:setupGLMaterial()

	mesh:draw()
	globals.shadowReceiverGeo:draw()

	gl.glDisable(gl.GL_POLYGON_OFFSET_FILL)
	gl.glDisable(gl.GL_LIGHTING)
end


local terra wireframeMeshDrawPass(mesh: &Mesh(double))
	gl.glColor4d(0.0, 0.0, 0.0, 1.0)
	gl.glLineWidth(LINE_WIDTH)
	gl.glPolygonMode(gl.GL_FRONT_AND_BACK, gl.GL_LINE)

	mesh:draw()

	gl.glPolygonMode(gl.GL_FRONT_AND_BACK, gl.GL_FILL)
end

local terra drawGrid()
	gl.glDisable(gl.GL_POLYGON_OFFSET_FILL)
	gl.glDisable(gl.GL_LIGHTING)
	gl.glColor4d(1.0, 0.0, 0.0, 1.0)
	gl.glLineWidth(LINE_WIDTH)
	gl.glPolygonMode(gl.GL_FRONT_AND_BACK, gl.GL_LINE)
	var extents = bounds:extents()
	var numvox = (extents / globals.config.voxelSize):ceil()
	var xsize = extents(0) / numvox(0)
	var ysize = extents(1) / numvox(1)
	var zsize = extents(2) / numvox(2)
	gl.glMatrixMode(gl.GL_MODELVIEW)
	gl.glPushMatrix()
	gl.glTranslated(bounds.mins(0), bounds.mins(1), bounds.mins(2))
	gl.glScaled(xsize, ysize, zsize)
	for xi=0,uint(numvox(0)) do
		var x = double(xi)
		for yi=0,uint(numvox(1)) do
			var y = double(yi)
			for zi=0,uint(numvox(2)) do
				var z = double(zi)
				gl.glBegin(gl.GL_QUADS)
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

local terra toggleOverlay()
	shouldDrawOverlay = not shouldDrawOverlay
	gl.glutPostRedisplay()
end

local terra toggleTargetBoundsVoxelization()
	voxelizeUsingTargetBounds = not voxelizeUsingTargetBounds
	updateBounds()
	if voxelizeUsingTargetBounds then
		S.printf("Voxelize will now use target mesh bounds\n")
	else
		S.printf("Voxelize will now use display mesh bounds\n")
	end
	gl.glutPostRedisplay()
end

local terra toggleCheckSelfIntersections()
	checkingForSelfIntersections = not checkingForSelfIntersections
	gl.glutPostRedisplay()
end

local terra toggleAvoidMesh()
	shouldDrawAvoidMesh = not shouldDrawAvoidMesh
	gl.glutPostRedisplay()
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

local terra isDisplayingSample()
	return samples ~= nil and
		   displayMesh ~= nil and
		   displayMesh ~= &globals.matchTargetMesh and
		   displayMesh ~= &voxelMesh
end

local terra colorForScore(score: double)
	var t = (score - minScore)/(maxScore-minScore)
	return (1.0-t)*Vec3.create([MIN_SCORE_COLOR]) + t*Vec3.create([MAX_SCORE_COLOR])
end

local moveToNewLine = macro(function(y)
	return quote y = y - 25 end
end)

local terra screenQuad(x: double, y: double, w: double, h: double)
	gl.glBegin(gl.GL_QUADS)
		gl.glVertex2d(x, y)
		gl.glVertex2d(x+w, y)
		gl.glVertex2d(x+w, y+h)
		gl.glVertex2d(x, y+h)
	gl.glEnd()
end
local terra drawOverlay()
	-- Set up the viewing transform
	gl.glDisable(gl.GL_DEPTH_TEST)
	gl.glMatrixMode(gl.GL_PROJECTION)
	gl.glPushMatrix()
	gl.glLoadIdentity()
	var viewport : int[4]
	gl.glGetIntegerv(gl.GL_VIEWPORT, viewport)
	var vxstart = viewport[0]
	var vystart = viewport[1]
	var vwidth = viewport[2]
	var vheight = viewport[3]
	gl.gluOrtho2D(double(viewport[0]), double(viewport[2]), double(viewport[1]), double(viewport[3]))
	gl.glMatrixMode(gl.GL_MODELVIEW)
	gl.glPushMatrix()
	gl.glLoadIdentity()

	-- Prep some convenient 'local' coordinates
	var xleft = 10
	var ytop = vystart + vheight - 25

	-- Display the sample/generation index
	var str : int8[64]
	if displayMesh == &globals.matchTargetMesh then
		S.sprintf(str, "Match Target Shape")
	elseif displayMesh == &voxelMesh then
		S.sprintf(str, "Voxelization")
	elseif samples == nil then
		S.sprintf(str, "<No Active Mesh>")
	else
		S.sprintf(str, "Gen: %d/%u, Samp: %d/%u", currGenIndex+1, generations:size(), currSampleIndex+1, samples:size())
	end
	gl.glColor3f([TEXT_COLOR])
	displayString(TEXT_FONT, str, xleft, ytop)
	moveToNewLine(ytop)


	-- Display the score (logprob), if applicable
	-- Also report whether mesh self intersects
	-- Also report the size of the mesh
	if isDisplayingSample() then
		gl.glColor3f([TEXT_COLOR])
		S.sprintf(str, "Score: ")
		displayString(TEXT_FONT, str, xleft, ytop)
		var score = samples(currSampleIndex).logprob
		if samples:size() > 1 then
			var color = colorForScore(score)
			gl.glColor3dv(&(color(0)))
		end
		S.sprintf(str, "%g", score)
		displayString(TEXT_FONT, str, xleft + 65, ytop)
		moveToNewLine(ytop)
		gl.glColor3f([TEXT_COLOR])
		if checkingForSelfIntersections then
			S.sprintf(str, "Has self-intersections: %u\n", meshSelfIntersects)
		else
			S.sprintf(str, "(Not checking for self-intersections)\n")
		end
		displayString(TEXT_FONT, str, xleft, ytop)
		moveToNewLine(ytop)
		S.sprintf(str, "Num tris/verts/norms: %u/%u/%u\n",
			displayMesh:numTris(), displayMesh:numVertices(), displayMesh:numNormals())
		displayString(TEXT_FONT, str, xleft, ytop)
		moveToNewLine(ytop)
	end
	-- Report whether we're showing the avoid mesh
	if shouldDrawAvoidMesh then
		S.sprintf(str, "(Showing Avoid Mesh)\n")
		displayString(TEXT_FONT, str, xleft, ytop)
		moveToNewLine(ytop)
	end

	-- Draw a little 'navigation bar' at the bottom
	if isDisplayingSample() and samples:size() > 1 then
		gl.glPolygonMode(gl.GL_FRONT_AND_BACK, gl.GL_FILL)
		-- First, draw a bar across the screen colored by score
		var height = 20.0
		var width = vwidth / double(samples:size())
		var start = 0.0
		for i=0,samples:size() do
			var color = colorForScore(samples(i).logprob)
			gl.glColor3dv(&(color(0)))
			screenQuad(start, 0.0, width, height)
			start = start + width
		end
		-- Then, draw a notch for the MAP sample.
		gl.glColor3d(1.0, 1.0, 1.0)
		screenQuad(MAPIndex*width, 0.0, 5.0, height+5)
		-- Finally, draw a notch for where we are now.
		gl.glColor3d(0.0, 0.0, 0.0)
		screenQuad(currSampleIndex*width, 0.0, 5.0, height+5)
	end

	gl.glPopMatrix()
	gl.glMatrixMode(gl.GL_PROJECTION)
	gl.glPopMatrix()
	gl.glEnable(gl.GL_DEPTH_TEST)
end

local terra display()
	camera:setupGLPerspectiveView()
	gl.glClearColor(0.2, 0.2, 0.2, 1.0)
	gl.glClear(gl.GL_COLOR_BUFFER_BIT or gl.GL_DEPTH_BUFFER_BIT)

	if displayMesh ~= nil then
		shadingMeshDrawPass(displayMesh)
		wireframeMeshDrawPass(displayMesh)
	end
	if shouldDrawAvoidMesh then
		var meshToDraw = &globals.avoidTargetMesh
		if voxelAvoidMesh:numTris() > 0 then
			meshToDraw = &voxelAvoidMesh
		end
		shadingMeshDrawPass(meshToDraw)
		wireframeMeshDrawPass(meshToDraw)
	end
	if shouldDrawGrid then
		drawGrid()
	end
	if shouldDrawOverlay then
		drawOverlay()
	end

	gl.glutSwapBuffers()
end


local terra reshape(w: int, h: int)
	gl.glViewport(0, 0, w, h)
	camera.aspect = double(w) / h
	gl.glutPostRedisplay()
end


local terra mouse(button: int, state: int, x: int, y: int)
	if state == gl.GLUT_DOWN then
		prevbutton = button
		prevx = x
		prevy = y
		alt = (gl.glutGetModifiers() == gl.GLUT_ACTIVE_ALT)
	end
end


local terra cameraMotion(x: int, y: int)
	var dx = x - prevx
	var dy = y - prevy
	if prevbutton == gl.GLUT_LEFT_BUTTON then
		camera:orbitLeft(-dx * ORBIT_SPEED)
		camera:orbitUp(dy * ORBIT_SPEED)
	elseif prevbutton == gl.GLUT_MIDDLE_BUTTON then
		camera:dollyLeft(dx * DOLLY_SPEED)
		camera:dollyUp(dy * DOLLY_SPEED)
	elseif prevbutton == gl.GLUT_RIGHT_BUTTON then
		var val = dx
		if dy*dy > dx*dx then
			val = dy
		end
		camera:zoom(val * ZOOM_SPEED)
	end
	prevx = x
	prevy = y
	gl.glutPostRedisplay()
end


local terra sampleIndexScrub(x: int, y: int)
	if prevbutton == gl.GLUT_LEFT_BUTTON and samples ~= nil then
		var viewport : int[4]
		gl.glGetIntegerv(gl.GL_VIEWPORT, viewport)
		var w = viewport[2]
		if x < 0 then x = 0 end
		if x >= w then x = w-1 end
		var t = double(x)/w
		var i = uint(t*samples:size())
		setSampleIndex(i)
	end
end


local terra renderShadowStuff(i: int)
	escape
		if globals.config.doShadowMatch then
			emit quote
				if displayMesh ~= nil then
					[shadowmap.renderShadowMask(true)](displayMesh,i)
				end
			end
		end
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
	elseif key == char('a') then
		toggleAvoidMesh()
	elseif key == char('i') then
		displayIntersectionMesh()
	elseif key == char('s') then
		toggleCheckSelfIntersections()
	elseif key == char('m') then
		setSampleIndex(MAPIndex)
	elseif key == char('b') then
		toggleTargetBoundsVoxelization()
	elseif key == char('o') then
		toggleOverlay()
	elseif key == char('c') then
		camera:print()
	elseif key == char('h') then
		renderShadowStuff(0)
	elseif key == char('j') then
		if displayMesh ~= nil then
			displayMesh:saveOBJ("savedMesh.obj")
		end
	elseif key == char('z') then
		regenCurrMeshAtHighRes()
	elseif key == char(' ') then 
		S.printf("Starting\n")
		for i=1,10 do
			S.printf("iteration %i\n", i)
			reloadCodeAndRegen()
			renderShadowStuff(i)
		end
		S.printf("Done\n")
	end
end


local terra special(key: int, x: int, y: int)
	if key == gl.GLUT_KEY_LEFT then
		setSampleIndex(currSampleIndex - 1)
	elseif key == gl.GLUT_KEY_RIGHT then
		setSampleIndex(currSampleIndex + 1)
	elseif key == gl.GLUT_KEY_UP then
		setGenerationIndex(currGenIndex - 1, false)
	elseif key == gl.GLUT_KEY_DOWN then
		setGenerationIndex(currGenIndex + 1, false)
	end
end


local terra main()

	var argc = 0
	gl.safeGlutInit(&argc, nil)
	gl.glutInitWindowSize(INITIAL_RES, INITIAL_RES)
	gl.glutInitDisplayMode(gl.GLUT_RGB or gl.GLUT_DOUBLE or gl.GLUT_DEPTH)
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





