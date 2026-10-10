-- JSON (RFC 8259), to read the conformance vectors (tests/vectors.json):
-- the wire layer reads no JSON, and Lua's standard library has none. Under
-- nvim -l, tests/vectors.lua checks that it reads them as vim.json does.
--
-- decode reads null as json.null, so that a key whose value is null is told
-- from one that is absent, and marks arrays (json.is_array), so that [] and {}
-- are told apart.

local byte, sub, find, format = string.byte, string.sub, string.find, string.format
local join = require("hotty.join")
local utf8 = require("hotty.utf8").char

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

return M
