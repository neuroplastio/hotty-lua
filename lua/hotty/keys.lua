--- What a text field does with a key (SDK.md §3.10; SPEC §10.2, §10.4): key
--- names, the keys in the terminal's input, keymaps, and the SDK's keymap. It
--- is part of the wire layer, and hotty has it all: hotty.parse_key,
--- hotty.decode_keys, hotty.parse_keymap, hotty.resolve, hotty.TERMINAL_KEYS.
---
--- Characters are code points, CR LF one: Lua has no grapheme segmentation
--- (SDK.md §4.6). Shift makes a capital of a letter in ASCII, Latin-1, and
--- the basic Greek and Cyrillic alphabets.
local json = require("hotty.json")

local byte, char, sub, find, gmatch = string.byte, string.char, string.sub, string.find, string.gmatch
local floor = math.floor
local concat = table.concat
local utf8_len, utf8 = json.utf8_len, json.utf8

local M = {}

M.MODIFIERS = { "Control", "Alt", "Meta", "Shift" }

-- The actions of SPEC §10.2.
M.ACTIONS = {
	"char-backward",
	"char-forward",
	"word-backward",
	"word-forward",
	"line-start",
	"line-end",
	"delete-char-backward",
	"delete-char-forward",
	"delete-word-backward",
	"delete-word-forward",
	"delete-to-line-start",
	"delete-to-line-end",
	"line-previous",
	"line-next",
	"page-up",
	"page-down",
	"input-start",
	"input-end",
	"newline",
	"submit",
	"program",
}
local ACTION = {}
for _, a in ipairs(M.ACTIONS) do
	ACTION[a] = true
end

-- The actions only a multi-line field has.
M.MULTILINE_ACTIONS = {
	["line-previous"] = true,
	["line-next"] = true,
	["page-up"] = true,
	["page-down"] = true,
	["input-start"] = true,
	["input-end"] = true,
	["newline"] = true,
}

-- What lookup returns for a character the field types.
M.INSERT = "insert"

-- The SDK's keymap (SDK.md §3.10): Bubble Tea's text input and text area.
M.TERMINAL_KEYS = concat({
	"ArrowLeft=char-backward Control+b=char-backward ArrowRight=char-forward Control+f=char-forward",
	"Alt+ArrowLeft=word-backward Control+ArrowLeft=word-backward Alt+b=word-backward",
	"Alt+ArrowRight=word-forward Control+ArrowRight=word-forward Alt+f=word-forward",
	"Home=line-start Control+a=line-start End=line-end Control+e=line-end",
	"Backspace=delete-char-backward Control+h=delete-char-backward",
	"Delete=delete-char-forward Control+d=delete-char-forward",
	"Alt+Backspace=delete-word-backward Control+w=delete-word-backward Control+Backspace=delete-word-backward",
	"Alt+Delete=delete-word-forward Alt+d=delete-word-forward Control+Delete=delete-word-forward",
	"Control+u=delete-to-line-start Control+k=delete-to-line-end",
	"ArrowUp=line-previous Control+p=line-previous ArrowDown=line-next Control+n=line-next",
	"PageUp=page-up PageDown=page-down",
	"Alt+<=input-start Control+Home=input-start Alt+>=input-end Control+End=input-end",
	"Control+m=newline",
}, " ")

-- Characters ------------------------------------------------------------------

--- A text's characters: its code points, CR LF one, and each byte that is
--- not UTF-8 one.
function M.chars(s)
	local out, k, i, n = {}, 0, 1, #s
	while i <= n do
		local len = sub(s, i, i + 1) == "\r\n" and 2 or utf8_len(s, i) or 1
		k = k + 1
		out[k] = sub(s, i, i + len - 1)
		i = i + len
	end
	return out
end

-- The code point of a one-character string, or nil.
local function code_point(c)
	local b = byte(c, 1)
	local n = b and utf8_len(c, 1)
	if not n or n ~= #c then
		return nil
	end
	if n == 1 then
		return b
	end
	local cp = b % (n == 2 and 0x20 or n == 3 and 0x10 or 0x08)
	for i = 2, n do
		cp = cp * 0x40 + byte(c, i) % 0x40
	end
	return cp
end

-- Whether v is one character that a key types: not a control.
local function is_char(v)
	local cs = M.chars(v)
	if #cs ~= 1 or not utf8_len(v, 1) then
		return false
	end
	local b = byte(v, 1)
	return b >= 0x20 and b ~= 0x7F
end

-- The capital of a small letter, and the small letter of a capital, for one
-- code point: ASCII, Latin-1, basic Greek and Cyrillic.
local function upper_cp(cp)
	if (cp >= 0x61 and cp <= 0x7A) or (cp >= 0xE0 and cp <= 0xFE and cp ~= 0xF7) then
		return cp - 0x20
	elseif cp >= 0x3B1 and cp <= 0x3C9 and cp ~= 0x3C2 then
		return cp - 0x20
	elseif cp >= 0x430 and cp <= 0x44F then
		return cp - 0x20
	elseif cp >= 0x450 and cp <= 0x45F then
		return cp - 0x50
	end
	return cp
end

local function lower_cp(cp)
	if (cp >= 0x41 and cp <= 0x5A) or (cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7) then
		return cp + 0x20
	elseif cp >= 0x391 and cp <= 0x3A9 and cp ~= 0x3A2 then
		return cp + 0x20
	elseif cp >= 0x410 and cp <= 0x42F then
		return cp + 0x20
	elseif cp >= 0x400 and cp <= 0x40F then
		return cp + 0x50
	end
	return cp
end

-- Key names (SPEC §10.4) ----------------------------------------------------------

local MODIFIER = { Control = 1, Alt = 2, Meta = 3, Shift = 4 }

-- s split at each "+", empty pieces kept.
local function split_plus(s)
	local out, i = {}, 1
	while true do
		local j = find(s, "+", i, true)
		if not j then
			out[#out + 1] = sub(s, i)
			return out
		end
		out[#out + 1] = sub(s, i, j - 1)
		i = j + 1
	end
end

-- A key's name as its modifiers (a set) and its value, or nil when it does
-- not parse.
local function split_key(name)
	local head, value
	if #name > 2 and sub(name, -2) == "++" then
		head, value = sub(name, 1, -3), "+"
	elseif name == "+" then
		head, value = "", "+"
	else
		local i = find(name, "%+[^+]*$")
		if i then
			head, value = sub(name, 1, i - 1), sub(name, i + 1)
		else
			head, value = "", name
		end
	end
	local mods = {}
	if head ~= "" then
		for _, m in ipairs(split_plus(head)) do
			if not MODIFIER[m] or mods[m] then
				return nil
			end
			mods[m] = true
		end
	end
	if value == "Space" then
		value = " "
	end
	if not (is_char(value) or find(value, "^[A-Z][A-Za-z0-9]+$")) then
		return nil
	end
	return mods, value
end

-- The canonical name of a key: modifiers in order, Shift shown in a letter
-- where it can be, Space for a space. mods is a set; it is not changed.
local function key_name(mods, value)
	local shift = mods.Shift
	if shift and is_char(value) then
		local cp = code_point(value)
		if cp then
			local up, low = upper_cp(cp), lower_cp(cp)
			if up ~= cp then
				value, shift = utf8(up), false
			elseif low ~= cp then
				shift = false
			end
		end
	end
	local out = {}
	for _, m in ipairs(M.MODIFIERS) do
		if (m == "Shift" and shift) or (m ~= "Shift" and mods[m]) then
			out[#out + 1] = m
		end
	end
	out[#out + 1] = value == " " and "Space" or value
	return concat(out, "+")
end

--- A key's name in its canonical form (SDK.md §3.10), or nil when it does
--- not parse.
function M.parse_key(name)
	if type(name) ~= "string" then
		return nil
	end
	local mods, value = split_key(name)
	if not mods then
		return nil
	end
	return key_name(mods, value)
end

-- Decoding (SPEC §10.4) ------------------------------------------------------------

local C0 = {
	[0x00] = "Control+Space",
	[0x08] = "Control+h",
	[0x09] = "Tab",
	[0x0D] = "Enter",
	[0x1B] = "Escape",
	[0x7F] = "Backspace",
	[0x1C] = "Control+\\",
	[0x1D] = "Control+]",
	[0x1E] = "Control+^",
	[0x1F] = "Control+_",
}
local CSI_FINAL = { A = "ArrowUp", B = "ArrowDown", C = "ArrowRight", D = "ArrowLeft", H = "Home", F = "End" }
local TILDE = {
	[1] = "Home",
	[7] = "Home",
	[4] = "End",
	[8] = "End",
	[2] = "Insert",
	[3] = "Delete",
	[5] = "PageUp",
	[6] = "PageDown",
}
local CODES = { [9] = "Tab", [13] = "Enter", [27] = "Escape", [8] = "Backspace", [127] = "Backspace" }
-- The kitty keyboard protocol's codes from 57344 that name keys.
local KITTY = {
	[57409] = ".",
	[57410] = "/",
	[57411] = "*",
	[57412] = "-",
	[57413] = "+",
	[57414] = "Enter",
	[57415] = "=",
	[57417] = "ArrowLeft",
	[57418] = "ArrowRight",
	[57419] = "ArrowUp",
	[57420] = "ArrowDown",
	[57421] = "PageUp",
	[57422] = "PageDown",
	[57423] = "Home",
	[57424] = "End",
	[57425] = "Insert",
	[57426] = "Delete",
	[57441] = "Shift",
	[57442] = "Control",
	[57443] = "Alt",
	[57444] = "Meta",
	[57447] = "Shift",
	[57448] = "Control",
	[57449] = "Alt",
	[57450] = "Meta",
}
for i = 0, 9 do
	KITTY[57399 + i] = tostring(i)
end

-- Whether bit b (a power of two) is set in n. gopher-lua has no bit library.
local function has(n, b)
	return floor(n / b) % 2 == 1
end

-- A number of decimal digits, or nil.
local function number(s)
	if not find(s, "^%d+$") then
		return nil
	end
	return tonumber(s)
end

-- The modifiers (a set) in a CSI parameter "m[:e]", and whether it is a
-- release; nil when it does not parse.
local function csi_mods(field)
	local m_s, e_s = field:match("^([^:]*):?([^:]*)")
	local m = m_s == "" and 1 or number(m_s)
	local e = e_s == "" and 1 or number(e_s)
	if not m or not e then
		return nil
	end
	local bits = m - 1
	local mods = {}
	if bits < 0 then
		return mods, e == 3
	end
	if has(bits, 1) then
		mods.Shift = true
	end
	if has(bits, 2) then
		mods.Alt = true
	end
	if has(bits, 4) then
		mods.Control = true
	end
	if has(bits, 8) or has(bits, 32) then
		mods.Meta = true
	end
	return mods, e == 3
end

-- The character of a code point, or nil for a control or no code point.
local function code_char(cp)
	if not cp or cp < 0x20 or cp == 0x7F or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
		return nil
	end
	return utf8(cp)
end

-- The key a kitty or modifyOtherKeys code names.
local function code_key(code, mods, shifted, text)
	if CODES[code] then
		return key_name(mods, CODES[code])
	end
	if code >= 57344 then
		return KITTY[code] and key_name(mods, KITTY[code]) or nil
	end
	local base = code_char(code)
	if not base then
		return nil
	end
	local value = base
	local shift = mods.Shift
	if shift then
		if shifted and shifted ~= 0 and code_char(shifted) then
			value = code_char(shifted)
		elseif text and text ~= "" then
			value = text
		else
			value = utf8(upper_cp(code))
		end
		if value ~= base then
			shift = false
		end
	end
	local out = {}
	for _, m in ipairs(M.MODIFIERS) do
		if (m == "Shift" and shift) or (m ~= "Shift" and mods[m]) then
			out[#out + 1] = m
		end
	end
	out[#out + 1] = value == " " and "Space" or value
	return concat(out, "+")
end

-- s split at each ";", empty pieces kept.
local function split_semi(s)
	local out, i = {}, 1
	while true do
		local j = find(s, ";", i, true)
		if not j then
			out[#out + 1] = sub(s, i)
			return out
		end
		out[#out + 1] = sub(s, i, j - 1)
		i = j + 1
	end
end

-- The key a CSI sequence names, or nil.
local function csi(params, final)
	local first = sub(params, 1, 1)
	if first == "<" or first == "=" or first == ">" or first == "?" then
		return nil
	end
	local fields = split_semi(params)
	if final == "u" then
		local codes = {}
		for c in gmatch(fields[1] .. ":", "([^:]*):") do
			codes[#codes + 1] = c == "" and 0 or number(c)
			if not codes[#codes] then
				return nil
			end
		end
		local mods, release = {}, false
		if fields[2] then
			mods, release = csi_mods(fields[2])
		end
		if not mods or release then
			return nil
		end
		local text
		if fields[3] then
			local t = {}
			for c in gmatch(fields[3], "[^:]+") do
				local cp = number(c)
				if not cp or cp > 0x10FFFF then
					return nil
				end
				t[#t + 1] = utf8(cp)
			end
			text = concat(t)
		end
		return code_key(codes[1], mods, codes[2], text)
	elseif final == "~" then
		local n = fields[1] == "" and 0 or number(fields[1])
		if not n then
			return nil
		end
		if n == 27 and #fields >= 3 then
			local mods, release = csi_mods(fields[2])
			local code = number(fields[3])
			if not mods or release or not code then
				return nil
			end
			return code_key(code, mods)
		end
		if not TILDE[n] then
			return nil
		end
		local mods, release = {}, false
		if fields[2] then
			mods, release = csi_mods(fields[2])
		end
		if not mods or release then
			return nil
		end
		return key_name(mods, TILDE[n])
	elseif CSI_FINAL[final] then
		local mods, release = {}, false
		if fields[2] then
			mods, release = csi_mods(fields[2])
		end
		if not mods or release then
			return nil
		end
		return key_name(mods, CSI_FINAL[final])
	elseif final == "Z" then
		return "Shift+Tab"
	end
	return nil
end

-- The key of a control byte or a character at data[i], and its length.
local function one(data, i)
	local b = byte(data, i)
	if b < 0x20 or b == 0x7F then
		return C0[b] or ("Control+" .. char(b + 0x60)), 1
	end
	local n = utf8_len(data, i)
	if not n then
		return nil, 1
	end
	local c = sub(data, i, i + n - 1)
	return c == " " and "Space" or c, n
end

-- A key's name with Alt.
local function with_alt(name)
	if not name then
		return nil
	end
	local mods, value = split_key(name)
	mods.Alt = true
	return key_name(mods, value)
end

--- The keys in input from the terminal (SDK.md §3.10, SPEC §10.4): a list
--- with the canonical name of each key, and false for input that is no key
--- (nil would end the list).
function M.decode_keys(data)
	local out, k, i, n = {}, 0, 1, #data
	local function put(key)
		k = k + 1
		out[k] = key or false
	end
	while i <= n do
		if byte(data, i) ~= 0x1B then
			local key, len = one(data, i)
			put(key)
			i = i + len
		elseif i == n then
			put("Escape")
			i = i + 1
		else
			local nxt = byte(data, i + 1)
			if (nxt == 0x5B or nxt == 0x4F) and i + 2 <= n then
				if nxt == 0x4F then
					put(CSI_FINAL[sub(data, i + 2, i + 2)])
					i = i + 3
				else
					local j = i + 2
					while j <= n and byte(data, j) >= 0x30 and byte(data, j) <= 0x3F do
						j = j + 1
					end
					local params = sub(data, i + 2, j - 1)
					while j <= n and byte(data, j) >= 0x20 and byte(data, j) <= 0x2F do
						j = j + 1
					end
					if j > n then
						put(nil)
						break
					end
					put(byte(data, j) >= 0x40 and csi(params, sub(data, j, j)) or nil)
					i = j + 1
				end
			else
				local key, len = one(data, i + 1)
				put(with_alt(key))
				i = i + 1 + len
			end
		end
	end
	return out
end

-- Keymaps (SPEC §10.2) ------------------------------------------------------------

local Keymap = {}
Keymap.__index = Keymap

--- An empty keymap; multiline says which field it is for, when resolved.
function M.keymap(multiline)
	return setmetatable({ keys = {}, actions = {}, multiline = multiline and true or false }, Keymap)
end

--- Binds a key (a canonical name) to an action. A key bound again keeps
--- its place.
function Keymap:bind(key, action)
	if not self.actions[key] then
		self.keys[#self.keys + 1] = key
	end
	self.actions[key] = action
end

--- Binds what other binds, over what this one binds.
function Keymap:update(other)
	for _, key in ipairs(other.keys) do
		self:bind(key, other.actions[key])
	end
end

--- The keymap as a data-keys value.
function Keymap:format()
	local out = {}
	for i, key in ipairs(self.keys) do
		out[i] = key .. "=" .. self.actions[key]
	end
	return concat(out, " ")
end

local FOCUS = { Tab = true, ["Shift+Tab"] = true, Escape = true }

-- The action bound to a canonical key, or, for a key with Shift that is
-- not bound, to the key without Shift; and the key's modifiers and value.
function Keymap:bound(k)
	local mods, value = split_key(k)
	local a = self.actions[k]
	if not a and mods.Shift then
		local rest = {}
		for m in pairs(mods) do
			rest[m] = m ~= "Shift" or nil
		end
		a = self.actions[key_name(rest, value)]
	end
	return a, mods, value
end

--- What the field does with a key: an action, INSERT for a character it
--- types, or nil when the key is not the field's.
function Keymap:lookup(key)
	local k = M.parse_key(key)
	if not k or FOCUS[k] then
		return nil
	end
	local a, mods, value = self:bound(k)
	if a then
		if a == "program" or (M.MULTILINE_ACTIONS[a] and not self.multiline) then
			return nil
		end
		return a
	end
	if is_char(value) and not (mods.Control or mods.Alt or mods.Meta) then
		return M.INSERT
	end
	return nil
end

--- Whether the keymap gives a key to the program (SDK.md §3.10): it binds
--- the key to program, or, for a key with Shift it does not bind, the key
--- without Shift. On an element that is not a text field, a host asks it of
--- the element's keymap, parse_keymap of its data-keys values joined with a
--- space, the root's first, with no default keymap; a key it gives reaches
--- the program before the element or a scroll uses it (SPEC §10.2, keys for
--- the program).
function Keymap:program(key)
	local k = M.parse_key(key)
	return k ~= nil and self:bound(k) == "program"
end

--- A data-keys value's bindings, without those a host ignores. They are
--- split on ASCII white space only: space, tab, LF, FF and CR (SPEC §10.2),
--- not %s, which also takes VT.
function M.parse_keymap(value)
	local m = M.keymap()
	for b in gmatch(value or "", "[^ \t\n\f\r]+") do
		local i = find(b, "=[^=]*$")
		if i then
			local key, action = M.parse_key(sub(b, 1, i - 1)), sub(b, i + 1)
			if key and ACTION[action] and not FOCUS[key] then
				m:bind(key, action)
			end
		end
	end
	return m
end

--- A field's keymap: SPEC §10.2's default, then each data-keys value, the
--- root's first.
function M.resolve(multiline, ...)
	local m = M.keymap(multiline)
	m:bind("ArrowLeft", "char-backward")
	m:bind("ArrowRight", "char-forward")
	m:bind("Home", "line-start")
	m:bind("End", "line-end")
	m:bind("Backspace", "delete-char-backward")
	m:bind("Delete", "delete-char-forward")
	m:bind("ArrowUp", "line-previous")
	m:bind("ArrowDown", "line-next")
	m:bind("PageUp", "page-up")
	m:bind("PageDown", "page-down")
	m:bind("Enter", multiline and "newline" or "submit")
	for i = 1, select("#", ...) do
		m:update(M.parse_keymap(select(i, ...)))
	end
	return m
end

return M
