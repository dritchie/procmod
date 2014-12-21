local util = terralib.require("util")

-- Mac OSX only, for now
local osname = util.osName()
if not (osname == "Darwin\n") then
	error(string.format("GLUT/OpenGL module currently only supported on OSX; osName is %s",
		osname))
end

-- Automatically generate functions that return commonly-used macro constants
--    that are otherwise not accessible from Terra.
local function genConstantAccessorDef(constantName, constantType)
	return string.format("inline %s m%s() { return %s; }\n", constantType, constantName, constantName)
end
local function genAllConstantAccessorDefs(constants)
	local code = ""
	for name,typ in pairs(constants) do
		code = code .. genConstantAccessorDef(name, typ)
	end
	return code
end

-- Constants to be exposed
local constTable = {}
local function addConstants(constants)
	for _,c in ipairs(constants) do
		-- default type of a constant is int
		if type(c) == "string" then
			constTable[c] = "int"
		elseif type(c) == "table" then
			constTable[c[1]] = c[2]
		else
			error("gl.addConstants: entries must be either names or {name, type} tables")
		end
	end
end

local function loadHeaders()
	-- Get GLUT header, adding functions for constants
	return util.includecstring_path(string.format([[
	#include <GLUT/glut.h>
	%s
	]], genAllConstantAccessorDefs(constTable)))
end

-- Initialize the module with the default set of constants exposed
local gl = loadHeaders()

-- Link dynamic libraries
terralib.linklibrary("/System/Library/Frameworks/OpenGL.framework/Libraries/libGL.dylib")
terralib.linklibrary("/System/Library/Frameworks/OpenGL.framework/Libraries/libGLU.dylib")
terralib.linklibrary("/System/Library/Frameworks/GLUT.framework/GLUT")

-- Add a method for initializing GLUT that can be safely called multiple times
local glutIsInitialized = global(bool, 0)
gl.safeGlutInit = macro(function(argc, argv)
	return quote
		if not glutIsInitialized then
			gl.glutInit(argc, argv)
			glutIsInitialized = true
		end
	end
end)

-- If you need access to additional macro constants, use this function.
-- It will reload the GLUT/OpenGL headers and add accessor functions for
--    the requested constants.
-- This is cumulative; it will provide access to all constants requested
--    up to this call as well.
function gl.exposeConstants(constants)
	addConstants(constants)
	local h = loadHeaders()
	for k,v in pairs(h) do gl[k] = v end
end

return gl





