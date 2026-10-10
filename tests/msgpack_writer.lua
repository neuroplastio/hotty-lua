-- msgpack as a host writes it (SPEC §3.3), for the tests' fake hosts: the
-- wire layer only reads it. An int goes out in its smallest form, a number
-- with a fraction as a float64, and a whole one too when wrapped in
-- float(). A table with keys 1 to n, or wrapped in array(), is an array;
-- any other a map, its keys sorted.

local char = string.char
local floor = math.floor
local concat, sort = table.concat, table.sort

local M = {}

local FLOAT, ARRAY = {}, {}

--- nil, which a table cannot hold, and a host does not send (SPEC §3.3): for
--- bodies that do not decode.
M.NIL = setmetatable({}, {
	__tostring = function()
		return "nil"
	end,
})

--- x, to go out as a float even when whole.
function M.float(x)
	return setmetatable({ x }, FLOAT)
end

--- t, to go out as an array even when empty.
function M.array(t)
	return setmetatable(t, ARRAY)
end

-- v >= 0 as n bytes, big-endian.
local function be(v, n)
	local out = {}
	for k = n, 1, -1 do
		out[k] = char(v % 256)
		v = floor(v / 256)
	end
	return concat(out)
end

-- v < 0 as n bytes of two's complement, without 2^64, which no double holds
-- to the unit.
local function neg(v, n)
	local b = { be(-v - 1, n):byte(1, n) }
	for k = 1, n do
		b[k] = char(255 - b[k])
	end
	return concat(b)
end

local function int(v)
	if v >= 0 then
		if v < 0x80 then
			return char(v)
		elseif v < 0x100 then
			return "\204" .. be(v, 1)
		elseif v < 0x10000 then
			return "\205" .. be(v, 2)
		elseif v < 0x100000000 then
			return "\206" .. be(v, 4)
		end
		return "\207" .. be(v, 8)
	elseif v >= -32 then
		return char(v + 256)
	elseif v >= -0x80 then
		return "\208" .. neg(v, 1)
	elseif v >= -0x8000 then
		return "\209" .. neg(v, 2)
	elseif v >= -0x80000000 then
		return "\210" .. neg(v, 4)
	end
	return "\211" .. neg(v, 8)
end

local function float64(x)
	if x ~= x then
		return "\203\127\248\0\0\0\0\0\0"
	end
	local sign = 0
	if x < 0 or (x == 0 and 1 / x < 0) then
		sign, x = 0x80, -x
	end
	local e, m
	if x == 0 then
		e, m = 0, 0
	elseif x > 1.7976931348623157e308 then
		e, m = 2047, 0
	else
		e = floor(math.log(x) / math.log(2))
		while 2 ^ e > x do
			e = e - 1
		end
		while 2 ^ (e + 1) <= x do
			e = e + 1
		end
		-- Apart: gopher-lua v1.1.2 assigns e before it reads the next value.
		if e < -1022 then -- subnormal
			m = x / 2 ^ -1022 * 2 ^ 52
			e = 0
		else
			m = (x / 2 ^ e - 1) * 2 ^ 52
			e = e + 1023
		end
	end
	return "\203" .. char(sign + floor(e / 16), (e % 16) * 16 + floor(m / 2 ^ 48)) .. be(m % 2 ^ 48, 6)
end

local function str(s)
	local n = #s
	if n < 32 then
		return char(0xA0 + n) .. s
	elseif n < 0x100 then
		return "\217" .. be(n, 1) .. s
	elseif n < 0x10000 then
		return "\218" .. be(n, 2) .. s
	end
	return "\219" .. be(n, 4) .. s
end

local function header(n, fix, b16, b32)
	if n < 16 then
		return char(fix + n)
	elseif n < 0x10000 then
		return b16 .. be(n, 2)
	end
	return b32 .. be(n, 4)
end

local function before(a, b)
	if type(a) ~= type(b) then
		return type(a) < type(b)
	end
	return a < b
end

local function value(v, out)
	local t = type(v)
	if v == nil or v == M.NIL then
		out[#out + 1] = "\192"
	elseif t == "boolean" then
		out[#out + 1] = v and "\195" or "\194"
	elseif t == "number" then
		out[#out + 1] = (v == floor(v) and v > -2 ^ 63 and v < 2 ^ 64) and int(v) or float64(v)
	elseif t == "string" then
		out[#out + 1] = str(v)
	elseif getmetatable(v) == FLOAT then
		out[#out + 1] = float64(v[1])
	else
		local n, keys = 0, {}
		for k in pairs(v) do
			n = n + 1
			keys[n] = k
		end
		local array = getmetatable(v) == ARRAY or n > 0
		for i = 1, n do
			array = array and v[i] ~= nil
		end
		if array then
			out[#out + 1] = header(n, 0x90, "\220", "\221")
			for i = 1, n do
				value(v[i], out)
			end
			return
		end
		sort(keys, before)
		out[#out + 1] = header(n, 0x80, "\222", "\223")
		for _, k in ipairs(keys) do
			value(k, out)
			value(v[k], out)
		end
	end
end

--- v's msgpack.
function M.pack(v)
	local out = {}
	value(v, out)
	return concat(out)
end

return M
