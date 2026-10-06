-- Base64 (RFC 4648, the standard alphabet), in arithmetic: gopher-lua, which
-- plx embeds, has no bit library, and this runs the same everywhere.

local byte, char, sub, find = string.byte, string.char, string.sub, string.find
local floor = math.floor
local join = require("hotty.join")

local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local enc = {} -- 0..63 to a character
local pair = {} -- 0..4095 to two characters
local dec = {} -- a character's byte to 0..63
for i = 0, 63 do
	enc[i] = sub(ALPHABET, i + 1, i + 1)
	dec[byte(ALPHABET, i + 1)] = i
end
for i = 0, 4095 do
	pair[i] = enc[floor(i / 64)] .. enc[i % 64]
end

--- The base64 of s, padded.
function M.encode(s)
	local n = #s
	local out, k = {}, 0
	local last = n - n % 3
	for i = 1, last, 3 do
		local a, b, c = byte(s, i, i + 2)
		local v = a * 65536 + b * 256 + c
		local hi = floor(v / 4096)
		k = k + 1
		out[k] = pair[hi] .. pair[v - hi * 4096]
	end
	local rem = n - last
	if rem == 1 then
		k = k + 1
		out[k] = pair[byte(s, n) * 16] .. "=="
	elseif rem == 2 then
		local a, b = byte(s, n - 1, n)
		local v = (a * 256 + b) * 4
		local hi = floor(v / 64)
		k = k + 1
		out[k] = pair[hi] .. enc[v - hi * 64] .. "="
	end
	return join(out, k)
end

--- The bytes of base64 text, with or without padding, whitespace ignored.
--- nil when it is not base64: a byte outside the alphabet, padding before
--- the end, or a length no base64 has.
function M.decode(s)
	-- No pattern repeats over the data: gopher-lua's matcher gives up on
	-- long input.
	if find(s, "%s") then
		s = s:gsub("%s", "")
	end
	local data = s
	if sub(data, -2) == "==" then
		data = sub(data, 1, -3)
	elseif sub(data, -1) == "=" then
		data = sub(data, 1, -2)
	end
	if find(data, "[^A-Za-z0-9+/]") or #data % 4 == 1 then
		return nil
	end
	local n = #data
	local out, k = {}, 0
	local last = n - n % 4
	for i = 1, last, 4 do
		local a, b, c, d = byte(data, i, i + 3)
		local v = dec[a] * 262144 + dec[b] * 4096 + dec[c] * 64 + dec[d]
		local x = floor(v / 65536)
		local y = floor(v / 256) % 256
		k = k + 1
		out[k] = char(x, y, v % 256)
	end
	local rem = n - last
	if rem == 2 then
		local a, b = byte(data, last + 1, last + 2)
		k = k + 1
		out[k] = char(floor((dec[a] * 64 + dec[b]) / 16))
	elseif rem == 3 then
		local a, b, c = byte(data, last + 1, last + 3)
		local v = floor((dec[a] * 4096 + dec[b] * 64 + dec[c]) / 4)
		k = k + 1
		out[k] = char(floor(v / 256), v % 256)
	end
	return join(out, k)
end

return M
