local S = terralib.require("qs.lib.std")
local globals = terralib.require("globals")
local gl = terralib.require("gl.gl")
local Vec = terralib.require("linalg.vec")
local Vec3 = Vec(double, 3)
local Mat4 = terralib.require("linalg.mat")(double, 4, 4)
local Mesh = terralib.require("geometry.mesh")(double)
local BinaryGrid2D = terralib.require("geometry.binaryGrid2d")

local renderShadowMask = S.memoize(function(saveImages)

	local image = nil
	if saveImages then image = terralib.require("image") end

	local terra render(mesh: &Mesh, shadowMatchImage: &BinaryGrid2D,
				 	   shadowMatchImagePixelData: &S.Vector(Vec(uint8, 4))) : {}
		var viewport : int[4]
		gl.glGetIntegerv(gl.GL_VIEWPORT, viewport)

		-----------------
		-- SHADOW PASS --
		-----------------
		gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, globals.getShadowMapFBO())
		var w = globals.config.shadowMapRes
		var h = globals.config.shadowMapRes
		gl.glViewport(0, 0, w, h)
		gl.glClearColor(0.0, 0.0, 0.0, 1.0)
		gl.glClear(gl.GL_COLOR_BUFFER_BIT or gl.GL_DEPTH_BUFFER_BIT)
		gl.glColor4f(1.0, 1.0, 1.0, 1.0)
		-- Viewing transform
		gl.glMatrixMode(gl.GL_MODELVIEW)
		gl.glLoadIdentity()
		var bounds = mesh:bbox()
		var receiverBounds = globals.shadowReceiverGeo:bbox()
		bounds:unionWith(&receiverBounds)
		var center = bounds:center()
		if globals.config.orthoShadow then 
			center = receiverBounds:center() 
		end
		var eye = center - @globals.config.shadowLightDir
		var shadowview = Mat4.lookAt(eye, center, Vec3.create(0.0, 1.0, 0.0))
		if globals.config.orthoShadow then 
			shadowview = Mat4.lookAt(eye, center, Vec3.create(0.0, 0.0, -1.0))
		end
		var gl_matrix : double[16]
		shadowview:toColumnMajor(gl_matrix)
		gl.glLoadMatrixd(gl_matrix)
		gl.glMatrixMode(gl.GL_PROJECTION)
		gl.glLoadIdentity()
		var sidelen = bounds:extents():norm()*0.5
		var shadowproj = Mat4.ortho(-sidelen, sidelen, -sidelen, sidelen, -sidelen, sidelen)
		if globals.config.orthoShadow then
			sidelen = receiverBounds:extents()(0)*0.5
			shadowproj = Mat4.ortho(-sidelen, sidelen, -sidelen, sidelen, -100, 100)
		end
		shadowproj:toColumnMajor(gl_matrix)
		gl.glLoadMatrixd(gl_matrix)
		-- Render
		globals.shadowReceiverGeo:draw()
		mesh:draw()
		gl.glFlush()
		var depthTex : int
		gl.glGetFramebufferAttachmentParameteriv(
			gl.GL_FRAMEBUFFER,
			gl.GL_DEPTH_ATTACHMENT,
			gl.GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME,
			&depthTex
		)
		-- Save shadow map image, if requested
		escape
			if saveImages then
				emit quote
					var depthdata = [&float](S.malloc(w*h*sizeof(float)))
					gl.glBindTexture(gl.GL_TEXTURE_2D, depthTex)
					gl.glGetTexImage(gl.GL_TEXTURE_2D, 0, gl.GL_DEPTH_COMPONENT, gl.GL_FLOAT, depthdata)
					var mindepth = [math.huge]
					var maxdepth = [-math.huge]
					for y=0,h do
						for x=0,w do
							var d = depthdata[y*w + x]
							if d < mindepth then mindepth = d end
							if d > maxdepth then maxdepth = d end
						end
					end
					gl.glBindTexture(gl.GL_TEXTURE_2D, 0)
					var dimg = [image.Image(float, 1)].salloc():init(w, h)
					for y=0,h do
						for x=0,w do
							var d = depthdata[y*w + x]
							d = (d - mindepth) / (maxdepth - mindepth)
							dimg(x,y)(0) = d
						end
					end
					S.free(depthdata)
					dimg:save(image.Format.TIFF, "shadowMap.tiff")
				end
			end
		end

		-----------------
		-- RENDER PASS --
		-----------------
		-- Switch to special shadow rendering program
		var prog = globals.getShadowRenderProgram()
		gl.glUseProgram(prog)
		-- Bind the shadow model/view/projection matrix uniform
		var shadowMVP = shadowproj * shadowview
		shadowMVP:toColumnMajor(gl_matrix)
		var gl_float_matrix : float[16]
		for i=0,16 do gl_float_matrix[i] = float(gl_matrix[i]) end
		var shadowmvploc = gl.glGetUniformLocation(prog, "shadowMVP")
		gl.glUniformMatrix4fv(shadowmvploc, 1, gl.GL_FALSE, gl_float_matrix)
		-- Bind the light direction uniform
		var lightdirloc = gl.glGetUniformLocation(prog, "lightDir")
		var ldir : float[3]
		for i=0,3 do ldir[i] = float(globals.config.shadowLightDir(i)) end
		gl.glUniform3fv(lightdirloc, 3, ldir)
		-- Bind the shadow map sampler uniform
		var shadowmaploc = gl.glGetUniformLocation(prog, "shadowMap")
		gl.glUniform1i(shadowmaploc, 0)
		gl.glActiveTexture(gl.GL_TEXTURE0)
		gl.glBindTexture(gl.GL_TEXTURE_2D, depthTex)
		-- Render
		gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, globals.getShadowMatchFBO())
		w = globals.shadowTargetImage.cols
		h = globals.shadowTargetImage.rows
		gl.glViewport(0, 0, w, h)
		gl.glClear(gl.GL_COLOR_BUFFER_BIT or gl.GL_DEPTH_BUFFER_BIT)
		globals.config.shadowMatchCamera.aspect = float(w)/h
		globals.config.shadowMatchCamera:setupGLPerspectiveView()


		if globals.config.orthoShadow then
			gl.glMatrixMode(gl.GL_MODELVIEW)
			gl.glLoadIdentity()
			shadowview:toColumnMajor(gl_matrix)
			gl.glLoadMatrixd(gl_matrix)
			gl.glMatrixMode(gl.GL_PROJECTION)
			gl.glLoadIdentity()
			shadowproj:toColumnMajor(gl_matrix)
			gl.glLoadMatrixd(gl_matrix)
		end


		globals.shadowReceiverGeo:draw()
		if not globals.config.orthoShadow then 
			mesh:draw() 
		end
		gl.glFlush()
		-- Read out into binary grid
		shadowMatchImagePixelData:resize(w*h)
		gl.glReadPixels(0, 0, w, h, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &(shadowMatchImagePixelData(0)))
		shadowMatchImage:clear()
		shadowMatchImage:resize(h, w)
		for y=0,h do
			for x=0,w do
				var c = shadowMatchImagePixelData(y*w + x)
				if c(0) > 0 then
					shadowMatchImage:setPixel(y, x)
				end
			end
		end
		-- Save mask image, if requested
		escape
			if saveImages then
				emit quote
					var img = [image.Image(uint8, 4)].salloc():init(w, h)
					for y=0,h do
						for x=0,w do
							var c = shadowMatchImagePixelData(y*w + x)
							img(x,y) = c
							if globals.config.orthoShadow and ((c.entries[0] == 0) and globals.shadowTargetImage:isPixelSet(y,x)) then
								img(x,y).entries[1] = 255
							end
						end
					end
					img:save(image.Format.PNG, "shadowMask.png")
				end
			end
		end

		-- Clean up
		gl.glUseProgram(0)
		gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0)
		gl.glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
	end

	render:adddefinition((terra(mesh: &Mesh) : {}
		var shadowMatchImage = BinaryGrid2D.salloc():init()
		var shadowMatchImagePixelData = [S.Vector(Vec(uint8, 4))].salloc():init()
		render(mesh, shadowMatchImage, shadowMatchImagePixelData)
	end):getdefinitions()[1])

	return render

end)

return
{
	renderShadowMask = renderShadowMask
}



