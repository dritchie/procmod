local gl = terralib.require("gl.gl")
local Vec = terralib.require("linalg.vec")

-- Do all sorts of crazy model generation/drawing here
local terra draw()

	-- TEST drawing
	gl.glBegin(gl.mGL_QUADS())
		gl.glVertex3f(-1.0, -1.0, -3.0)
		gl.glVertex3f(1.0, -1.0, -3.0)
		gl.glVertex3f(1.0, 1.0, -3.0)
		gl.glVertex3f(-1.0, 1.0, -3.0)
	gl.glEnd()
	
end

return draw



