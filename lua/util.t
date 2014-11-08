local U = {}

function U.newcopy(x)
	if x.newcopy then
		return x:newcopy()
	else
		return x
	end
end


return U