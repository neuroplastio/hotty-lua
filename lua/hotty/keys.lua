--- What a text field does with a key (SDK.md §3.10; SPEC §10.2, §10.4): key
--- names, the keys in the terminal's input, keymaps, and the SDK's keymap. It
--- is part of the wire layer, and hotty has it all: hotty.parse_key,
--- hotty.decode_keys, hotty.key_text, hotty.parse_keymap, hotty.resolve,
--- hotty.TERMINAL_KEYS.
---
--- Keys are named as myelin key names 0.1 names them (SPEC §10.4).
---
--- Characters are code points, CR LF one: Lua has no grapheme segmentation
--- (SDK.md §4.6). A letter's case is the simple mapping of the code points
--- below (case_map): ASCII, Latin-1, Latin Extended, Greek, Cyrillic,
--- Armenian, Latin Extended Additional and the full-width Latin letters.
local u8 = require("hotty.utf8")

local byte, char, sub, find, gmatch = string.byte, string.char, string.sub, string.find, string.gmatch
local floor = math.floor
local concat = table.concat
local utf8_len, utf8 = u8.len, u8.char

local M = {}

M.MODIFIERS = { "super", "ctrl", "alt", "shift" }

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
	"select-all",
	"newline",
	"submit",
	"program",
	"prefix",
	"copy",
	"cut",
	"paste",
	"undo",
	"redo",
	"scroll-up",
	"scroll-down",
	"scroll-left",
	"scroll-right",
	"scroll-page-up",
	"scroll-page-down",
	"scroll-half-page-up",
	"scroll-half-page-down",
	"scroll-start",
	"scroll-end",
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
	["newline"] = true,
}

-- The moves, which select with Shift (SPEC §10.2).
M.MOVES = {
	["char-backward"] = true,
	["char-forward"] = true,
	["word-backward"] = true,
	["word-forward"] = true,
	["line-start"] = true,
	["line-end"] = true,
	["line-previous"] = true,
	["line-next"] = true,
	["page-up"] = true,
	["page-down"] = true,
	["input-start"] = true,
	["input-end"] = true,
}

-- The scroll actions (SPEC §10.2, scrolling keys), which a text field's
-- keymap leaves out.
M.SCROLL_ACTIONS = {}
for _, a in ipairs(M.ACTIONS) do
	if sub(a, 1, 7) == "scroll-" then
		M.SCROLL_ACTIONS[a] = true
	end
end

-- What lookup returns for a character the field types.
M.INSERT = "insert"

-- The SDK's keymap (SDK.md §3.10): Bubble Tea's text input and text area,
-- but mod+a selects all, as in a GUI field: ctrl+a on Linux, while on
-- macOS ctrl+a stays the line's start.
M.TERMINAL_KEYS = concat({
	"arrow_left=char-backward ctrl+b=char-backward arrow_right=char-forward ctrl+f=char-forward",
	"alt+arrow_left=word-backward ctrl+arrow_left=word-backward alt+b=word-backward",
	"alt+arrow_right=word-forward ctrl+arrow_right=word-forward alt+f=word-forward",
	"home=line-start end=line-end ctrl+e=line-end",
	"backspace=delete-char-backward ctrl+h=delete-char-backward",
	"delete=delete-char-forward ctrl+d=delete-char-forward",
	"alt+backspace=delete-word-backward ctrl+w=delete-word-backward ctrl+backspace=delete-word-backward",
	"alt+delete=delete-word-forward alt+d=delete-word-forward ctrl+delete=delete-word-forward",
	"ctrl+u=delete-to-line-start ctrl+k=delete-to-line-end",
	"arrow_up=line-previous ctrl+p=line-previous arrow_down=line-next ctrl+n=line-next",
	"page_up=page-up page_down=page-down",
	"alt+<=input-start ctrl+home=input-start alt+>=input-end ctrl+end=input-end",
	"mod+a=select-all",
	"ctrl+m=newline",
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

-- Whether v is one character (myelin key names §2.4): its first code point
-- neither a space nor a control (category Cc).
local function is_char(v)
	local cs = M.chars(v)
	if #cs ~= 1 or not utf8_len(v, 1) then
		return false
	end
	local cp = code_point(v)
	return cp ~= nil and cp > 0x20 and not (cp >= 0x7F and cp <= 0x9F)
end

-- The simple lowercase mapping of a code point (UnicodeData.txt), for the
-- scripts in the header. The Lua runtimes differ in what string.lower does
-- beyond ASCII (gopher-lua's is Go's), so none is used.
local function lower_cp(cp)
	if cp < 0x80 then
		return (cp >= 0x41 and cp <= 0x5A) and cp + 0x20 or cp
	elseif cp < 0x100 then
		return (cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7) and cp + 0x20 or cp
	elseif cp < 0x180 then
		if cp == 0x130 then
			return 0x69
		elseif cp == 0x178 then
			return 0xFF
		elseif (cp >= 0x100 and cp <= 0x137) or (cp >= 0x14A and cp <= 0x177) then
			return cp % 2 == 0 and cp + 1 or cp
		elseif (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then
			return cp % 2 == 1 and cp + 1 or cp
		end
		return cp
	elseif cp < 0x250 then
		if cp == 0x1C4 or cp == 0x1C5 then
			return 0x1C6
		elseif cp == 0x1C7 or cp == 0x1C8 then
			return 0x1C9
		elseif cp == 0x1CA or cp == 0x1CB then
			return 0x1CC
		elseif cp == 0x1F1 or cp == 0x1F2 then
			return 0x1F3
		elseif cp >= 0x1CD and cp <= 0x1DC then
			return cp % 2 == 1 and cp + 1 or cp
		end
		return cp
	elseif cp >= 0x370 and cp < 0x400 then
		if cp == 0x386 then
			return 0x3AC
		elseif cp >= 0x388 and cp <= 0x38A then
			return cp + 0x25
		elseif cp == 0x38C then
			return 0x3CC
		elseif cp == 0x38E or cp == 0x38F then
			return cp + 0x3F
		elseif (cp >= 0x391 and cp <= 0x3A1) or (cp >= 0x3A3 and cp <= 0x3AB) then
			return cp + 0x20
		end
		return cp
	elseif cp >= 0x400 and cp < 0x530 then
		if cp <= 0x40F then
			return cp + 0x50
		elseif cp <= 0x42F then
			return cp + 0x20
		elseif (cp >= 0x460 and cp <= 0x481) or (cp >= 0x48A and cp <= 0x4BF) or (cp >= 0x4D0 and cp <= 0x52F) then
			return cp % 2 == 0 and cp + 1 or cp
		elseif cp == 0x4C0 then
			return 0x4CF
		elseif cp >= 0x4C1 and cp <= 0x4CE then
			return cp % 2 == 1 and cp + 1 or cp
		end
		return cp
	elseif cp >= 0x531 and cp <= 0x556 then
		return cp + 0x30
	elseif (cp >= 0x1E00 and cp <= 0x1E95) or (cp >= 0x1EA0 and cp <= 0x1EFF) then
		return cp % 2 == 0 and cp + 1 or cp
	elseif cp >= 0xFF21 and cp <= 0xFF3A then
		return cp + 0x20
	end
	return cp
end

-- The simple uppercase mapping: the inverse of lower_cp for the first
-- code point that maps to a letter (Ǆ, not ǅ, is ǆ's), and the few small
-- letters that no capital maps to.
local UPPER = { [0xB5] = 0x39C, [0x131] = 0x49, [0x17F] = 0x53, [0x3C2] = 0x3A3 }
for _, r in ipairs({ { 0x41, 0x590 }, { 0x1E00, 0x1EFF }, { 0xFF21, 0xFF3A } }) do
	for cp = r[1], r[2] do
		local lo = lower_cp(cp)
		if lo ~= cp and not UPPER[lo] then
			UPPER[lo] = cp
		end
	end
end

local function upper_cp(cp)
	return UPPER[cp] or cp
end

-- The simple lowercase and uppercase of a one-character string.
local function lower(c)
	local cp = code_point(c)
	return cp and utf8(lower_cp(cp)) or c
end

local function upper(c)
	local cp = code_point(c)
	return cp and utf8(upper_cp(cp)) or c
end

-- Whether c is a capital (myelin key names §4.3): its lowercase differs
-- and the uppercase of that is c again. A title-case letter is none.
local function is_capital(c)
	local l = lower(c)
	return l ~= c and upper(l) == c
end

-- A letter is a character with case (§2.6): its uppercase differs.
local function is_letter(c)
	return upper(c) ~= c or is_capital(c)
end

-- Key names (SPEC §10.4) ----------------------------------------------------------

local function set(list)
	local s = {}
	for _, v in ipairs(list) do
		s[v] = true
	end
	return s
end

local MODSET = set(M.MODIFIERS)
-- The modifiers' names and aliases, as the default reading takes them
-- (myelin key names §4.1).
local MOD_NAMES = {
	super = "super",
	cmd = "super",
	command = "super",
	ctrl = "ctrl",
	control = "ctrl",
	alt = "alt",
	opt = "alt",
	option = "alt",
	shift = "shift",
}
-- The modifiers in the order a name writes them; a binding's mod comes
-- first where it keeps it.
local ORDER = { "mod", "super", "ctrl", "alt", "shift" }

-- The physical keys (myelin key names, Appendix A).
local PHYSICAL = set({
	"backquote",
	"backslash",
	"bracket_left",
	"bracket_right",
	"comma",
	"digit_0",
	"digit_1",
	"digit_2",
	"digit_3",
	"digit_4",
	"digit_5",
	"digit_6",
	"digit_7",
	"digit_8",
	"digit_9",
	"equal",
	"intl_backslash",
	"intl_ro",
	"intl_yen",
	"key_a",
	"key_b",
	"key_c",
	"key_d",
	"key_e",
	"key_f",
	"key_g",
	"key_h",
	"key_i",
	"key_j",
	"key_k",
	"key_l",
	"key_m",
	"key_n",
	"key_o",
	"key_p",
	"key_q",
	"key_r",
	"key_s",
	"key_t",
	"key_u",
	"key_v",
	"key_w",
	"key_x",
	"key_y",
	"key_z",
	"minus",
	"period",
	"quote",
	"semicolon",
	"slash",
	"alt_left",
	"alt_right",
	"backspace",
	"caps_lock",
	"context_menu",
	"control_left",
	"control_right",
	"enter",
	"meta_left",
	"meta_right",
	"shift_left",
	"shift_right",
	"space",
	"tab",
	"convert",
	"kana_mode",
	"non_convert",
	"delete",
	"end",
	"help",
	"home",
	"insert",
	"page_down",
	"page_up",
	"arrow_down",
	"arrow_left",
	"arrow_right",
	"arrow_up",
	"num_lock",
	"numpad_0",
	"numpad_1",
	"numpad_2",
	"numpad_3",
	"numpad_4",
	"numpad_5",
	"numpad_6",
	"numpad_7",
	"numpad_8",
	"numpad_9",
	"numpad_add",
	"numpad_backspace",
	"numpad_clear",
	"numpad_clear_entry",
	"numpad_comma",
	"numpad_decimal",
	"numpad_divide",
	"numpad_enter",
	"numpad_equal",
	"numpad_memory_add",
	"numpad_memory_clear",
	"numpad_memory_recall",
	"numpad_memory_store",
	"numpad_memory_subtract",
	"numpad_multiply",
	"numpad_paren_left",
	"numpad_paren_right",
	"numpad_subtract",
	"numpad_separator",
	"numpad_up",
	"numpad_down",
	"numpad_right",
	"numpad_left",
	"numpad_begin",
	"numpad_home",
	"numpad_end",
	"numpad_insert",
	"numpad_delete",
	"numpad_page_up",
	"numpad_page_down",
	"escape",
	"f1",
	"f2",
	"f3",
	"f4",
	"f5",
	"f6",
	"f7",
	"f8",
	"f9",
	"f10",
	"f11",
	"f12",
	"f13",
	"f14",
	"f15",
	"f16",
	"f17",
	"f18",
	"f19",
	"f20",
	"f21",
	"f22",
	"f23",
	"f24",
	"f25",
	"fn",
	"fn_lock",
	"print_screen",
	"scroll_lock",
	"pause",
	"browser_back",
	"browser_favorites",
	"browser_forward",
	"browser_home",
	"browser_refresh",
	"browser_search",
	"browser_stop",
	"eject",
	"launch_app_1",
	"launch_app_2",
	"launch_mail",
	"media_play_pause",
	"media_select",
	"media_stop",
	"media_track_next",
	"media_track_previous",
	"power",
	"sleep",
	"audio_volume_down",
	"audio_volume_mute",
	"audio_volume_up",
	"wake_up",
	"copy",
	"cut",
	"paste",
})
-- Other keymaps' names for physical keys, which the default reading takes.
local OTHER = {
	up = "arrow_up",
	down = "arrow_down",
	left = "arrow_left",
	right = "arrow_right",
	pageup = "page_up",
	pagedown = "page_down",
	pgup = "page_up",
	pgdn = "page_down",
	esc = "escape",
}

-- A physical key as the default reading takes it (§4.1), or nil: its name
-- in any case, another name above, or a W3C code value (`PageDown`), which
-- starts a word at each capital letter or digit after the first character.
local function physical(part)
	local low = part:lower()
	if PHYSICAL[low] then
		return low
	elseif OTHER[low] then
		return OTHER[low]
	elseif not find(part, "^[A-Za-z0-9]+$") then
		return nil
	end
	local n = part:sub(1, 1):lower() .. part:sub(2):gsub("[A-Z0-9]", function(c)
		return "_" .. c:lower()
	end)
	return PHYSICAL[n] and n or nil
end

-- The name of a key with these modifiers (a set, mod among them where it
-- is kept) and this value.
local function join(mods, value)
	local out = {}
	for _, m in ipairs(ORDER) do
		if mods[m] then
			out[#out + 1] = m
		end
	end
	out[#out + 1] = value
	return concat(out, "+")
end

-- A canonical key taken apart (myelin key names §2.1): its modifiers (a
-- set), its value, and its kind: "character", "physical" or "modifier".
local function split(k)
	local mods, i = {}, 1
	while true do
		local j = find(k, "+", i, true)
		local m = j and sub(k, i, j - 1)
		if not (m and MODSET[m]) then
			break
		end
		mods[m] = true
		i = j + 1
	end
	local value = sub(k, i)
	return mods, value, PHYSICAL[value] and "physical" or MODSET[value] and "modifier" or "character"
end

-- The default reading of a key's name (myelin key names §4.1), with `mod`
-- standing for the modifier it is given (§4.4), or refused when that is nil.
-- With keep, a key written with mod keeps it, first. nil when the reading
-- refuses the name.
local function read(text, mod, keep)
	if type(text) ~= "string" or text == "" or find(text, "^<[A-Za-z0-9_%-]+>$") then
		return nil
	end
	local parts, i, n = {}, 1, #text
	while true do
		local j = find(text, "+", i, true)
		if not j then
			parts[#parts + 1] = sub(text, i)
			break
		end
		parts[#parts + 1] = sub(text, i, j - 1)
		i = j + 1
		if i > n then
			if parts[#parts] ~= "" then
				return nil -- ctrl+, a+
			end
			break
		end
	end
	local mods, order, value, written, named = {}, {}, nil, {}, {}
	for _, p in ipairs(parts) do
		local low = p:lower()
		local m = MOD_NAMES[low]
		if low == "meta" then
			return nil
		elseif low == "mod" then
			-- mod with super or ctrl, whichever it stands for, is refused
			-- (SPEC §10.4), and mod twice, as any modifier is.
			if not mod or named.mod or named.super or named.ctrl then
				return nil
			end
			named.mod, m = true, mod
			written[m] = true
		elseif m then
			if (m == "super" or m == "ctrl") and named.mod then
				return nil
			end
			named[m] = true
		end
		if m then
			if mods[m] then
				return nil
			end
			mods[m] = true
			order[#order + 1] = m
		else
			if value then
				return nil
			elseif p == "" then
				value = "+"
			elseif is_char(p) then
				value = lower(p)
			else
				value = physical(p)
				if not value then
					return nil
				end
			end
		end
	end
	if not value then
		if #order == 0 then
			return nil
		end
		value = order[#order]
		mods[value], written[value] = nil, nil
	end
	if keep and next(written) then
		for m in pairs(written) do
			mods[m] = nil
		end
		mods.mod = true
	end
	return join(mods, value)
end

--- A key's name read with myelin key names' default reading (SPEC §10.4,
--- SDK.md §3.10), in its canonical form, or nil where the reading refuses
--- it: mod too, which only a platform reads (read_key).
function M.parse_key(name)
	return read(name, nil, false)
end

-- The platform's mod: "ctrl", or "super" (SPEC §4).
local function mod_of(platform)
	return platform and platform.mod == "super" and "super" or "ctrl"
end

--- A key's name read as parse_key does, with mod standing for the platform's
--- (myelin key names §4.4): platform is {mod, edit}, or nil for ctrl. nil
--- for a name the reading refuses. A menu's items (their key, menu_level_of)
--- compare with the keys typed this way.
function M.read_key(platform, name)
	return read(name, mod_of(platform), false)
end

--- The text a key types in a field (SDK.md §3.10, SPEC §10.2): a
--- character's, a letter with shift as its capital, a space for space, and
--- nil for any other key or a key with ctrl, alt or super.
function M.key_text(key)
	local k = M.parse_key(key)
	if not k then
		return nil
	end
	local mods, value, kind = split(k)
	if mods.super or mods.ctrl or mods.alt then
		return nil
	elseif value == "space" then
		return " "
	elseif kind ~= "character" then
		return nil
	end
	return mods.shift and is_letter(value) and upper(value) or value
end

-- Decoding (SPEC §10.4) ------------------------------------------------------------

-- The key of a character (a capital is shift with its letter), and its
-- modifiers.
local function char_key(c, mods)
	mods = mods or {}
	if c == " " then
		return join(mods, "space")
	elseif is_capital(c) then
		local m = { shift = true }
		for x in pairs(mods) do
			m[x] = true
		end
		return join(m, lower(c))
	end
	return join(mods, c)
end

local C0 = {
	[0x00] = "ctrl+space",
	[0x08] = "ctrl+h",
	[0x09] = "tab",
	[0x0D] = "enter",
	[0x1B] = "escape",
	[0x7F] = "backspace",
	[0x1C] = "ctrl+\\",
	[0x1D] = "ctrl+]",
	[0x1E] = "ctrl+^",
	[0x1F] = "ctrl+_",
}
local CSI_FINAL = { A = "arrow_up", B = "arrow_down", C = "arrow_right", D = "arrow_left", H = "home", F = "end" }
local TILDE = {
	[1] = "home",
	[7] = "home",
	[4] = "end",
	[8] = "end",
	[2] = "insert",
	[3] = "delete",
	[5] = "page_up",
	[6] = "page_down",
}
local CODES = { [9] = "tab", [13] = "enter", [27] = "escape", [8] = "backspace", [127] = "backspace", [32] = "space" }
-- The kitty keyboard protocol's keypad codes, as a legacy terminal sends
-- the keys (SPEC §10.4); its other codes from 57344 name no key.
local KITTY = {
	[57409] = ".",
	[57410] = "/",
	[57411] = "*",
	[57412] = "-",
	[57413] = "+",
	[57414] = "enter",
	[57415] = "=",
	[57417] = "arrow_left",
	[57418] = "arrow_right",
	[57419] = "arrow_up",
	[57420] = "arrow_down",
	[57421] = "page_up",
	[57422] = "page_down",
	[57423] = "home",
	[57424] = "end",
	[57425] = "insert",
	[57426] = "delete",
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
		mods.shift = true
	end
	if has(bits, 2) then
		mods.alt = true
	end
	if has(bits, 4) then
		mods.ctrl = true
	end
	if has(bits, 8) or has(bits, 32) then
		mods.super = true
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

-- The key a kitty or modifyOtherKeys code names: a letter with shift is
-- shift and the letter; another character with shift is the shifted key
-- when given, else the text when given (SPEC §10.4).
local function code_key(code, mods, shifted, text)
	if CODES[code] then
		return join(mods, CODES[code])
	elseif code >= 57344 then
		return KITTY[code] and join(mods, KITTY[code]) or nil
	end
	local c = code_char(code)
	if not c then
		return nil
	elseif is_letter(c) then
		return join(mods, lower(c))
	elseif mods.shift then
		local rest = {}
		for m in pairs(mods) do
			rest[m] = m ~= "shift" or nil
		end
		if shifted and shifted ~= 0 and code_char(shifted) then
			return char_key(code_char(shifted), rest)
		elseif text and text ~= "" then
			return char_key(text, rest)
		end
	end
	return join(mods, c)
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
		return join(mods, TILDE[n])
	elseif CSI_FINAL[final] then
		local mods, release = {}, false
		if fields[2] then
			mods, release = csi_mods(fields[2])
		end
		if not mods or release then
			return nil
		end
		return join(mods, CSI_FINAL[final])
	elseif final == "Z" then
		return "shift+tab"
	end
	return nil
end

-- The key of a control byte or a character at data[i], and its length.
local function one(data, i)
	local b = byte(data, i)
	if b < 0x20 or b == 0x7F then
		return C0[b] or ("ctrl+" .. char(b + 0x60)), 1
	end
	local n = utf8_len(data, i)
	if not n then
		return nil, 1
	end
	return char_key(sub(data, i, i + n - 1)), n
end

-- A key's name with alt.
local function with_alt(name)
	if not name then
		return nil
	end
	local mods, value = split(name)
	mods.alt = true
	return join(mods, value)
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
			put("escape")
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

--- An empty keymap; multiline says which field it is for, when resolved,
--- and platform ({mod, edit}, or nil) what mod reads as: ctrl, or super.
function M.keymap(multiline, platform)
	return setmetatable({
		keys = {},
		actions = {},
		written = {},
		multiline = multiline and true or false,
		mod = mod_of(platform),
	}, Keymap)
end

--- Binds a key (canonical, mod read) to an action. A key bound again keeps
--- its place; written is the key as the binding wrote it, with mod where it
--- had it (parse_key's name when absent).
function Keymap:bind(key, action, written)
	if not self.actions[key] then
		self.keys[#self.keys + 1] = key
	end
	self.actions[key] = action
	self.written[key] = written or key
end

--- Binds what other binds, over what this one binds.
function Keymap:update(other)
	for _, key in ipairs(other.keys) do
		self:bind(key, other.actions[key], other.written[key])
	end
end

--- The keymap as a data-keys value: each key once, where it was first
--- bound, as its last binding wrote it (a key written with mod keeps it,
--- first), with its last action.
function Keymap:format()
	local out = {}
	for i, key in ipairs(self.keys) do
		out[i] = self.written[key] .. "=" .. self.actions[key]
	end
	return concat(out, " ")
end

local FOCUS = { tab = true, ["shift+tab"] = true, escape = true }

-- The action bound to a canonical key, or, for a key with shift that is
-- not a character and is not bound, to the key without shift.
function Keymap:bound(k)
	local a = self.actions[k]
	if not a then
		local mods, value, kind = split(k)
		if mods.shift and kind ~= "character" then
			mods.shift = nil
			a = self.actions[join(mods, value)]
		end
	end
	return a
end

--- Whether the keymap binds a key (SDK.md §3.10), or, for a key with shift
--- that is not a character and that it does not bind, the key without
--- shift (SPEC §10.2). A host that has two names for a press (SPEC §10.4)
--- asks it of the physical one first, and of the other one where the
--- keymap does not bind it.
function Keymap:binds(key)
	local k = M.parse_key(key)
	return k ~= nil and self:bound(k) ~= nil
end

--- What the field does with a key: an action, INSERT for a character it
--- types (key_text), or nil when the key is not the field's.
function Keymap:lookup(key)
	local k = M.parse_key(key)
	if not k or FOCUS[k] then
		return nil
	end
	local a = self:bound(k)
	if a then
		if a == "program" or a == "prefix" or (M.MULTILINE_ACTIONS[a] and not self.multiline) then
			return nil
		end
		return a
	end
	return M.key_text(k) ~= nil and M.INSERT or nil
end

--- Whether the field selects with a key (SDK.md §3.10, SPEC §10.2, Shift
--- selects): lookup returns a move for it, and its canonical name has
--- shift (shift+arrow_left, ctrl+shift+end, not alt+<). The field then
--- does the move with extend.
function Keymap:selects(key)
	local k = M.parse_key(key)
	if not k then
		return false
	end
	local a = self:lookup(k)
	return a ~= nil and M.MOVES[a] == true and split(k).shift == true
end

--- Whether the keymap gives a key to the program (SDK.md §3.10): it binds
--- the key to program or prefix, or, for a key with shift that is not a
--- character and that it does not bind, the key without shift. On an
--- element that is not a text field, a host asks it of the element's
--- keymap, parse_keymap of its data-keys values joined with a space, the
--- root's first, with no default keymap; a key it gives reaches the program
--- before the element or a scroll uses it (SPEC §10.2, keys for the
--- program).
function Keymap:program(key)
	local k = M.parse_key(key)
	local a = k and self:bound(k)
	return a == "program" or a == "prefix"
end

--- Whether the keymap binds a key to prefix, with the same fallback without
--- shift as program (SDK.md §3.10). A host asks it of a key program gives the
--- program, and from then on gives the program every key, tab, shift+tab and
--- escape too, until the program sends a=focus or a=blur, the surface loses
--- the keyboard, or the user focuses an element of it with a press (SPEC
--- §10.5).
function Keymap:prefix(key)
	local k = M.parse_key(key)
	return k ~= nil and self:bound(k) == "prefix"
end

--- The scroll action the keymap binds a key to, with the same fallback
--- without shift as program, or nil (SDK.md §3.10). A host asks it of the
--- keymap it asks program of, for a key the element does not use (SPEC
--- §10.2, scrolling keys).
function Keymap:scroll(key)
	local k = M.parse_key(key)
	local a = k and self:bound(k)
	return M.SCROLL_ACTIONS[a] and a or nil
end

-- Calls fn(key, action, written) for each of a data-keys value's bindings,
-- in order, without those a host ignores: the key read on the platform, and
-- as written with mod. They are split on ASCII white space only: space,
-- tab, LF, FF and CR (SPEC §10.2), not %s, which also takes VT.
local function each_binding(platform, value, fn)
	local mod = mod_of(platform)
	for b in gmatch(value or "", "[^ \t\n\f\r]+") do
		local i = find(b, "=[^=]*$")
		if i then
			local text, action = sub(b, 1, i - 1), sub(b, i + 1)
			local key = read(text, mod, false)
			if key and ACTION[action] and not FOCUS[key] then
				fn(key, action, read(text, mod, true))
			end
		end
	end
end

--- A data-keys value's bindings, without those a host ignores, each key
--- read on the platform ({mod, edit}, or nil for ctrl).
function M.parse_keymap(platform, value)
	local m = M.keymap(false, platform)
	each_binding(platform, value, function(key, action, written)
		m:bind(key, action, written)
	end)
	return m
end

-- The edit actions, in SPEC §10.2's order.
local EDIT_ACTIONS = { "select-all", "copy", "cut", "paste", "undo", "redo" }

--- The default edit shortcuts for a mod, "ctrl" (the default) or "super"
--- (SPEC §10.2): each action to its keys, read.
function M.default_edit(mod)
	local m = mod == "super" and "super" or "ctrl"
	local e = {
		["select-all"] = { m .. "+a" },
		copy = { m .. "+c" },
		cut = { m .. "+x" },
		paste = { m .. "+v" },
		undo = { m .. "+z" },
		redo = { m .. "+shift+z" },
	}
	if m == "ctrl" then
		e.redo[2] = "ctrl+y"
	end
	return e
end

--- The platform of a host's capabilities (SDK.md §3.10): {mod, edit}, each
--- the default where it reports none: mod "ctrl", edit nil, which is
--- default_edit(mod).
function M.platform_of(caps)
	return { mod = mod_of(caps), edit = caps and caps.edit or nil }
end

-- The default keymap (SPEC §10.2): every host's keys, then those of its mod.
local DEFAULT_KEYS = {
	{ "arrow_left", "char-backward" },
	{ "arrow_right", "char-forward" },
	{ "alt+arrow_left", "word-backward" },
	{ "alt+arrow_right", "word-forward" },
	{ "home", "line-start" },
	{ "end", "line-end" },
	{ "backspace", "delete-char-backward" },
	{ "delete", "delete-char-forward" },
	{ "alt+backspace", "delete-word-backward" },
	{ "alt+delete", "delete-word-forward" },
	{ "arrow_up", "line-previous" },
	{ "arrow_down", "line-next" },
	{ "page_up", "page-up" },
	{ "page_down", "page-down" },
}
local MOD_KEYS = {
	ctrl = {
		{ "ctrl+arrow_left", "word-backward" },
		{ "ctrl+arrow_right", "word-forward" },
		{ "ctrl+home", "input-start" },
		{ "ctrl+end", "input-end" },
		{ "ctrl+backspace", "delete-word-backward" },
		{ "ctrl+delete", "delete-word-forward" },
	},
	super = {
		{ "super+arrow_left", "line-start" },
		{ "super+arrow_right", "line-end" },
		{ "super+arrow_up", "input-start" },
		{ "super+arrow_down", "input-end" },
		{ "super+backspace", "delete-to-line-start" },
		{ "ctrl+a", "line-start" },
		{ "ctrl+e", "line-end" },
		{ "ctrl+b", "char-backward" },
		{ "ctrl+f", "char-forward" },
		{ "ctrl+p", "line-previous" },
		{ "ctrl+n", "line-next" },
		{ "ctrl+h", "delete-char-backward" },
		{ "ctrl+d", "delete-char-forward" },
		{ "ctrl+k", "delete-to-line-end" },
	},
}

--- A field's keymap: SPEC §10.2's default for the platform's mod, with its
--- edit shortcuts, then each data-keys value, the root's first. A binding
--- to a scroll action is left out where it stands, in its own value too: it
--- neither acts nor overrides an earlier binding of its key. platform is
--- {mod, edit}, or nil for ctrl and the default edit shortcuts.
function M.resolve(platform, multiline, ...)
	platform = platform or {}
	local m = M.keymap(multiline, platform)
	for _, b in ipairs(DEFAULT_KEYS) do
		m:bind(b[1], b[2])
	end
	m:bind("enter", multiline and "newline" or "submit")
	for _, b in ipairs(MOD_KEYS[m.mod]) do
		m:bind(b[1], b[2])
	end
	local edit = platform.edit or M.default_edit(m.mod)
	for _, a in ipairs(EDIT_ACTIONS) do
		for _, key in ipairs(edit[a] or {}) do
			local k = read(key, m.mod, false)
			if k and not FOCUS[k] then
				m:bind(k, a, read(key, m.mod, true))
			end
		end
	end
	local function bind(key, action, written)
		if not M.SCROLL_ACTIONS[action] then
			m:bind(key, action, written)
		end
	end
	for i = 1, select("#", ...) do
		each_binding(platform, select(i, ...), bind)
	end
	return m
end

return M
