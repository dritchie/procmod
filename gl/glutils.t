local S = require("qs.lib.std")
local Vec = require("linalg.vec")
local Mat = require("linalg.mat")
local gl = require("gl.gl")



local elems = macro(function(vec)
	local T = vec:gettype()
	local N = T.Dimension
	local exps = terralib.newlist()
	for i=1,N do
		exps:insert(`vec([i-1]))
	end
	return exps
end)



-- Simple camera class that packages up data needed to establish 3D
--    viewing / projection transforms
-- Also provides some camera manipulation primitives
local Camera = S.memoize(function(real)

	local Vec3 = Vec(real, 3)
	local Mat4 = Mat(real, 4, 4)

	local struct Camera(S.Object)
	{
		eye: Vec3,
		target: Vec3,
		forward: Vec3,
		up: Vec3,
		absUp: Vec3,
		left: Vec3,
		fovy: real,	-- in degrees
		aspect: real,
		znear: real,
		zfar: real
	}

	terra Camera:__init(eye: Vec3, target: Vec3, up: Vec3, worldUp: Vec3, fovy: real, aspect: real, znear: real, zfar: real) : {}
		self.eye = eye
		self.target = target
		self.up = up
		self.absUp = worldUp
		self.fovy = fovy
		self.aspect = aspect
		self.znear = znear
		self.zfar = zfar

		self.up:normalize()
		self.forward = (self.target - self.eye); self.forward:normalize()
		self.left = self.up:cross(self.forward)
		self.up = self.forward:cross(self.left)
	end

	terra Camera:__init(eye_x: real, eye_y: real, eye_z: real, target_x: real, target_y: real, target_z: real, up_x: real, up_y: real, up_z: real,
						wup_x: real, wup_y: real, wup_z: real, fovy: real, aspect: real, znear: real, zfar: real) : {}
		self:__init(Vec3.create(eye_x, eye_y, eye_z),			-- eye
					Vec3.create(target_x, target_y, target_z),	-- target
					Vec3.create(up_x, up_y, up_z),				-- up
					Vec3.create(wup_x, wup_y, wup_z),			-- world up
					fovy,										-- fov y
					aspect,										-- aspect
					znear,										-- znear,
					zfar										-- zfar
		)
	end

	-- Default camera is looking down -z
	terra Camera:__init() : {}
		self:__init(Vec3.create(0.0, 0.0, 0.0),    -- eye
				   	Vec3.create(0.0, 0.0, -1.0),   -- target
				   	Vec3.create(0.0, 1.0, 0.0),    -- up
				   	Vec3.create(0.0, 1.0, 0.0),    -- world up
				   	45.0,						   -- fov y
				   	1.0,						   -- aspect
				   	0.1,						   -- z near
				   	100.0						   -- z far
		)
	end

	terra Camera:print()
		S.printf("%g %g %g   %g %g %g   %g %g %g   %g %g %g   %g   %g   %g   %g\n",
			self.eye(0), self.eye(1), self.eye(2),
			self.target(0), self.target(1), self.target(2),
			self.up(0), self.up(1), self.up(2),
			self.absUp(0), self.absUp(1), self.absUp(2),
			self.fovy, self.aspect, self.znear, self.zfar)
	end

	-- OpenGL 1.1 style
	terra Camera:setupGLPerspectiveView()
		gl.glMatrixMode(gl.GL_MODELVIEW)
		gl.glLoadIdentity()
		gl.gluLookAt(self.eye(0), self.eye(1), self.eye(2),
					 self.target(0), self.target(1), self.target(2),
					 self.up(0), self.up(1), self.up(2))
		gl.glMatrixMode(gl.GL_PROJECTION)
		gl.glLoadIdentity()
		gl.gluPerspective(self.fovy, self.aspect, self.znear, self.zfar)
	end

	terra Camera:viewMatrix()
		return Mat4.lookAt(self.eye, self.target, self.up)
	end

	terra Camera:dollyLeft(dist: real)
		var offset = dist*self.left
		self.eye = self.eye + offset
		self.target = self.target + offset
	end

	terra Camera:dollyForward(dist: real)
		var offset = dist*self.forward
		self.eye = self.eye + offset
		self.target = self.target + offset
	end

	terra Camera:dollyUp(dist: real)
		var offset = dist*self.up
		self.eye = self.eye + offset
		self.target = self.target + offset
	end

	terra Camera:zoom(dist: real)
		var offset = dist*self.forward
		self.eye = self.eye + offset
	end

	terra Camera:panLeft(theta: real)
		var t = Mat4.rotate(self.absUp, theta, self.eye)
		var fwd = t:transformVector(self.target - self.eye)
		self.forward = fwd; self.forward:normalize()
		self.up = t:transformVector(self.up)
		self.left = t:transformVector(self.left)
		self.target = self.eye + fwd
	end

	terra Camera:panUp(theta: real)
		var t = Mat4.rotate(self.left, theta, self.eye)
		var fwd = t:transformVector(self.target - self.eye)
		self.forward = fwd; self.forward:normalize()
		self.up = t:transformVector(self.up)
		self.target = self.eye + fwd
	end

	terra Camera:orbitLeft(theta: real)
		var t = Mat4.rotate(self.absUp, theta, self.target)
		var backward = t:transformVector(self.eye - self.target)
		self.forward = -backward; self.forward:normalize()
		self.up = t:transformVector(self.up)
		self.left = t:transformVector(self.left)
		self.eye = self.target + backward
	end

	terra Camera:orbitUp(theta: real)
		var t = Mat4.rotate(self.left, theta, self.target)
		var backward = t:transformVector(self.eye - self.target)
		self.forward = -backward; self.forward:normalize()
		self.up = t:transformVector(self.up)
		self.eye = self.target + backward
	end

	return Camera

end)



-- Simple light class that packages up parameters about lights
local Light = S.memoize(function(real)

	local Vec3 = Vec(real, 3)
	local Color4 = Vec(real, 4)

	local LightType = uint
	local Directional = 0
	local Point = 1

	local struct Light(S.Object)
	{
		type: LightType,
		union
		{
			pos: Vec3,
			dir: Vec3
		},
		ambient: Color4,
		diffuse: Color4,
		specular: Color4
	}
	Light.LightType = LightType
	Light.Point = Point
	Light.Directional = Directional

	terra Light:__init()
		self.type = Directional
		self.dir:init(-1.0, 1.0, 1.0)
		self.ambient:init(0.3, 0.3, 0.3, 1.0)
		self.diffuse:init(1.0, 1.0, 1.0, 1.0)
		self.specular:init(1.0, 1.0, 1.0, 1.0)
	end

	terra Light:__init(type: LightType, posOrDir: Vec3, ambient: Color4, diffuse: Color4, specular: Color4) : {}
		self.type = type
		self.pos = posOrDir
		self.ambient = ambient
		self.diffuse = diffuse
		self.specular = specular
	end

	terra Light:__init(type: LightType, posOrDir: Vec3, diffuse: Color4, ambAmount: real, specular: Color4) : {}
		self.type = type
		self.pos = posOrDir
		self.ambient = ambAmount * diffuse; self.ambient(3) = self.diffuse(3)
		self.diffuse = diffuse
		self.specular = specular
	end

	-- OpenGL 1.1 style
	terra Light:setupGLLight(lightID: int)
		if lightID < 0 or lightID >= gl.GL_MAX_LIGHTS then
			S.printf("lightID must be in the range [0,%d); got %d instead\n", 0, gl.GL_MAX_LIGHTS, lightID)
			S.assert(false)
		end
		var lightNumFlag = gl.GL_LIGHT0 + lightID
		gl.glEnable(lightNumFlag)
		var floatArr = arrayof(float, elems(self.ambient))
		gl.glLightfv(lightNumFlag, gl.GL_AMBIENT, floatArr)
		floatArr = arrayof(float, elems(self.diffuse))
		gl.glLightfv(lightNumFlag, gl.GL_DIFFUSE, floatArr)
		floatArr = arrayof(float, elems(self.specular))
		gl.glLightfv(lightNumFlag, gl.GL_SPECULAR, floatArr)
		-- Leverage the fact that the light type flags correspond to the value of the w coordinate
		floatArr = arrayof(float, elems(self.pos), self.type)
		gl.glLightfv(lightNumFlag, gl.GL_POSITION, floatArr)
	end

	return Light

end)




-- Simple material class to package up material params
local Material = S.memoize(function(real)

	local Color4 = Vec(real, 4)

	local struct Material(S.Object)
	{
		ambient: Color4,
		diffuse: Color4,
		specular: Color4,
		shininess: real
	}

	terra Material:__init()
		self.ambient:init(0.8, 0.8, 0.8, 1.0)
		self.diffuse:init(0.8, 0.8, 0.8, 1.0)
		self.specular:init(0.0, 0.0, 0.0, 1.0)
		self.shininess = 0.0
	end

	terra Material:__init(ambient: Color4, diffuse: Color4, specular: Color4, shininess: real)
		self.ambient = ambient
		self.diffuse = diffuse
		self.specular = specular
		self.shininess = shininess
	end

	terra Material:__init(diffuse: Color4, specular: Color4, shininess: real)
		self.ambient = diffuse
		self.diffuse = diffuse
		self.specular = specular
		self.shininess = shininess
	end

	-- OpenGL 1.1 style
	terra Material:setupGLMaterial()
		-- Just default everything to only affecting the front faces
		var flag = gl.GL_FRONT
		var floatArr = arrayof(float, elems(self.ambient))
		gl.glMaterialfv(flag, gl.GL_AMBIENT, floatArr)
		floatArr = arrayof(float, elems(self.diffuse))
		gl.glMaterialfv(flag, gl.GL_DIFFUSE, floatArr)
		floatArr = arrayof(float, elems(self.specular))
		gl.glMaterialfv(flag, gl.GL_SPECULAR, floatArr)
		gl.glMaterialf(flag, gl.GL_SHININESS, self.shininess)
	end

	return Material

end)



return
{
	Camera = Camera,
	Light = Light,
	Material = Material
}





