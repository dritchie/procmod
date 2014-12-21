local S = terralib.require("qs.lib.std")
local Vec = terralib.require("linalg.vec")
local tmath = terralib.require("qs.lib.tmath")


----------------------------------------------------------------------------------------------


-- Link against FreeImage (throw error if we can't find it)
local FI = os.getenv("FREEIMAGE_H_PATH") and terralib.includec(os.getenv("FREEIMAGE_H_PATH")) or
		   error("Environment variable 'FREEIMAGE_H_PATH' not defined.")
if os.getenv("FREEIMAGE_LIB_PATH") then
	terralib.linklibrary(os.getenv("FREEIMAGE_LIB_PATH"))
else
	error("Environment variable 'FREEIMAGE_LIB_PATH' not defined.")
end

-- Initialize FreeImage
FI.FreeImage_Initialise(0)

-- Tear down FreeImage when it is safe to destroy this module
local struct FIMemSentinel(S.Object) {}
terra FIMemSentinel:__destruct()
	FI.FreeImage_DeInitialise()
end
local __fiMemSentinel = terralib.new(FIMemSentinel)
local ffi = require("ffi")
ffi.gc(__fiMemSentinel, FIMemSentinel.methods.__destruct)


local function makeEnum(names, startVal)
	local enum = {}
	for i,n in ipairs(names) do
		enum[n] = startVal + (i-1)
	end
	return enum
end


----------------------------------------------------------------------------------------------


-- FreeImage types
local Type = makeEnum({"UNKNOWN", "BITMAP", "UINT16", "INT16", "UINT32", "INT32", "FLOAT", "DOUBLE", "COMPLEX", "RGB16",
	"RGBA16", "RGBF", "RGBAF"}, 0)

-- FreeImage formats
local Format = makeEnum({"UNKNOWN", "BMP", "ICO", "JPEG", "JNG", "KOALA", "LBM", "MNG", "PBM", "PBMRAW",
	"PCD", "PCX", "PGM", "PGMRAW", "PNG", "PPM", "PPMRAW", "RAS", "TARGA", "TIFF", "WBMP", "PSD", "CUT", "XBM", "XPM",
	"DDS", "GIF", "HDR", "FAXG3", "SGI", "EXR", "J2K", "JP2", "PFM", "PICT", "RAW"}, -1)
Format.IFF = Format.LBM


----------------------------------------------------------------------------------------------


-- Code gen helpers
local function arrayElems(ptr, num)
	local t = {}
	for i=1,num do
		local iminus1 = i-1
		table.insert(t, `ptr[iminus1])
	end
	return t
end
local function wrap(exprs, unaryFn)
	local t = {}
	for _,e in ipairs(exprs) do table.insert(t, `[unaryFn(e)]) end
	return t
end

local function typeAndBitsPerPixel(dataType, numChannels)
	-- Bytes to bits
	local function B2b(B)
		return 8*B
	end
	assert(numChannels > 0 and numChannels <= 4)
	-- 8-bit per channel image (standard bitmaps)
	if dataType == uint8 then
		return Type.BITMAP, B2b(terralib.sizeof(uint8)*numChannels)
	-- Signed 16-bit per channel image (only supports single channel)
	elseif dataType == int16 and numChannels == 1 then
		return Type.INT16, B2b(terralib.sizeof(int16))
	-- Unsigned 16-bit per channel image
	elseif dataType == uint16 then
		local s = terralib.sizeof(uint16)
		-- Single-channel
		if numChannels == 1 then
			return Type.UINT16, B2b(s)
		-- RGB
		elseif numChannels == 3 then
			return Type.RGB16, B2b(s*3)
		-- RGBA
		elseif numChannels == 4 then
			return Type.RGBA16, B2b(s*4)
		end
	-- Signed 32-bit per channel image (only supports single channel)
	elseif dataType == int32 and numChannels == 1 then
		return Type.INT32, B2b(terralib.sizeof(int32))
	-- Unsigned 32-bit per channel image (only supports single channel)
	elseif dataType == uint32 and numChannels == 1 then
		return Type.UINT32, B2b(terralib.sizeof(uint32))
	-- Single precision floating point per chanel image
	elseif dataType == float then
		local s = terralib.sizeof(float)
		-- Single-channel
		if numChannels == 1 then
			return Type.FLOAT, B2b(s)
		-- RGB
		elseif numChannels == 3 then
			return Type.RGBF, B2b(s*3)
		-- RGBA
		elseif numChannels == 4 then
			return Type.RGBAF, B2b(s*4)
		end
	-- Double-precision floating point image (only supports single channel)
	elseif dataType == double then
		return Type.DOUBLE, B2b(terralib.sizeof(double))
	else
		error(string.format("FreeImage does not support images with %u %s's per pixel", numChannels, tostring(dataType)))
	end
end


----------------------------------------------------------------------------------------------


local Image = S.memoize(function(dataType, numChannels)

	local Color = Vec(dataType, numChannels)

	local struct ImageT(S.Object)
	{
		data: &Color,
		width: uint,
		height: uint
	}
	ImageT.Color = Color
	ImageT.metamethods.__typename = function(self)
		return string.format("Image(%s, %d)", tostring(dataType), numChannels)
	end

	terra ImageT:get(x: uint, y: uint)
		return self.data + y*self.width + x
	end
	ImageT.methods.get:setinlined(true)

	ImageT.metamethods.__apply = macro(function(self, x, y)
		return `@(self.data + y*self.width + x)
	end)

	terra ImageT:__init() : {}
		self.width = 0
		self.height = 0
		self.data = nil
	end

	terra ImageT:__init(width: uint, height: uint) : {}
		self:__init()
		self.width = width
		self.height = height
		if width*height > 0 then
			self.data = [&Color](S.malloc(width*height*sizeof(Color)))
		end
	end

	terra ImageT:__init(width: uint, height: uint, fillval: Color) : {}
		self:__init()
		self.width = width
		self.height = height
		if width*height > 0 then
			self.data = [&Color](S.malloc(width*height*sizeof(Color)))
			for y=0,self.height do
				for x=0,self.width do
					S.copy(self(x,y), fillval)
				end
			end
		end
	end

	terra ImageT:__destruct()
		S.free(self.data)
	end

	terra ImageT:resize(width: uint, height: uint)
		if self.width ~= width or self.height ~= height then
			self:destruct()
			self:init(width, height)
		end
	end

	local str = terralib.includec("string.h")
	terra ImageT:memcpy(other: &ImageT)
		self:resize(other.width, other.height)
		str.memcpy(self.data, other.data, self.width*self.height*sizeof(Color))
	end

	terra ImageT:__copy(other: &ImageT)
		self.width = other.width
		self.height = other.height
		self.data = [&Color](S.malloc(self.width*self.height*sizeof(Color)))
		for y=0,self.height do
			for x=0,self.width do
				S.copy(self(x,y), other(x,y))
			end
		end
	end

	terra ImageT:clear(color: Color)
		for y=0,self.height do
			for x=0,self.width do
				self(x, y) = color
			end
		end
	end

	-- Quantize/dequantize channel values
	local makeQuantize = S.memoize(function(srcDataType, tgtDataType)
		local function B2b(B)
			return 8*B
		end
		return function(x)
			if tgtDataType:isfloat() and srcDataType:isintegral() then
				local tsize = terralib.sizeof(srcDataType)
				local maxtval = (2 ^ B2b(tsize)) - 1
				return `[tgtDataType](x/[tgtDataType](maxtval))
			elseif tgtDataType:isintegral() and srcDataType:isfloat() then
				local tsize = terralib.sizeof(tgtDataType)
				local maxtval = (2 ^ B2b(tsize)) - 1
				return `[tgtDataType](tmath.fmin(tmath.fmax(x, 0.0), 1.0) * maxtval)
			else
				return `[tgtDataType](x)
			end
		end
	end)

	-- Helper for file load constructor
	local loadImage = S.memoize(function(fileDataType)
		local b2B = macro(function(b)
			return `b/8
		end)
		local quantize = makeQuantize(fileDataType, dataType)
		return terra(image: &ImageT, fibitmap: &FI.FIBITMAP)
			var bpp = FI.FreeImage_GetBPP(fibitmap)
			var fileNumChannels = b2B(bpp) / sizeof(fileDataType)
			-- FreeImage flips R and B for 24 and 32 bit images
			var isBGR = [fileDataType == uint8] and (fileNumChannels == 3 or fileNumChannels == 4)
			var numChannelsToCopy = fileNumChannels
			if numChannels < numChannelsToCopy then numChannelsToCopy = numChannels end
			var w = FI.FreeImage_GetWidth(fibitmap)
			var h = FI.FreeImage_GetHeight(fibitmap)
			image:init(w, h)
			for y=0,h do
				var scanline = [&fileDataType](FI.FreeImage_GetScanLine(fibitmap, y))
				for x=0,w do
					var fibitmapPixelPtr = scanline + x*fileNumChannels
					var imagePixelPtr = image:get(x, y)
					for c=0,numChannelsToCopy do
						imagePixelPtr(c) = [quantize(`fibitmapPixelPtr[c])]
					end
					-- If we have a 3 or 4 element uint8 image (read:
					--    a 24 or 32 bit image), then FreeImage flips R and B
					--    for little endian machines (all x86 machines)
					-- We need to flip it back
					if isBGR then
						var tmp = imagePixelPtr(0)
						imagePixelPtr(0) = imagePixelPtr(2)
						imagePixelPtr(2) = tmp
					end
				end
			end
			return image
		end
	end)
	-- File load constructor
	terra ImageT:__init(format: int, filename: rawstring) : {}
		var fibitmap = FI.FreeImage_Load(format, filename, 0)
		if fibitmap == nil then
			S.printf("Could not load image file '%s'\n", filename)
			S.assert(false)
		end
		var fit = FI.FreeImage_GetImageType(fibitmap)
		var bpp = FI.FreeImage_GetBPP(fibitmap)

		if fit == Type.BITMAP then 
			[loadImage(uint8)](self, fibitmap)
		elseif fit == Type.INT16 then
			[loadImage(int16)](self, fibitmap)
		elseif fit == Type.UINT16 or fit == Type.RGB16 or fit == Type.RGBA16 then
			[loadImage(uint16)](self, fibitmap)
		elseif fit == Type.INT32 then
			[loadImage(int32)](self, fibitmap)
		elseif fit == Type.UINT32 then
			[loadImage(uint32)](self, fibitmap)
		elseif fit == Type.FLOAT or fit == Type.RGBF or fit == Type.RGBAF then
			[loadImage(float)](self, fibitmap)
		elseif fit == Type.DOUBLE then
			[loadImage(double)](self, fibitmap)
		else
			S.printf("Attempt to load unsupported image type.\n")
			S.assert(false)
		end

		FI.FreeImage_Unload(fibitmap)
	end

	-- Save an existing image
	ImageT.save = S.memoize(function(fileDataType)
		-- Default to internal dataType
		fileDataType = fileDataType or dataType
		local quantize = makeQuantize(dataType, fileDataType)
		local fit, bpp = typeAndBitsPerPixel(fileDataType, numChannels)
		-- FreeImage flips R and B for 24 and 32 bit images
		local isBGR = fileDataType == uint8 and (numChannels == 3 or numChannels == 4)
		return terra(image: &ImageT, format: int, filename: rawstring)
			var fibitmap = FI.FreeImage_AllocateT(fit, image.width, image.height, bpp, 0, 0, 0)
			if fibitmap == nil then
				S.printf("Unable to allocate FreeImage bitmap to save image.\n")
				S.assert(false)
			end
			for y=0,image.height do
				var scanline = [&fileDataType](FI.FreeImage_GetScanLine(fibitmap, y))
				for x=0,image.width do
					var fibitmapPixelPtr = scanline + x*numChannels
					var imagePixelPtr = image:get(x, y)
					for c=0,numChannels do
						fibitmapPixelPtr[c] = [quantize(`imagePixelPtr(c))]
					end
					-- If we have a 3 or 4 element uint8 image (read:
					--    a 24 or 32 bit image), then FreeImage flips R and B
					--    for little endian machines (all x86 machines)
					-- We need to flip it back
					escape
						if isBGR then emit quote
							var tmp = fibitmapPixelPtr[0]
							fibitmapPixelPtr[0] = fibitmapPixelPtr[2]
							fibitmapPixelPtr[2] = tmp
						end end
					end
				end
			end
			if FI.FreeImage_Save(format, fibitmap, filename, 0) == 0 then
				S.printf("Failed to save image named '%s'\n", filename)
				S.assert(false)
			end
			FI.FreeImage_Unload(fibitmap)
		end
	end)

	-- Convenience method for most common save case
	terra ImageT:save(format: int, filename: rawstring)
		[ImageT.save()](self, format, filename)
	end

	return ImageT
end)


----------------------------------------------------------------------------------------------


-- -- TEST
-- local terra test()
-- 	var flowersInt = [Image(uint8, 3)].salloc():init(Format.JPEG, "flowers.jpeg")
-- 	flowersInt:save(Format.PNG, "flowersInt.png")
-- 	var flowersFloat = [Image(float, 3)].salloc():init(Format.JPEG, "flowers.jpeg")
-- 	[Image(float, 3).save(uint8)](flowersFloat, Format.PNG, "flowersFloat.png")
-- end
-- test()


----------------------------------------------------------------------------------------------


return
{
	-- Type = Type,
	Format = Format,
	Image = Image,
	__fiMemSentinel = __fiMemSentinel
}











