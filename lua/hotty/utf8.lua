-- UTF-8 (RFC 3629), in arithmetic: the wire layer cleans values, names
-- surfaces and keys, splits a field's value into characters, and checks a
-- host's strings (hotty.msgpack), and Lua 5.1 has no utf8 library.

local byte, char, find = string.byte, string.char, string.find
local floor = math.floor

local M = {}

--- The length of the valid UTF-8 sequence at s[i], or nil: no overlong
--- form, no surrogate, nothing past U+10FFFF.
function M.len(s, i)
	local c = byte(s, i)
	if c < 0x80 then
		return 1
	end
	local n, lo, hi
	if c >= 0xC2 and c <= 0xDF then
		n, lo, hi = 2, 0x80, 0xBF
	elseif c == 0xE0 then
		n, lo, hi = 3, 0xA0, 0xBF
	elseif (c >= 0xE1 and c <= 0xEC) or c == 0xEE or c == 0xEF then
		n, lo, hi = 3, 0x80, 0xBF
	elseif c == 0xED then
		n, lo, hi = 3, 0x80, 0x9F
	elseif c == 0xF0 then
		n, lo, hi = 4, 0x90, 0xBF
	elseif c >= 0xF1 and c <= 0xF3 then
		n, lo, hi = 4, 0x80, 0xBF
	elseif c == 0xF4 then
		n, lo, hi = 4, 0x80, 0x8F
	else
		return nil
	end
	local c2 = byte(s, i + 1)
	if not c2 or c2 < lo or c2 > hi then
		return nil
	end
	for k = 2, n - 1 do
		local ck = byte(s, i + k)
		if not ck or ck < 0x80 or ck > 0xBF then
			return nil
		end
	end
	return n
end

local len = M.len

--- Whether s is UTF-8 throughout.
function M.valid(s)
	local i = find(s, "[\128-\255]")
	while i do
		local n = len(s, i)
		if not n then
			return false
		end
		i = find(s, "[\128-\255]", i + n)
	end
	return true
end

--- The UTF-8 of a code point.
function M.char(cp)
	if cp < 0x80 then
		return char(cp)
	elseif cp < 0x800 then
		return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return char(
		0xF0 + floor(cp / 0x40000),
		0x80 + floor(cp / 0x1000) % 0x40,
		0x80 + floor(cp / 0x40) % 0x40,
		0x80 + cp % 0x40
	)
end

return M
