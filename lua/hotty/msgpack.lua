-- MessagePack (https://github.com/msgpack/msgpack/blob/master/spec.md) for
-- what a host sends: the bodies of its replies and events (SPEC §3.3). It
-- only decodes, in arithmetic: gopher-lua, which plx embeds, has no bit
-- library, and this runs the same everywhere.
--
-- Values are plain tables with no metatables, so that a host's own decoder
-- can give the same answers: init.lua reaches this one only through
-- require("hotty.msgpack"). docs/plx.md has the contract, and tests/unit.lua
-- pins its edges.

local byte, sub, format = string.byte, string.sub, string.format
local floor = math.floor
local utf8 = require("hotty.utf8")

local M = {}

M.MAX_DEPTH = 32 -- the most levels a value nests, the outermost container being the first
M.MAX_INT = 2 ^ 53 - 1 -- the furthest an int may be from 0: a double holds it exactly

local INF = math.huge * 2 -- gopher-lua's math.huge is the largest double, not infinity

local function fail(what)
	error({ msgpack = "msgpack: " .. what }, 0)
end

local function need(s, i, n)
	if i + n - 1 > #s then
		fail("cut short")
	end
end

-- Big-endian, unsigned, of n bytes at i: exact below 2^53.
local function uint(s, i, n)
	need(s, i, n)
	local v = 0
	for k = i, i + n - 1 do
		v = v * 256 + byte(s, k)
	end
	return v
end

-- An int of n bytes at i, big-endian, two's complement when signed. One
-- further than MAX_INT from 0 fails, as what (an int, by default). In 8
-- bytes, that is told from the first 11 bits, which must all be the sign,
-- before anything is summed: so nothing is rounded, or wraps where Lua's
-- ints are 64 bits.
local function int(s, i, n, signed, what)
	need(s, i, n)
	local neg = signed and byte(s, i) >= 0x80
	what = what or "an int"
	if n == 8 then
		local b1, b2 = byte(s, i, i + 1)
		if (neg and (b1 ~= 0xFF or b2 < 0xE0)) or (not neg and (b1 ~= 0 or b2 >= 0x20)) then
			fail(what .. " further than 2^53 - 1 from 0")
		end
	end
	if not neg then
		return uint(s, i, n)
	end
	local v = 0
	for k = i, i + n - 1 do
		v = v * 256 + (255 - byte(s, k))
	end
	v = -v - 1
	if v < -M.MAX_INT then -- -2^53, which the first bits let through
		fail(what .. " further than 2^53 - 1 from 0")
	end
	return v
end

-- An IEEE 754 float of 4 or 8 bytes at i. The sign goes on last, by
-- negation: gopher-lua's -1 * 0 is 0, not -0.
local function float(s, i, n)
	need(s, i, n)
	local b1, b2 = byte(s, i, i + 1)
	local e, m, bias, bits
	if n == 4 then
		e, m, bias, bits = (b1 % 0x80) * 2 + floor(b2 / 0x80), uint(s, i + 1, 3) % 0x800000, 127, 23
	else
		e, m, bias, bits = (b1 % 0x80) * 16 + floor(b2 / 16), (b2 % 16) * 2 ^ 48 + uint(s, i + 2, 6), 1023, 52
	end
	local v
	if e == 2 * bias + 1 then
		if m ~= 0 then
			return 0 / 0
		end
		v = INF
	elseif e == 0 then -- zero, or subnormal: no 1 before the point
		v = (m / 2 ^ bits) * 2 ^ (1 - bias)
	else
		v = (1 + m / 2 ^ bits) * 2 ^ (e - bias)
	end
	if b1 >= 0x80 then
		return -v
	end
	return v
end

-- Extension -1, a timestamp in n bytes at i: { sec, nsec }. Its seconds are
-- an int, at most MAX_INT from 1970 (in 12 bytes; fewer cannot pass it), and
-- its nanoseconds under a second.
local function timestamp(s, i, n)
	local sec, nsec
	if n == 4 then
		sec, nsec = uint(s, i, 4), 0
	elseif n == 8 then
		local hi = uint(s, i, 4) -- 30 bits of nanoseconds, then the seconds' top 2
		sec, nsec = (hi % 4) * 2 ^ 32 + uint(s, i + 4, 4), floor(hi / 4)
	elseif n == 12 then
		sec, nsec = int(s, i + 4, 8, true, "a timestamp's seconds"), uint(s, i, 4)
	else
		fail(format("a timestamp of %d bytes", n))
	end
	if nsec > 999999999 then
		fail("a timestamp's nanoseconds past a second")
	end
	return { sec = sec, nsec = nsec }
end

-- An extension of n bytes at i, after its type, and its kind: a timestamp,
-- "time", or nil for any other type, which is absent, "ext".
local function ext(s, i, n)
	need(s, i, n + 1)
	if byte(s, i) == 0xFF then
		return timestamp(s, i + 1, n), i + 1 + n, "time"
	end
	return nil, i + 1 + n, "ext"
end

-- A str (UTF-8) or a bin of n bytes at i, and a bin's kind.
local function bytes(s, i, n, str)
	need(s, i, n)
	local v = sub(s, i, i + n - 1)
	if not str then
		return v, i + n, "bin"
	elseif not utf8.valid(v) then
		fail("a str that is not UTF-8")
	end
	return v, i + n
end

local read

-- A container of n values (size 1) or pairs (2) at i, a level below depth.
local function enter(s, i, n, depth, size)
	if depth >= M.MAX_DEPTH then
		fail(format("nested more than %d levels", M.MAX_DEPTH))
	elseif n * size > #s - i + 1 then -- each value takes a byte at least
		fail("cut short")
	end
end

local function array(s, i, n, depth, kinds)
	enter(s, i, n, depth, 1)
	local t, marks = {}, nil
	for k = 1, n do
		local v, kind
		v, i, kind = read(s, i, depth + 1, kinds)
		t[k] = v -- an absent extension leaves a hole
		if kind then
			marks = marks or {}
			marks[k] = kind
		end
	end
	if marks then
		kinds[t] = marks
	end
	return t, i, "array"
end

-- Whether c starts a str: fixstr, or str 8, 16 or 32.
local function is_str(c)
	return (c >= 0xA0 and c < 0xC0) or (c >= 0xD9 and c <= 0xDB)
end

local function map(s, i, n, depth, kinds)
	enter(s, i, n, depth, 2)
	local t, marks = {}, nil
	for _ = 1, n do
		local c = byte(s, i)
		if c and not is_str(c) then -- no byte at all is cut short, which read says
			fail("a map key that is not a str")
		end
		local k, v, kind
		k, i = read(s, i, depth + 1, kinds)
		-- Every key given has a value or a mark: an absent one is "ext".
		if t[k] ~= nil or (marks and marks[k]) then
			fail("a key given twice")
		end
		v, i, kind = read(s, i, depth + 1, kinds)
		t[k] = v -- an absent extension leaves the key out
		if kind then
			marks = marks or {}
			marks[k] = kind
		end
	end
	if marks then
		kinds[t] = marks
	end
	return t, i
end

local SIZES = { 1, 2, 4, 8, 16 }

-- The forms whose length comes first, in 1, 2 or 4 bytes.
local SIZED = {
	[0xC4] = { "bin", 1 },
	[0xC5] = { "bin", 2 },
	[0xC6] = { "bin", 4 },
	[0xC7] = { "ext", 1 },
	[0xC8] = { "ext", 2 },
	[0xC9] = { "ext", 4 },
	[0xD9] = { "str", 1 },
	[0xDA] = { "str", 2 },
	[0xDB] = { "str", 4 },
	[0xDC] = { "array", 2 },
	[0xDD] = { "array", 4 },
	[0xDE] = { "map", 2 },
	[0xDF] = { "map", 4 },
}

-- The value at s[i], depth containers deep: it, the index after it, and its
-- kind where a Lua value cannot show its msgpack type (M.decode).
read = function(s, i, depth, kinds)
	local c = byte(s, i)
	if not c then
		fail("cut short")
	end
	i = i + 1
	if c < 0x80 then
		return c, i
	elseif c < 0x90 then
		return map(s, i, c - 0x80, depth, kinds)
	elseif c < 0xA0 then
		return array(s, i, c - 0x90, depth, kinds)
	elseif c < 0xC0 then
		return bytes(s, i, c - 0xA0, true)
	elseif c >= 0xE0 then
		return c - 0x100, i
	elseif c == 0xC0 then
		fail("a nil")
	elseif c == 0xC2 or c == 0xC3 then
		return c == 0xC3, i
	elseif c == 0xCA or c == 0xCB then
		local n = c == 0xCA and 4 or 8
		return float(s, i, n), i + n, "float"
	elseif c >= 0xCC and c <= 0xD3 then
		local unsigned = c <= 0xCF
		local n = SIZES[unsigned and c - 0xCB or c - 0xCF]
		return int(s, i, n, not unsigned), i + n
	elseif c >= 0xD4 and c <= 0xD8 then
		return ext(s, i, SIZES[c - 0xD3])
	end
	local form = SIZED[c]
	if not form then
		fail(format("no type starts with 0x%02x", c))
	end
	local kind, w = form[1], form[2]
	local n = uint(s, i, w)
	i = i + w
	if kind == "str" or kind == "bin" then
		return bytes(s, i, n, kind == "str")
	elseif kind == "ext" then
		return ext(s, i, n)
	elseif kind == "array" then
		return array(s, i, n, depth, kinds)
	end
	return map(s, i, n, depth, kinds)
end

--- The one value s holds, and its kinds: a table whose keys are the tables
--- of the value, kinds[t][k] the msgpack type of t[k] where a Lua value
--- cannot show it ("float", "bin", "array", "time", "ext"). nil and an error
--- ("msgpack: …") when s is not one value, which a nil, a map key that is
--- not a str or a key given twice anywhere in it makes it: docs/plx.md has
--- the whole contract.
function M.decode(s)
	if type(s) ~= "string" then
		return nil, "msgpack: not a string"
	end
	local kinds = {}
	local ok, v, i = pcall(read, s, 1, 0, kinds)
	if not ok then
		if type(v) == "table" and v.msgpack then
			return nil, v.msgpack
		end
		return nil, "msgpack: " .. tostring(v)
	end
	if i <= #s then
		return nil, "msgpack: bytes after the value"
	end
	return v, kinds
end

return M
