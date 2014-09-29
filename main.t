local S = terralib.require("qs.lib.std")
local gl = terralib.require("gl.gl")
local glutils = terralib.require("gl.glutils")

gl.exposeConstants({
	"GLUT_LEFT_BUTTON",
	"GLUT_MIDDLE_BUTTON",
	"GLUT_RIGHT_BUTTON",
	"GLUT_UP",
	"GLUT_DOWN"
})


-- Constants
local INITIAL_RES = 800
local ORBIT_SPEED = 0.01
local DOLLY_SPEED = 0.01
local ZOOM_SPEED = 0.02


-- Globals
local camera = global(glutils.Camera(double))
local prevx = global(int)
local prevy = global(int)
local prevbutton = global(int)


local terra init()
	camera:init()
	gl.glClearColor(0.2, 0.2, 0.2, 1.0)
end


local terra display()
	gl.glClear(gl.mGL_COLOR_BUFFER_BIT() or gl.mGL_DEPTH_BUFFER_BIT())
	gl.glMatrixMode(gl.mGL_MODELVIEW())

	-- TEST drawing
	gl.glColor3f(0.8, 0.8, 0.8)
	gl.glBegin(gl.mGL_QUADS())
		gl.glVertex3f(-1.0, -1.0, -3.0)
		gl.glVertex3f(1.0, -1.0, -3.0)
		gl.glVertex3f(1.0, 1.0, -3.0)
		gl.glVertex3f(-1.0, 1.0, -3.0)
	gl.glEnd()

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

	init()
	gl.glutMainLoop()

end

main()





