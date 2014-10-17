local Mesh = terralib.require("mesh")
local Vec = terralib.require("linalg.vec")
local Shapes = terralib.require("shapes")
local qs = terralib.require("qs")
local globals = terralib.require("globals")
local BinaryGrid = terralib.require("binaryGrid3d")
local BBox = terralib.require("bbox")


-- Main will call the function returned by this module


local p = qs.program(function()
	local Vec3 = Vec(qs.real, 3)
	local Shape = Shapes(qs.real)
	local MeshT = Mesh(qs.real)
	local BBox3 = BBox(Vec3)

	local lerp = macro(function(lo, hi, t)
		return `(1.0-t)*lo + t*hi
	end)
	-- So ranges stay synced during MH proposals.
	local uniform = macro(function(lo, hi)
		return quote
			var u = qs.uniform(0.0, 1.0, {struc=false})
		in
			lerp(lo, hi, u)
		end
	end)
	local min = macro(function(a, b)
		return quote
			var x = a
			if b < a then x = b end
		in
			x
		end
	end)
	local max = macro(function(a, b)
		return quote
			var x = a
			if b > a then x = b end
		in
			x
		end
	end)

	-- Wings are just a horizontally-symmetric stack of boxes
	local genWing = qs.func(terra(mesh: &MeshT, xbase: qs.real, zlo: qs.real, zhi: qs.real)
		var nboxes = qs.poisson(5) + 1
		for i in qs.range(0,nboxes) do
			var zbase = uniform(zlo, zhi)
			var xlen = uniform(0.25, 2.0)
			var ylen = uniform(0.25, 1.25)
			var zlen = uniform(0.5, 4.0)
			-- Clip zlen to [zlo, zhi] for the first iteration, which is what attaches to the ship body.
			if i == 0 then
				-- Constraints: zbase + 0.5*zlen < zhi 
				--              zbase - 0.5*zlen > zlo
				zlen = min(zlen, 2.0*(zhi - zbase))
				zlen = min(zlen, -2.0*(zlo - zbase))
			end
			Shape.addBox(mesh, Vec3.create(xbase + 0.5*xlen, 0.0, zbase), xlen, ylen, zlen)
			Shape.addBox(mesh, Vec3.create(-(xbase + 0.5*xlen), 0.0, zbase), xlen, ylen, zlen)
			xbase = xbase + xlen
			zlo = zbase - 0.5*zlen
			zhi = zbase + 0.5*zlen
		end
	end)

	-- Fins protrude up from ship body segments
	local genFin = qs.func(terra(mesh: &MeshT, ybase: qs.real, zlo: qs.real, zhi: qs.real, xmax: qs.real)
		var nboxes = qs.poisson(2) + 1
		for i in qs.range(0,nboxes) do
			var xlen = uniform(0.5, 1.0) * xmax
			xmax = xlen
			var ylen = uniform(0.1, 0.5)
			var zlen = uniform(0.5, 1.0) * (zhi - zlo)
			var zbase = 0.5*(zlo+zhi)
			Shape.addBox(mesh, Vec3.create(0.0, ybase + 0.5*ylen, zbase), xlen, ylen, zlen)
			ybase = ybase + ylen
			zlo = zbase - 0.5*zlen
			zhi = zbase + 0.5*zlen
		end
	end)

	-- The ship body is a forward-protruding stack of boxes
	-- Wings and fins are randomly attached to different body segments
	local genShip = qs.func(terra(mesh: &MeshT, rearz: qs.real)
		var nboxes = qs.poisson(4) + 1
		for i in qs.range(0,nboxes) do
			var xlen = uniform(1.0, 3.0)
			var ylen = uniform(0.5, 1.0) * xlen
			var zlen = uniform(2.0, 5.0)
			Shape.addBox(mesh, Vec3.create(0.0, 0.0, rearz + 0.5*zlen), xlen, ylen, zlen)
			rearz = rearz + zlen
			-- Gen wing?
			var wingprob = lerp(0.4, 0.0, i/qs.real(nboxes)) -- var wingprob = 0.25
			if qs.flip(wingprob) then
				var xbase = 0.5*xlen
				var zlo = rearz - zlen
				var zhi = rearz
				genWing(mesh, xbase, zlo, zhi)
			end
			-- Gen fin?
			var finprob = 0.7
			if qs.flip(finprob) then
				var ybase = 0.5*ylen
				var zlo = rearz - zlen
				var zhi = rearz
				var xmax = 0.6*xlen
				genFin(mesh, ybase, zlo, zhi, xmax)
			end
		end
	end)

	-- Factor that enforces a desired aspect ratio
	local terra aspectFactor(mesh: &MeshT, targetWidth: qs.real, targetLength: qs.real)
		-- Compute bounding box, enforce desired dimensions
		var bbox = mesh:bbox()
		var dims = bbox:extents()
		qs.factor(qs.softeq(dims(0), targetWidth, 0.25))
		qs.factor(qs.softeq(dims(2), targetLength, 0.25))
	end

	-- Factor that compares voxelization of generated mesh against a target voxelization
	local targetGrid = global(BinaryGrid)
	local targetBounds = global(BBox3)
	local terra inittarget()
		targetGrid:init()
		targetBounds = globals.targetMesh:bbox()
		targetBounds:expand(globals.BOUNDS_EXPAND)
		globals.targetMesh:voxelize(&targetGrid, &targetBounds, globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
	end
	inittarget()
	local terra voxelFactor(mesh: &MeshT)
		var grid = BinaryGrid.salloc():init(targetGrid.rows, targetGrid.cols, targetGrid.slices)
		mesh:voxelize(grid, &targetBounds, globals.VOXEL_SIZE, globals.SOLID_VOXELIZE)
		var numsame = 0
		for k=0,grid.slices do
			for i=0,grid.rows do
				for j=0,grid.cols do
					numsame = numsame + int(grid:isVoxelSet(i,j,k) == targetGrid:isVoxelSet(i,j,k))
				end
			end
		end
		var percentsame = qs.real(numsame)/(grid.rows*grid.cols*grid.slices)
		qs.factor(qs.softeq(percentsame, 1.0, 0.05))
	end

	return terra()
		var mesh : MeshT
		mesh:init()

		-- Generate ship mesh
		genShip(&mesh, -5.0)

		-- Enforce some constraint
		voxelFactor(&mesh)
		-- aspectFactor(&mesh, 10.0, 10.0)
		-- aspectFactor(&mesh, 4.0, 25.0)

		return mesh
	end
end)

-- -- Forward sampling
-- local gen = p:compile()
-- return terra(mesh: &Mesh(double))
-- 	mesh:destruct()
-- 	@mesh = gen()
-- end

-- Constrained sampling with MCMC
local query = qs.infer(p, qs.MAP, qs.MCMC(qs.TraceMHKernel(), {numsamps=2000, verbose=true}))
return terra(mesh: &Mesh(double))
	mesh:destruct()
	@mesh = query()
end




