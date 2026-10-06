-- JSON (RFC 8259) for what a host sends: capabilities, error bodies and event
-- details. Lua's standard library has none, and the wire layer depends on
-- that library only.
--
-- decode reads null as json.null, so that a key whose value is null is told
-- from one that is absent, and marks arrays (json.is_array), so that [] and {}
-- are told apart. encode writes what decode read as encoding/json does in Go
-- (the reference SDK's language): compact, object keys sorted, <, > and &
-- escaped.

local byte, char, sub, find, format = string.byte, string.char, string.sub, string.find, string.format
local floor = math.floor
local sort = table.sort
local join = require("hotty.join")

local M = {}

--- The value JSON's null decodes to.
M.null = setmetatable({}, {
	__tostring = function()
		return "null"
	end,
})

local ARRAY = { __jsontype = "array" }
local OBJECT = { __jsontype = "object" }

--- Whether t is an array that decode made.
function M.is_array(t)
	return type(t) == "table" and getmetatable(t) == ARRAY
end

--- Whether t is an object that decode made.
function M.is_object(t)
	return type(t) == "table" and getmetatable(t) == OBJECT
end

-- The deepest nesting decode takes. gopher-lua's call stack is small.
local MAX_DEPTH = 100

local function utf8(cp)
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

local ESCAPES =
	{ [34] = '"', [92] = "\\", [47] = "/", [98] = "\b", [102] = "\f", [110] = "\n", [114] = "\r", [116] = "\t" }

local decode_value

local function fail(i, what)
	error({ json = format("json: %s at byte %d", what, i) }, 0)
end

local function skip(s, i)
	local _, e = find(s, "^[ \t\r\n]*", i)
	return e + 1
end

local function decode_string(s, i)
	-- s[i] is the opening quote.
	local out, k = {}, 0
	i = i + 1
	while true do
		local j = find(s, '["\\%c]', i)
		if not j then
			fail(i, "unterminated string")
		end
		if j > i then
			k = k + 1
			out[k] = sub(s, i, j - 1)
		end
		local c = byte(s, j)
		if c == 34 then
			return join(out, k), j + 1
		elseif c ~= 92 then
			fail(j, "control character in string")
		end
		local e = byte(s, j + 1)
		if e == 117 then -- \uXXXX
			local hex = sub(s, j + 2, j + 5)
			if not hex:match("^%x%x%x%x$") then
				fail(j, "bad \\u escape")
			end
			local cp = tonumber(hex, 16)
			i = j + 6
			if cp >= 0xD800 and cp <= 0xDBFF then
				local lo = sub(s, i, i + 5):match("^\\u(%x%x%x%x)$")
				local lcp = lo and tonumber(lo, 16)
				if lcp and lcp >= 0xDC00 and lcp <= 0xDFFF then
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lcp - 0xDC00)
					i = i + 6
				end
			end
			k = k + 1
			out[k] = utf8(cp)
		elseif e and ESCAPES[e] then
			k = k + 1
			out[k] = ESCAPES[e]
			i = j + 2
		else
			fail(j, "bad escape")
		end
	end
end

-- -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?
local function decode_number(s, i)
	local j = i
	if byte(s, j) == 45 then
		j = j + 1
	end
	local c = byte(s, j)
	if c == 48 then
		j = j + 1
	elseif c and c >= 49 and c <= 57 then
		local _, e = find(s, "^%d*", j + 1)
		j = e + 1
	else
		fail(i, "bad number")
	end
	if byte(s, j) == 46 then
		local _, e = find(s, "^%d+", j + 1)
		if not e then
			fail(i, "bad number")
		end
		j = e + 1
	end
	c = byte(s, j)
	if c == 101 or c == 69 then
		j = j + 1
		c = byte(s, j)
		if c == 43 or c == 45 then
			j = j + 1
		end
		local _, e = find(s, "^%d+", j)
		if not e then
			fail(i, "bad number")
		end
		j = e + 1
	end
	return tonumber(sub(s, i, j - 1)), j
end

local function decode_array(s, i, depth)
	local out, n = setmetatable({}, ARRAY), 0
	i = skip(s, i + 1)
	if byte(s, i) == 93 then
		return out, i + 1
	end
	while true do
		local v
		v, i = decode_value(s, i, depth)
		n = n + 1
		out[n] = v
		i = skip(s, i)
		local c = byte(s, i)
		if c == 93 then
			return out, i + 1
		elseif c ~= 44 then
			fail(i, "expected , or ]")
		end
		i = skip(s, i + 1)
	end
end

local function decode_object(s, i, depth)
	local out = setmetatable({}, OBJECT)
	i = skip(s, i + 1)
	if byte(s, i) == 125 then
		return out, i + 1
	end
	while true do
		if byte(s, i) ~= 34 then
			fail(i, "expected a key")
		end
		local k
		k, i = decode_string(s, i)
		i = skip(s, i)
		if byte(s, i) ~= 58 then
			fail(i, "expected :")
		end
		local v
		v, i = decode_value(s, skip(s, i + 1), depth)
		out[k] = v
		i = skip(s, i)
		local c = byte(s, i)
		if c == 125 then
			return out, i + 1
		elseif c ~= 44 then
			fail(i, "expected , or }")
		end
		i = skip(s, i + 1)
	end
end

function decode_value(s, i, depth)
	if depth > MAX_DEPTH then
		fail(i, "too deep")
	end
	local c = byte(s, i)
	if c == 123 then
		return decode_object(s, i, depth + 1)
	elseif c == 91 then
		return decode_array(s, i, depth + 1)
	elseif c == 34 then
		return decode_string(s, i)
	elseif c == 45 or (c and c >= 48 and c <= 57) then
		return decode_number(s, i)
	elseif sub(s, i, i + 3) == "true" then
		return true, i + 4
	elseif sub(s, i, i + 4) == "false" then
		return false, i + 5
	elseif sub(s, i, i + 3) == "null" then
		return M.null, i + 4
	end
	fail(i, "unexpected input")
end

--- The value JSON text s holds, or nil and an error.
function M.decode(s)
	local ok, v, i = pcall(function()
		local v, i = decode_value(s, skip(s, 1), 0)
		return v, skip(s, i)
	end)
	if not ok then
		if type(v) == "table" and v.json then
			return nil, v.json
		end
		return nil, "json: " .. tostring(v)
	end
	if i <= #s then
		return nil, format("json: unexpected input at byte %d", i)
	end
	return v
end

-- Encoding --------------------------------------------------------------------

-- A number as Go's encoding/json writes a float64: the shortest digits that
-- read back as the same number, in fixed notation from 1e-6 up to 1e21, and in
-- exponent notation outside it.
local function encode_number(x)
	if x ~= x or x == math.huge or x == -math.huge then
		return nil
	end
	if x == 0 then
		return (1 / x < 0) and "-0" or "0"
	end
	local s
	for p = 1, 17 do
		s = format("%." .. (p - 1) .. "e", x)
		if tonumber(s) == x then
			break
		end
	end
	local sign, d1, ds, e = s:match("^(-?)(%d)%.?(%d*)e([-+]%d+)$")
	local digits = (d1 .. ds):gsub("0+$", "")
	if digits == "" then
		digits = "0"
	end
	local exp = tonumber(e)
	local a = math.abs(x)
	if a < 1e21 and a >= 1e-6 then
		local point = exp + 1 -- digits before the point
		if point <= 0 then
			return sign .. "0." .. string.rep("0", -point) .. digits
		elseif point >= #digits then
			return sign .. digits .. string.rep("0", point - #digits)
		end
		return sign .. sub(digits, 1, point) .. "." .. sub(digits, point + 1)
	end
	local mant = #digits > 1 and (sub(digits, 1, 1) .. "." .. sub(digits, 2)) or digits
	return sign .. mant .. "e" .. (exp < 0 and "-" or "+") .. tostring(math.abs(exp))
end

local STR_ESC = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["<"] = "\\u003c",
	[">"] = "\\u003e",
	["&"] = "\\u0026",
}

-- The length of the valid UTF-8 sequence at s[i], or nil.
local function utf8_len(s, i)
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
M.utf8_len = utf8_len

local function encode_string(s)
	local out, k, i, n = { '"' }, 1, 1, #s
	while i <= n do
		local j = find(s, '[%c"\\<>&\128-\255]', i)
		if not j then
			k = k + 1
			out[k] = sub(s, i)
			break
		end
		if j > i then
			k = k + 1
			out[k] = sub(s, i, j - 1)
		end
		local c = sub(s, j, j)
		local b = byte(c)
		k = k + 1
		if STR_ESC[c] then
			out[k] = STR_ESC[c]
			i = j + 1
		elseif b < 0x20 or b == 0x7F then
			out[k] = b == 0x7F and c or format("\\u%04x", b)
			i = j + 1
		else
			local len = utf8_len(s, j)
			if not len then
				out[k] = "\\ufffd"
				i = j + 1
			else
				local seq = sub(s, j, j + len - 1)
				if seq == "\226\128\168" then
					seq = "\\u2028"
				elseif seq == "\226\128\169" then
					seq = "\\u2029"
				end
				out[k] = seq
				i = j + len
			end
		end
	end
	out[k + 1] = '"'
	return join(out, k + 1)
end

local function encode_value(v, depth)
	if depth > MAX_DEPTH then
		error("json: too deep", 0)
	end
	local t = type(v)
	if v == M.null or v == nil then
		return "null"
	elseif t == "boolean" then
		return v and "true" or "false"
	elseif t == "number" then
		return encode_number(v) or error("json: not a finite number", 0)
	elseif t == "string" then
		return encode_string(v)
	elseif t == "table" then
		local out = {}
		if getmetatable(v) == ARRAY or (getmetatable(v) ~= OBJECT and #v > 0) then
			for i = 1, #v do
				out[#out + 1] = i > 1 and "," or "["
				out[#out + 1] = encode_value(v[i], depth + 1)
			end
			return #v > 0 and (join(out) .. "]") or "[]"
		end
		local keys = {}
		for key in pairs(v) do
			keys[#keys + 1] = tostring(key)
		end
		sort(keys)
		for i, key in ipairs(keys) do
			out[#out + 1] = i > 1 and "," or "{"
			out[#out + 1] = encode_string(key) .. ":" .. encode_value(v[key], depth + 1)
		end
		return #keys > 0 and (join(out) .. "}") or "{}"
	end
	error("json: cannot encode a " .. t, 0)
end

--- v as compact JSON text, or nil and an error.
function M.encode(v)
	local ok, s = pcall(encode_value, v, 0)
	if not ok then
		return nil, s
	end
	return s
end

return M
