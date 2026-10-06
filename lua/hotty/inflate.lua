-- zlib (RFC 1950) and DEFLATE (RFC 1951) decompression, in arithmetic, after
-- Mark Adler's puff. Hosts never compress (SPEC §3.3), so a program needs it
-- only to read what a program sent: a relay, or a test of its own output.

local byte, char = string.byte, string.char
local floor = math.floor
local join = require("hotty.join")

local M = {}

-- The most bytes inflate makes, so that a small payload cannot exhaust memory.
M.MAX = 16 * 1024 * 1024

local pow2 = {}
for i = 0, 40 do
	pow2[i] = 2 ^ i
end

local function bits(st, need)
	local buf, cnt = st.buf, st.cnt
	while cnt < need do
		local b = byte(st.src, st.pos)
		if not b then
			error("inflate: unexpected end", 0)
		end
		st.pos = st.pos + 1
		buf = buf + b * pow2[cnt]
		cnt = cnt + 8
	end
	local p = pow2[need]
	local v = buf % p
	st.buf = (buf - v) / p
	st.cnt = cnt - need
	return v
end

-- A canonical Huffman code from code lengths: count[len] codes of each
-- length, and the symbols in code order.
local function construct(lengths, n)
	local h = { count = {}, symbol = {} }
	for len = 0, 15 do
		h.count[len] = 0
	end
	for s = 0, n - 1 do
		local l = lengths[s] or 0
		h.count[l] = h.count[l] + 1
	end
	local left = 1
	for len = 1, 15 do
		left = left * 2 - h.count[len]
		if left < 0 then
			error("inflate: over-subscribed code", 0)
		end
	end
	local offs = { [1] = 0 }
	for len = 1, 14 do
		offs[len + 1] = offs[len] + h.count[len]
	end
	for s = 0, n - 1 do
		local l = lengths[s] or 0
		if l ~= 0 then
			h.symbol[offs[l]] = s
			offs[l] = offs[l] + 1
		end
	end
	return h
end

local function decode(st, h)
	local code, first, index = 0, 0, 0
	local count = h.count
	for len = 1, 15 do
		code = code + bits(st, 1)
		local c = count[len]
		if code - c < first then
			return h.symbol[index + (code - first)]
		end
		index = index + c
		first = (first + c) * 2
		code = code * 2
	end
	error("inflate: bad code", 0)
end

local LBASE = {
	[0] = 3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}
local LEXT = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = {
	[0] = 1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
}
local DEXT = { [0] = 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local fixed_lit, fixed_dist

local function codes(st, lit, dist)
	local out = st.out
	while true do
		local sym = decode(st, lit)
		if sym < 256 then
			local n = st.n + 1
			if n > M.MAX then
				error("inflate: too large", 0)
			end
			out[n] = sym
			st.n = n
		elseif sym == 256 then
			return
		else
			sym = sym - 257
			if sym >= 29 then
				error("inflate: bad length", 0)
			end
			local len = LBASE[sym] + bits(st, LEXT[sym])
			local ds = decode(st, dist)
			if ds >= 30 then
				error("inflate: bad distance", 0)
			end
			local d = DBASE[ds] + bits(st, DEXT[ds])
			local n = st.n
			if d > n then
				error("inflate: distance too far back", 0)
			end
			if n + len > M.MAX then
				error("inflate: too large", 0)
			end
			for i = 1, len do
				out[n + i] = out[n + i - d]
			end
			st.n = n + len
		end
	end
end

local function stored(st)
	st.buf, st.cnt = 0, 0 -- the rest of the current byte
	local a, b, c, d = byte(st.src, st.pos, st.pos + 3)
	if not d then
		error("inflate: unexpected end", 0)
	end
	local len = a + b * 256
	if len ~= 65535 - (c + d * 256) then
		error("inflate: bad stored length", 0)
	end
	st.pos = st.pos + 4
	if st.pos + len - 1 > #st.src then
		error("inflate: unexpected end", 0)
	end
	if st.n + len > M.MAX then
		error("inflate: too large", 0)
	end
	local out, n = st.out, st.n
	for i = 0, len - 1 do
		out[n + i + 1] = byte(st.src, st.pos + i)
	end
	st.n = n + len
	st.pos = st.pos + len
end

local function dynamic(st)
	local nlen = bits(st, 5) + 257
	local ndist = bits(st, 5) + 1
	local ncode = bits(st, 4) + 4
	if nlen > 286 or ndist > 30 then
		error("inflate: bad counts", 0)
	end
	local lengths = {}
	for i = 1, 19 do
		lengths[ORDER[i]] = i <= ncode and bits(st, 3) or 0
	end
	local lencode = construct(lengths, 19)
	lengths = {}
	local index = 0
	while index < nlen + ndist do
		local sym = decode(st, lencode)
		if sym < 16 then
			lengths[index] = sym
			index = index + 1
		else
			local len, rep = 0, 0
			if sym == 16 then
				if index == 0 then
					error("inflate: repeat with no first length", 0)
				end
				len = lengths[index - 1]
				rep = 3 + bits(st, 2)
			elseif sym == 17 then
				rep = 3 + bits(st, 3)
			else
				rep = 11 + bits(st, 7)
			end
			if index + rep > nlen + ndist then
				error("inflate: too many lengths", 0)
			end
			for _ = 1, rep do
				lengths[index] = len
				index = index + 1
			end
		end
	end
	if (lengths[256] or 0) == 0 then
		error("inflate: no end-of-block code", 0)
	end
	local lit = construct(lengths, nlen)
	local dl = {}
	for i = 0, ndist - 1 do
		dl[i] = lengths[nlen + i]
	end
	local dist = construct(dl, ndist)
	codes(st, lit, dist)
end

local function fixed(st)
	if not fixed_lit then
		local l = {}
		for s = 0, 143 do
			l[s] = 8
		end
		for s = 144, 255 do
			l[s] = 9
		end
		for s = 256, 279 do
			l[s] = 7
		end
		for s = 280, 287 do
			l[s] = 8
		end
		fixed_lit = construct(l, 288)
		local d = {}
		for s = 0, 29 do
			d[s] = 5
		end
		fixed_dist = construct(d, 30)
	end
	codes(st, fixed_lit, fixed_dist)
end

local function to_string(out, n)
	local parts, k = {}, 0
	for i = 1, n, 256 do
		local j = i + 255
		if j > n then
			j = n
		end
		k = k + 1
		parts[k] = char(unpack(out, i, j))
	end
	return join(parts, k)
end

--- The bytes a raw DEFLATE stream holds from byte pos, and the position
--- after it. Errors are raised.
local function raw(src, pos)
	local st = { src = src, pos = pos or 1, buf = 0, cnt = 0, out = {}, n = 0 }
	repeat
		local last = bits(st, 1)
		local kind = bits(st, 2)
		if kind == 0 then
			stored(st)
		elseif kind == 1 then
			fixed(st)
		elseif kind == 2 then
			dynamic(st)
		else
			error("inflate: bad block type", 0)
		end
	until last == 1
	return to_string(st.out, st.n), st.pos
end

local function adler32(s)
	local a, b = 1, 0
	for i = 1, #s, 4096 do
		local j = i + 4095
		if j > #s then
			j = #s
		end
		for k = i, j do
			a = a + byte(s, k)
			b = b + a
		end
		a = a % 65521
		b = b % 65521
	end
	return b * 65536 + a
end

--- The bytes zlib data holds, or nil and an error: a bad header, a bad
--- stream, a checksum that does not match, or more than M.MAX bytes.
function M.zlib(src)
	local cmf, flg = byte(src, 1, 2)
	if not flg or cmf % 16 ~= 8 or floor(cmf / 16) > 7 or (cmf * 256 + flg) % 31 ~= 0 then
		return nil, "inflate: not zlib"
	end
	if floor(flg / 32) % 2 == 1 then
		return nil, "inflate: a preset dictionary"
	end
	local ok, out, pos = pcall(raw, src, 3)
	if not ok then
		return nil, out
	end
	local a, b, c, d = byte(src, pos, pos + 3)
	if not d or ((a * 256 + b) * 256 + c) * 256 + d ~= adler32(out) then
		return nil, "inflate: bad checksum"
	end
	return out
end

return M
