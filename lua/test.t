local S = terralib.require("qs.lib.std")
local LS = terralib.require("lua.std")
local procmod = terralib.require("lua.procmod")
local generate = terralib.require("lua.generate")


local generations = global(S.Vector(S.Vector(procmod.Sample)))
LS.luainit(generations:getpointer())


while true do
	generate(generations:getpointer())
end