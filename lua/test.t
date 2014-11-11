local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Shapes = terralib.require("shapes")(double)
local Mesh = terralib.require("mesh")(double)
local procmod = terralib.require("lua.procmod")
local trace = terralib.require("lua.trace")
local smc = terralib.require("lua.smc")

local spaceship = terralib.require("lua.spaceship")
local generate = terralib.require("lua.generate")


local terra box(mesh: &Mesh, cx: double, cy: double, cz: double, xlen: double, ylen: double, zlen: double)
	Shapes.addBox(mesh, Vec3.create(cx, cy, cz), xlen, ylen, zlen)
end

-- NOTE: To make some of these run, make procmod export the State type

---------------------------

local generations = global(S.Vector(S.Vector(procmod.Sample)))
LS.luainit(generations:getpointer())

while true do
	generate(generations:getpointer())
end

---------------------------

-- local terra statetest()
-- 	while true do
-- 		var initstate = [procmod.State].salloc():init()
-- 		var states = [S.Vector(procmod.State)].salloc():init()
-- 		for i=0,200 do
-- 			states:insert():copy(initstate)
-- 		end
-- 		for i=0,30 do
-- 			for j=0,200 do
-- 				var state = states:get(j)
-- 				state.addmesh:clear()
-- 				Shapes.addBox(&state.addmesh, Vec3.create(0.0), 1.0, 1.0, 1.0)
-- 				state:update()
-- 			end
-- 		end
-- 		S.printf("Done\n")
-- 	end
-- end
-- statetest()

---------------------------

-- while true do
-- 	local states = {}
-- 	for i=1,200 do
-- 		table.insert(states, procmod.State.luaalloc():luainit())
-- 	end
-- 	for i=1,30 do
-- 		for _,s in ipairs(states) do
-- 			s.addmesh:clear()
-- 			box(s.addmesh, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0)
-- 			s:update()
-- 		end
-- 	end
-- 	print("Done")
-- end

---------------------------

-- local function p() end
-- while true do
-- 	local traces = {}
-- 	local state = procmod.State.luaalloc():luainit()
-- 	for i=1,200 do
-- 		table.insert(traces, trace.FlatValueTrace.alloc():init(p, state:newcopy()))
-- 	end
-- 	for i=1,30 do
-- 		for _,t in ipairs(traces) do
-- 			t.args[1].addmesh:clear()
-- 			box(t.args[1].addmesh, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0)
-- 			t.args[1]:update()
-- 		end
-- 	end
-- 	print("Done")
-- end

---------------------------

-- local function p() end
-- local Trace = trace.FlatValueTrace
-- while true do
-- 	local particles = {}
-- 	local state = procmod.State.luaalloc():luainit()
-- 	for i=1,200 do
-- 		table.insert(particles, smc.Particle(Trace).alloc():init(p, state:newcopy()))
-- 	end
-- 	for i=1,30 do
-- 		for _,p in ipairs(particles) do
-- 			p.trace.args[1].addmesh:clear()
-- 			box(p.trace.args[1].addmesh, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0)
-- 			p.trace.args[1]:update()
-- 		end
-- 	end
-- 	print("Done")
-- end

---------------------------

-- local function p() end
-- while true do
-- 	local arg = procmod.State.luaalloc():luainit()
-- 	smc.SIR(spaceship, {arg}, 200, true, p, p, p)
-- end

---------------------------

-- local generations = global(S.Vector(S.Vector(procmod.Sample)))
-- LS.luainit(generations:getpointer())
-- while true do
-- 	generations:getpointer():clear()
-- 	local arg = procmod.State.luaalloc():luainit()
-- 	procmod.SIR(spaceship, 200, generations:getpointer(), true, true)
-- end





