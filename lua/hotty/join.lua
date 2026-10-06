-- table.concat in batches. gopher-lua (plx's Lua) runs table.concat on a
-- fixed-size registry, and a table of a few thousand strings overflows it.

local concat = table.concat

local BATCH = 512

local function join(t, n)
	n = n or #t
	if n <= BATCH then
		return concat(t, "", 1, n)
	end
	local parts, k = {}, 0
	for i = 1, n, BATCH do
		local j = i + BATCH - 1
		if j > n then
			j = n
		end
		k = k + 1
		parts[k] = concat(t, "", i, j)
	end
	return join(parts, k)
end

return join
