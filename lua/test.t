local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local Vec3 = terralib.require("linalg.vec")(double, 3)
local Shapes = terralib.require("shapes")(double)
local procmod = terralib.require("lua.procmod")
local generate = terralib.require("lua.generate")


---------------------------

local generations = global(S.Vector(S.Vector(procmod.Sample)))
LS.luainit(generations:getpointer())

while true do
	generate(generations:getpointer())
end

---------------------------

-- To make this run, make procmod export the State type

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