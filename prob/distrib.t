
-- TODO: Default proposals for some of these?

local bernoulli =
{
	sample = function(p) return math.random() < p end,
	logprob = function(val, p)
		local prob = val and p or 1-p
		return math.log(prob)
	end,
	propose = function(val, p)
		return (not val), 0, 0
	end
}

local uniform =
{
	sample = function(lo, hi)
		local u = math.random()
		return (1-u)*lo + u*hi
	end,
	logprob = function(val, lo, hi)
		if val < lo or val > hi then return -math.huge end
		return -math.log(hi - lo)
	end
}

local multinomial = 
{
	sample = function(weights)
		local N = #weights
		local sum = 0
		for _,w in ipairs(weights) do sum = sum + w end
		local result = 1
		local x = math.random() * sum
		local probAccum = 0
		repeat
			probAccum = probAccum + weights[result]
			result = result + 1
		until probAccum > x or result > N
		return result - 1
	end,
	logprob = function(n, weights)
		if n < 1 or n > #weights then
			return -math.huge
		else
			n = math.ceil(n)
			local sum = 0
			for _,w in ipairs(weights) do sum = sum + w end
			return math.log(weights[n]/sum)
		end
	end
}

local gaussian = 
{
	sample = function(mu, sigma)
		local u, v, x, y, q
		repeat
			u = 1 - math.random()
			v = 1.7156 * (math.random() - 0.5)
			x = u - 0.449871
			y = math.abs(v) + 0.386595
			q = x*x + y*(0.196*y - 0.25472*x)
		until not(q >= 0.27597 and (q > 0.27846 or v*v > -4 * u * u * math.log(u)))
		return mu + sigma*v/u
	end,
	logprob = function(x, mu, sigma)
		local xminusmu = x - mu
		return -.5*(1.8378770664093453 + 2*math.log(sigma) + xminusmu*xminusmu/(sigma*sigma))
	end
}
function gaussian.propose(currval, mu, sigma)
	local newval = gaussian.sample(currval, sigma)
	local fwdlp = gaussian.logprob(newval, currval, sigma)
	local rvslp = gaussian.logprob(currval, newval, sigma)
	return newval, fwdlp, rvslp
end



return
{
	bernoulli = bernoulli,
	uniform = uniform,
	multinomial = multinomial,
	gaussian = gaussian
}

