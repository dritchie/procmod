local prob = terralib.require("prob.prob")
local S = terralib.require("qs.lib.std")
local LVec3 = terralib.require("linalg.luavec")(3)
local treelib = terralib.require("models.treelib")

local flip = prob.flip
local uniform = prob.uniform
local gaussian = prob.gaussian

---------------------------------------------------------------

return S.memoize(function(makeGeoPrim, geoRes)

	local T = treelib(makeGeoPrim, geoRes)

	local origradius
	local function branch(frame, prev, depth)
		-- if depth > 2 then return end
		local finished = false
		local i = 0
		repeat
			-- Kill things that get too small to matter
			if frame.radius/origradius < 0.1 then break end

			prob.setAddressLoopIndex(i)
			local uprot = gaussian(0, math.pi/12, "uprot")
			local leftrot = gaussian(0, math.pi/12, "leftroy")
			local len = uniform(3, 5, "len") * frame.radius
			local endradius = uniform(0.7, 0.9, "endradius") * frame.radius

			-- Figure out where we need to split the segment
			-- (This is so the part that we branch from is a pure conic section)
			local nextframe = T.advanceFrame(frame, uprot, leftrot, len, endradius)
			local splitFrame = T.findSplitFrame(frame, nextframe)

			-- Place geometry
			T.treeSegment(T.N_SEGS, prev, frame, splitFrame, nextframe)


			if flip(T.branchProb(depth, i), "branchgen") then
				-- Theta mean/variance based on avg weighted by 'up-facing-ness'
				local theta_mu, theta_sigma = T.estimateThetaDistrib(splitFrame, nextframe)
				local theta = gaussian(theta_mu, theta_sigma, "theta")
				local maxbranchradius = 0.5*(nextframe.center - splitFrame.center):norm()
				local branchradius = math.min(uniform(0.8, 0.95, "branchradius") * nextframe.radius, maxbranchradius)
				local bframe, prev = T.branchFrame(splitFrame, nextframe, 0.5, theta, branchradius, T.N_SEGS)
				prob.pushAddress("branch")
				branch(bframe, prev, depth+1)
				prob.popAddress()
			end
			-- local finished = true
			local finished = flip(1-T.continueProb(i), "continue")
			-- local finished = endradius < 0.2
			i = i + 1
			frame = nextframe
			-- 'Blank' this out, since it only matters for the first segment in a branch
			prev = nil
		until finished
	end

	return function()
		local startFrame = {
			center = LVec3.new(0, 0, 0),
			forward = LVec3.new(0, 1, 0),
			up = LVec3.new(0, 0, -1),
			radius = uniform(1.5, 2, "initradius"),
			v = 0
		}
		origradius = startFrame.radius
		prob.pushAddress("start")
		branch(startFrame, nil, 0)
		prob.popAddress()
	end
end)



