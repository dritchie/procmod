local S = terralib.require("qs.lib.std")
local gl = terralib.require("gl.gl")
local Vec = terralib.require("linalg.vec")
local Mat = terralib.require("linalg.mat")


-- Super simple mesh struct that can accumulate geometry and draw itself

local Mesh = S.memoize(function(real)

	assert(real == float or real == double,
		"Mesh: real must be float or double")

	local Vec3 = Vec(real, 3)
	local Mat4 = Mat(real, 4, 4)

	local glVertex = real == float and gl.glVertex3fv or gl.glVertex3dv
	local glNormal = real == float and gl.glNormal3fv or gl.glNormal3dv

	local struct Mesh(S.Object)
	{
		vertices: S.Vector(Vec3),
		normals: S.Vector(Vec3),
		indices: S.Vector(uint)
	}

	terra Mesh:draw()
		-- Just simple immediate mode drawing for now
		gl.glBegin(gl.mGL_TRIANGLES())
		for i in self.indices do
			glNormal(&(self.normals(i).entries[0]))
			glVertex(&(self.vertices(i).entries[0]))
		end
		gl.glEnd()
	end

	terra Mesh:clear()
		self.vertices:clear()
		self.normals:clear()
		self.indices:clear()
	end

	terra Mesh:append(other: &Mesh)
		var nverts = self.vertices:size()
		for ov in other.vertices do
			self.vertices:insert(ov)
		end
		for on in other.normals do
			self.normals:insert(on)
		end
		for oi in other.indices do
			self.indices:insert(oi + nverts)
		end
	end

	terra Mesh:transform(xform: &Mat4)
		for i=0,self.vertices:size() do
			self.vertices(i) = xform:transformPoint(self.vertices(i))
		end
		-- TODO: Implement 4x4 matrix inversion and use the inverse transpose
		--    for the normals (I expect to only use rotations and uniform scales
		--    for the time being, so this should be fine for now).
		for i=0,self.normals:size() do
			self.normals(i) = xform:transformVector(self.normals(i))
		end
	end

	return Mesh

end)

return Mesh



