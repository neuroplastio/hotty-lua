--- hotty speaks HOTTY, HTML Over The TTY (https://github.com/neuroplastio/hotty),
--- from Lua: the wire layer of SDK.md §3.
---
--- It does no I/O, starts nothing and reads no clock: the Detector takes the
--- time from its caller. It is Lua 5.1 and the standard library only, so it
--- runs in Neovim (LuaJIT), in plx (gopher-lua, which has no bit library), and
--- in any Lua 5.1 interpreter. The SDK layer for Neovim is hotty.nvim.
---
--- Names are SDK.md's canonical ones in snake case (Appendix A). Options are a
--- table, absence is nil, and an error is nil plus an error value.
local base64 = require("hotty.base64")
local msgpack = require("hotty.msgpack")
local inflate = require("hotty.inflate")
local utf8 = require("hotty.utf8")

local byte, char, sub, find, format, rep = string.byte, string.char, string.sub, string.find, string.format, string.rep
local floor = math.floor
local concat, insert = table.concat, table.insert
local join = require("hotty.join")

local M = {}

M.base64 = base64
M.msgpack = msgpack

-- Constants (SDK.md §3.1) -----------------------------------------------------

M.NUMBER = "7279" -- the OSC number
M.CHUNK = 4096 -- the most base64 bytes in one sequence
M.MAX_SIZE = 1000 -- the most columns or rows of a surface
M.MAX_NAME = 64 -- the longest surface name
M.VERSION = "0.4" -- the protocol version this SDK speaks, which its query lists (SPEC §4)
M.COMPRESS_FROM = 256 -- the smallest payload a program may compress
M.SCAN_MAX = 65536 -- the longest HOTTY sequence a Scanner takes

-- Event kinds (SPEC §9).
M.EVENT_CLICK = "click"
M.EVENT_CHANGE = "change"
M.EVENT_INPUT = "input"
M.EVENT_SUBMIT = "submit"
M.EVENT_PRESS = "press"
M.EVENT_FOCUS = "focus"
M.EVENT_BLUR = "blur"
M.EVENT_FIT = "fit"
M.EVENT_HOVER = "hover"
M.EVENT_VIEW = "view"
M.EVENT_DRAG_START = "dragstart"
M.EVENT_DRAG = "drag"
M.EVENT_DRAG_END = "dragend"
M.EVENT_COMMAND = "command" -- an edit command the program takes, or a pick from its menu (SPEC §10.6, §10.7); no surface
M.EVENT_CAPS = "caps" -- a capability changed (SPEC §4); no surface
M.EVENTS = {
	"click",
	"change",
	"input",
	"submit",
	"press",
	"focus",
	"blur",
	"fit",
	"hover",
	"view",
	"dragstart",
	"drag",
	"dragend",
	"command",
	"caps",
}

-- Error codes (SPEC §3.6).
M.EINVAL = "EINVAL"
M.ENOENT = "ENOENT"
M.ENOTARGET = "ENOTARGET"
M.EDETACHED = "EDETACHED"
M.EQUOTA = "EQUOTA"
M.EBUDGET = "EBUDGET"
M.EVERSION = "EVERSION"
M.CODES = { "EINVAL", "ENOENT", "ENOTARGET", "EDETACHED", "EQUOTA", "EBUDGET", "EVERSION" }

-- Delta ops (SPEC §6.1).
M.OP_MORPH = "morph"
M.OP_INNER = "inner"
M.OP_REPLACE = "replace"
M.OP_APPEND = "append"
M.OP_PREPEND = "prepend"
M.OP_BEFORE = "before"
M.OP_AFTER = "after"
M.OP_REMOVE = "remove"
M.OP_ATTR = "attr"
M.OP_UNATTR = "unattr"
M.OP_TEXT = "text"
M.OP_VAR = "var"
M.OP_REVEAL = "reveal"
M.OPS = {
	"morph",
	"inner",
	"replace",
	"append",
	"prepend",
	"before",
	"after",
	"remove",
	"attr",
	"unattr",
	"text",
	"var",
	"reveal",
}

-- The optional features a host may have (SPEC §4), as its capabilities list
-- them (Caps:has).
M.FEATURE_PASSTHROUGH = "passthrough" -- the pointer passes through the parts of a surface that take none (SPEC §9.3)
M.FEATURE_HOVER = "hover" -- it says where the pointer is, with hover events (SPEC §9.4)
M.FEATURE_COUNT = "count" -- it says that a click repeats one before it (SPEC §9)
M.FEATURE_MENU = "menu" -- it keeps a program's menu, shows its levels and lets the user pick from it (SPEC §10.7)
M.FEATURES = { "passthrough", "hover", "count", "menu" }

-- The modifier keys held during a click, a press or a drag, as the bits of
-- Event:mods (SPEC §9).
M.MOD_SHIFT = 1
M.MOD_ALT = 2
M.MOD_CTRL = 4
M.MOD_SUPER = 8

-- Where a reveal brings an element (SPEC §6.1).
M.REVEAL_NEAREST = "" -- as little as brings it into view
M.REVEAL_START = "start" -- its top at the top of each box that holds it
M.REVEAL_END = "end" -- its bottom at the bottom

-- How deep a menu's items nest, the top level's being one deep (SPEC §10.7).
M.MENU_DEPTH = 8

-- How many areas an a=touch may name (SPEC §9.6); a host refuses more.
M.TOUCH_MAX = 256

-- Quiet levels (SPEC §3.5).
M.REPLY_ALWAYS = 0
M.REPLY_ON_ERROR = 1
M.NO_REPLY = 2

-- A document's scroll axes, a bitmask (SPEC §5.1). Appendix A of SDK.md
-- spells them in lower case; both name the same values.
M.SCROLL_VERTICAL = 1
M.SCROLL_HORIZONTAL = 2
M.scroll_vertical = M.SCROLL_VERTICAL
M.scroll_horizontal = M.SCROLL_HORIZONTAL

local ESC = "\27"
local ST = "\27\\"
local HEAD = ESC .. "]" .. M.NUMBER -- ESC ] 7279
local PREFIX = HEAD .. ";" -- what begins every HOTTY sequence

-- Values and names (SDK.md §3.3, §3.5) -----------------------------------------

local utf8_len = utf8.len

--- v as a control value may be sent: each character a value may not hold
--- (":", ";", "=", a control character, anything outside ASCII) becomes one
--- "_": one for each UTF-8 code point, and one for each byte that is not
--- UTF-8 (SPEC §3.2). v is a string, or a number or boolean as tostring has
--- it.
function M.clean_value(v)
	v = tostring(v)
	if not find(v, "[^ -9<>-~]") then
		return v
	end
	local out, k, i, n = {}, 0, 1, #v
	while i <= n do
		local c = byte(v, i)
		k = k + 1
		if c >= 0x20 and c <= 0x7E and c ~= 58 and c ~= 59 and c ~= 61 then
			out[k] = char(c)
			i = i + 1
		else
			out[k] = "_"
			i = i + (c >= 0x80 and utf8_len(v, i) or 1)
		end
	end
	return join(out, k)
end

--- Whether s is a surface name: 1 to 64 of A-Z, a-z, 0-9, "_" and "-".
function M.valid_name(s)
	return type(s) == "string" and #s >= 1 and #s <= M.MAX_NAME and not find(s, "[^%w_%-]")
end

--- s made a surface name: each other character becomes "_", it is cut to 64,
--- and an empty name becomes "_".
function M.surface_name(s)
	s = tostring(s or "")
	if M.valid_name(s) then
		return s
	end
	local out, k, i, n = {}, 0, 1, #s
	while i <= n and k < M.MAX_NAME do
		local c = byte(s, i)
		k = k + 1
		if c < 0x80 and find(char(c), "[%w_%-]") then
			out[k] = char(c)
			i = i + 1
		else
			out[k] = "_"
			i = i + (c >= 0x80 and utf8_len(s, i) or 1)
		end
	end
	local name = concat(out)
	return name ~= "" and name or "_"
end

-- Control (SDK.md §3.2) ---------------------------------------------------------

local Control = {}
Control.__index = Control

--- A command's control: an ordered list of keys and values. pairs is an
--- optional list of {key, value}.
function M.control(pairs_)
	local c = setmetatable({ keys = {}, values = {} }, Control)
	for _, p in ipairs(pairs_ or {}) do
		c:with(p[1], p[2])
	end
	return c
end

--- A key's value, and whether it is present.
function Control:get(k)
	local v = self.values[k]
	return v, v ~= nil
end

--- Sets a key: in place if present, at the end if not. Returns the control.
function Control:with(k, v)
	if self.values[k] == nil then
		insert(self.keys, k)
	end
	self.values[k] = tostring(v)
	return self
end

--- The keys and values in order, as {key, value} pairs.
function Control:list()
	local out = {}
	for i, k in ipairs(self.keys) do
		out[i] = { k, self.values[k] }
	end
	return out
end

-- Encoding (SDK.md §3.3) --------------------------------------------------------

local function control_pairs(control)
	if getmetatable(control) == Control then
		return control:list()
	end
	return control
end

--- One command as one or more OSC sequences. control is a control
--- (hotty.control) or a list of {key, value}, in the order they go out;
--- values are cleaned, and the keys o and m, which are encode's to set, are
--- left out. A payload longer than CHUNK in base64 goes out in chunks, the
--- first with the whole control and m=1, every further one with m alone
--- (SPEC §3.4). payload is a string of bytes, or nil.
---
--- opts.compress, a function from bytes to zlib bytes, compresses a payload
--- of COMPRESS_FROM bytes or more when that makes it smaller, and marks it
--- o=z. Without it nothing is compressed: Lua has no zlib, and compressing is
--- the program's choice (SDK.md §3.3).
function M.encode(control, payload, opts)
	payload = payload and tostring(payload) or ""
	local body, zipped = payload, false
	if opts and opts.compress and #payload >= M.COMPRESS_FROM then
		local z = opts.compress(payload)
		if z and #z < #payload then
			body, zipped = z, true
		end
	end
	local parts = {}
	for _, p in ipairs(control_pairs(control)) do
		if p[1] ~= "o" and p[1] ~= "m" then -- Encode's to set
			parts[#parts + 1] = p[1] .. "=" .. M.clean_value(p[2])
		end
	end
	if zipped then
		parts[#parts + 1] = "o=z"
	end
	local ctl = concat(parts, ":")
	local b64 = body ~= "" and base64.encode(body) or ""
	if #b64 <= M.CHUNK then
		return PREFIX .. ctl .. (b64 ~= "" and (";" .. b64) or "") .. ST
	end
	local out = {}
	for i = 1, #b64, M.CHUNK do
		local piece = sub(b64, i, i + M.CHUNK - 1)
		if i == 1 then
			out[#out + 1] = PREFIX .. ctl .. ":m=1;" .. piece .. ST
		else
			local more = (i + M.CHUNK > #b64) and "0" or "1"
			out[#out + 1] = PREFIX .. "m=" .. more .. ";" .. piece .. ST
		end
	end
	return join(out)
end

-- Commands (SDK.md §3.4) --------------------------------------------------------

local function int(x)
	return format("%d", floor(tonumber(x)))
end

-- The reply options: n numbers the command and asks for its reply (q=0), q
-- sets the quiet level, and a q given wins over the one n implies, whatever
-- the order (SDK.md §3.4.2). q goes out only where the wire does not imply
-- it: 0 with n, else 1 (SPEC §3.5).
local function command(pairs_, payload, default_q, opts)
	local n, q = opts and opts.n, opts and opts.q
	if n ~= nil then
		pairs_[#pairs_ + 1] = { "n", int(n) }
	end
	if q == nil then
		q = n ~= nil and M.REPLY_ALWAYS or default_q
	end
	local implied = n ~= nil and M.REPLY_ALWAYS or M.REPLY_ON_ERROR
	if q ~= implied then
		pairs_[#pairs_ + 1] = { "q", int(q) }
	end
	return M.encode(pairs_, payload, opts)
end

--- Asks whether the terminal is a host that speaks VERSION: a=q with n (1
--- if nil) and v, the versions the program speaks, fenced by DA1 (SPEC §4).
--- opts.late asks for a late answer (late=1): what stands between the
--- program and the terminal may answer once there is a host.
function M.query(n, opts)
	local p = { { "a", "q" }, { "n", int(n or 1) }, { "v", M.VERSION } }
	if opts and opts.late then
		p[#p + 1] = { "late", "1" }
	end
	return M.encode(p) .. ESC .. "[c"
end

--- Withdraws a query that asked for a late answer (SPEC §4): a=q:q=2, a
--- query that wants no answer and takes the held one's place. No fence.
function M.withdraw_late()
	return M.encode({ { "a", "q" }, { "q", int(M.NO_REPLY) } })
end

--- Sends a surface's document (SPEC §5.1). opts: n, q (default 1);
--- detached, which creates it detached (d=1); and scroll, the axes along
--- which it scrolls, a bitmask of SCROLL_VERTICAL and SCROLL_HORIZONTAL (0 or
--- nil: it does not, and no key goes out).
function M.doc(surface, html, opts)
	local p = { { "a", "doc" }, { "s", surface } }
	if opts and opts.detached then
		p[#p + 1] = { "d", "1" }
	end
	if opts and opts.scroll and opts.scroll ~= 0 then
		p[#p + 1] = { "scroll", int(opts.scroll) }
	end
	return command(p, html, M.REPLY_ON_ERROR, opts)
end

-- A placement's control (SDK.md §3.4.1). A placement is a table: cols, rows
-- (0 or nil is auto), window {x, y, w, h}, z, press, fit, hover, keep_cursor.
-- press, fit and hover belong to the surface (SPEC §5.2), so each is true
-- (p=1), false (p=0) or nil, which sends nothing and leaves it as it was.
local function placement_pairs(surface, pl)
	local cols, rows = pl.cols or 0, pl.rows or 0
	local p = {
		{ "a", "place" },
		{ "s", surface },
		{ "c", int(cols) },
		{ "r", rows > 0 and int(rows) or "auto" },
	}
	local w = pl.window
	if w then
		local x, y, ww, wh = w.x or 0, w.y or 0, w.w or 0, w.h or 0
		local none = x == 0 and y == 0 and ww == 0 and wh == 0
		local whole = rows > 0 and x == 0 and y == 0 and ww == cols and wh == rows
		if not none and not whole then
			p[#p + 1] = { "x", int(x) }
			p[#p + 1] = { "y", int(y) }
			p[#p + 1] = { "w", int(ww) }
			p[#p + 1] = { "h", int(wh) }
		end
	end
	if pl.z and pl.z ~= 0 then
		p[#p + 1] = { "z", int(pl.z) }
	end
	for _, f in ipairs({ { "p", pl.press }, { "f", pl.fit }, { "v", pl.hover } }) do
		if f[2] == true then
			p[#p + 1] = { f[1], "1" }
		elseif f[2] == false then
			p[#p + 1] = { f[1], "0" }
		end
	end
	if pl.keep_cursor then
		p[#p + 1] = { "C", "1" }
	end
	return p
end

--- Places a surface at the cursor (SPEC §5.2). opts: n, q (default 1).
function M.place(surface, placement, opts)
	return command(placement_pairs(surface, placement), nil, M.REPLY_ON_ERROR, opts)
end

--- Places a surface with its top left at screen cell (x, y), counted from 0,
--- and leaves the cursor where it was: ESC 7, the cursor moved, the
--- placement with keep_cursor, ESC 8. opts: n, q (default 1).
function M.place_at(surface, x, y, placement, opts)
	local pl = {}
	for k, v in pairs(placement) do
		pl[k] = v
	end
	pl.keep_cursor = true
	return ESC
		.. "7"
		.. ESC
		.. "["
		.. int(y + 1)
		.. ";"
		.. int(x + 1)
		.. "H"
		.. M.place(surface, pl, opts)
		.. ESC
		.. "8"
end

--- Removes a surface's placement and keeps its document (SPEC §5.4).
--- opts: n, q (default 2).
function M.hide(surface, opts)
	return command({ { "a", "hide" }, { "s", surface } }, nil, M.NO_REPLY, opts)
end

-- msgpack for a program's bodies, a delta's ops, a menu and touch areas: each
-- str, int, array and map header in the smallest form it fits (SPEC §3.3).
local function mp_head(n, fix, fixmax, h8, h16, h32)
	if n <= fixmax then
		return char(fix + n)
	elseif h8 and n < 256 then
		return char(h8, n)
	elseif n < 65536 then
		return char(h16, floor(n / 256), n % 256)
	end
	return char(h32, floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

local function mp_str(s)
	return mp_head(#s, 0xa0, 31, 0xd9, 0xda, 0xdb) .. s
end

local function mp_array(n)
	return mp_head(n, 0x90, 15, nil, 0xdc, 0xdd)
end

local function mp_map(n)
	return mp_head(n, 0x80, 15, nil, 0xde, 0xdf)
end

-- n, at least 0, big-endian in size bytes: in arithmetic, since gopher-lua
-- has no bit library.
local function mp_be(n, size)
	local out = {}
	for i = size, 1, -1 do
		out[i] = char(n % 256)
		n = floor(n / 256)
	end
	return concat(out)
end

-- An int, a whole number within 2^53 of 0 (a fraction is dropped).
local function mp_int(n)
	n = floor(n)
	if n >= 0 then
		if n < 128 then
			return char(n)
		elseif n < 256 then
			return "\204" .. char(n)
		elseif n < 65536 then
			return "\205" .. mp_be(n, 2)
		elseif n < 4294967296 then
			return "\206" .. mp_be(n, 4)
		end
		return "\207" .. mp_be(n, 8)
	elseif n >= -32 then
		return char(256 + n)
	elseif n >= -128 then
		return "\208" .. char(256 + n)
	elseif n >= -32768 then
		return "\209" .. mp_be(65536 + n, 2)
	elseif n >= -2147483648 then
		return "\210" .. mp_be(4294967296 + n, 4)
	end
	local hi = floor(n / 4294967296)
	return "\211" .. mp_be(4294967296 + hi, 4) .. mp_be(n - hi * 4294967296, 4)
end

-- Ops (SDK.md §3.4.3) ------------------------------------------------------------

-- An op: a table with op, target, key and value. value is nil for an op that
-- takes none, and a string, even empty, for one that does.
local function valued(op, target, key, value)
	return { op = op, target = target, key = key, value = tostring(value) }
end

--- Morphs the target into html, or with no target (nil or ""), each
--- top-level element of html into the document's element with its id (SPEC
--- §6.2).
function M.morph(target, html)
	return valued("morph", target, nil, html)
end

--- Morphs the target's children into the nodes of html.
function M.inner(target, html)
	return valued("inner", target, nil, html)
end

--- Replaces the target with the nodes of html, without morphing.
function M.replace(target, html)
	return valued("replace", target, nil, html)
end

--- Adds the nodes of html as the target's last children.
function M.append(target, html)
	return valued("append", target, nil, html)
end

--- Adds the nodes of html as the target's first children.
function M.prepend(target, html)
	return valued("prepend", target, nil, html)
end

--- Inserts the nodes of html before the target.
function M.before(target, html)
	return valued("before", target, nil, html)
end

--- Inserts the nodes of html after the target.
function M.after(target, html)
	return valued("after", target, nil, html)
end

--- Removes the target. It has no value.
function M.remove(target)
	return { op = "remove", target = target }
end

--- Sets the target's attribute name.
function M.attr(target, name, value)
	return valued("attr", target, name, value)
end

--- Removes the target's attribute name. It has no value.
function M.unattr(target, name)
	return { op = "unattr", target = target, key = name }
end

--- Replaces the target's children with one text node.
function M.text(target, text)
	return valued("text", target, nil, text)
end

--- Sets the custom property --name on the target.
function M.var(target, name, value)
	return valued("var", target, name, value)
end

--- Scrolls the target into view (SPEC §6.1): where is "start", "end", or nil
--- (or "") for as little as brings it into view, which gives the op no
--- value. (SDK.md's RevealOp; hotty.reveal sends one.)
function M.reveal_op(target, where)
	if where == nil or where == M.REVEAL_NEAREST then
		return { op = "reveal", target = target }
	end
	return valued("reveal", target, nil, where)
end

-- One op as the msgpack map SDK.md §3.4.3 gives it: op, t unless the target
-- is empty, k when there is a key, v when there is a value.
local function mp_op(o)
	local out, n = { mp_str("op") .. mp_str(o.op) }, 1
	if o.target ~= nil and o.target ~= "" then
		out[#out + 1] = mp_str("t") .. mp_str(o.target)
		n = n + 1
	end
	if o.key ~= nil and o.key ~= "" then
		out[#out + 1] = mp_str("k") .. mp_str(o.key)
		n = n + 1
	end
	if o.value ~= nil then
		out[#out + 1] = mp_str("v") .. mp_str(o.value)
		n = n + 1
	end
	return mp_map(n) .. concat(out)
end

--- Changes a surface's document (SPEC §6.1): ops, a list of the ops that
--- hotty.morph, hotty.text, hotty.attr and the rest build, which the host
--- applies in order and shows as one. A program that changes a surface in
--- one frame sends one delta (SDK.md §2.9). A delta of no ops is sent, and
--- the host refuses it (EINVAL). opts: n, q (default 2).
function M.delta(surface, ops, opts)
	local out = {}
	for i, o in ipairs(ops or {}) do
		out[i] = mp_op(o)
	end
	local body = mp_map(1) .. mp_str("ops") .. mp_array(#out) .. join(out, #out)
	return command({ { "a", "delta" }, { "s", surface } }, body, M.NO_REPLY, opts)
end

--- Replaces the target's children with one text node: a delta of one text op.
function M.set_text(surface, target, text, opts)
	return M.delta(surface, { M.text(target, text) }, opts)
end

--- Sets the custom property --name on the target: a delta of one var op.
function M.set_var(surface, target, name, value, opts)
	return M.delta(surface, { M.var(target, name, value) }, opts)
end

--- Sets the target's attribute name: a delta of one attr op.
function M.set_attr(surface, target, name, value, opts)
	return M.delta(surface, { M.attr(target, name, value) }, opts)
end

--- Removes the target's attribute name: a delta of one unattr op.
function M.remove_attr(surface, target, name, opts)
	return M.delta(surface, { M.unattr(target, name) }, opts)
end

--- Morphs the target into html: a delta of one morph op.
function M.morph_to(surface, target, html, opts)
	return M.delta(surface, { M.morph(target, html) }, opts)
end

--- Scrolls the target into view (SPEC §6.1): a delta of one reveal op, where
--- "start" or "end", or nil (or "") for as little as brings it into view.
function M.reveal(surface, target, where, opts)
	return M.delta(surface, { M.reveal_op(target, where) }, opts)
end

--- Sends a resource that documents refer to as cid:<id> (SPEC §7.1).
--- opts: n, q (default 2).
function M.res(id, mime, data, opts)
	return command({ { "a", "res" }, { "id", id }, { "type", mime } }, data, M.NO_REPLY, opts)
end

--- Deletes a resource. opts: n, q (default 2).
function M.del_res(id, opts)
	return command({ { "a", "del" }, { "id", id } }, nil, M.NO_REPLY, opts)
end

--- Deletes a surface and its placement. opts: n, q (default 2).
function M.del(surface, opts)
	return command({ { "a", "del" }, { "s", surface } }, nil, M.NO_REPLY, opts)
end

--- Deletes every surface. opts: n, q (default 2).
function M.del_all(opts)
	return command({ { "a", "del" } }, nil, M.NO_REPLY, opts)
end

--- Gives a surface up: it reports nothing more (SPEC §5.5). opts: n, q
--- (default 2).
function M.detach(surface, opts)
	return command({ { "a", "detach" }, { "s", surface } }, nil, M.NO_REPLY, opts)
end

--- Gives a surface the keyboard, at target if given (SPEC §10.1). opts: n,
--- q (default 2).
function M.focus(surface, target, opts)
	local p = { { "a", "focus" }, { "s", surface } }
	if target and target ~= "" then
		p[#p + 1] = { "t", target }
	end
	return command(p, nil, M.NO_REPLY, opts)
end

--- Takes the keyboard back from a surface. opts: n, q (default 2).
function M.blur(surface, opts)
	return command({ { "a", "blur" }, { "s", surface } }, nil, M.NO_REPLY, opts)
end

--- Takes the edit commands named (SPEC §10.6), a list of "select-all",
--- "copy", "cut", "paste", "undo", "redo": their keys, the host's edit
--- shortcuts (caps.edit), then reach the program as command events in place
--- of their bytes. Each replaces the last; none takes nothing. It holds for
--- the screen it is sent on. opts: n, q (default 2).
function M.edit(names, opts)
	return command({ { "a", "edit" }, { "take", table.concat(names or {}, ",") } }, nil, M.NO_REPLY, opts)
end

--- Tells the host what the program can do now (SPEC §10.7): its menu, a tree
--- of actions with the keys that reach them and the names a pick sends. It
--- lasts until the program sends another, and with nil the program has none.
--- tree is { label, items = { { key, label, name, enabled, items }… } }:
--- enabled is true when nil, and an item with items is a group. A host that
--- has the feature menu (Caps:has) shows and picks from it; on one that does
--- not, the program shows its menu itself. Keep it within MENU_DEPTH
--- levels. It goes out as msgpack, each value in the smallest form of its
--- type: label unless it is empty, items; each item key, label and name
--- unless they are empty, enabled, and items unless there are none. opts: n,
--- q (default 2).
function M.menu(tree, opts)
	if tree == nil then
		return command({ { "a", "menu" } }, nil, M.NO_REPLY, opts)
	end
	local function items(list, out)
		out[#out + 1] = mp_array(#list)
		for _, it in ipairs(list) do
			local parts, n = {}, 1
			for _, f in ipairs({ "key", "label", "name" }) do
				local v = it[f]
				if v ~= nil and v ~= "" then
					parts[#parts + 1] = mp_str(f) .. mp_str(v)
					n = n + 1
				end
			end
			parts[#parts + 1] = mp_str("enabled") .. (it.enabled == false and "\194" or "\195")
			local sub_ = it.items
			if sub_ and #sub_ > 0 then
				n = n + 1
			end
			out[#out + 1] = mp_map(n) .. concat(parts)
			if sub_ and #sub_ > 0 then
				out[#out + 1] = mp_str("items")
				items(sub_, out)
			end
		end
	end
	local label = tree.label or ""
	local out = { mp_map(label ~= "" and 2 or 1) }
	if label ~= "" then
		out[#out + 1] = mp_str("label") .. mp_str(label)
	end
	out[#out + 1] = mp_str("items")
	items(tree.items or {}, out)
	return command({ { "a", "menu" } }, join(out, #out), M.NO_REPLY, opts)
end

--- Shows the level of the program's menu that the keys typed reach (SPEC
--- §10.7): keys names them as SPEC §10.4 does, "Space" and "f" for a leader
--- and a group. With none it shows the top level. A level shows until the
--- program shows another, or hides it. opts: n, q (default 2).
function M.menu_show(keys, opts)
	local body = nil
	if keys and #keys > 0 then
		local out = { mp_map(1) .. mp_str("seq") .. mp_array(#keys) }
		for i, k in ipairs(keys) do
			out[i + 1] = mp_str(k)
		end
		body = join(out, #out)
	end
	return command({ { "a", "menu" }, { "show", "1" } }, body, M.NO_REPLY, opts)
end

--- Hides the level shown (SPEC §10.7). The menu stays. opts: n, q (default
--- 2).
function M.menu_hide(opts)
	return command({ { "a", "menu" }, { "show", "0" } }, nil, M.NO_REPLY, opts)
end

--- Names the cells where a finger drags as the mouse does (SPEC §9.6), so
--- that what the program drags with the mouse in its cells, a slider, a
--- finger drags too. areas is a list of { c, r, w, h, drag }: the first
--- column and row each covers, counted from 0 at the screen's top left (a
--- mouse report counts from 1), the columns and rows it spans, at least 1
--- each, and the way a finger drags in it, "x" across, "y" up and down, or
--- "xy" either. While the program has the terminal report the mouse's
--- buttons, a touch that begins in an area and first moves the way it drags
--- is the primary button: pressed where it began, moved with the finger,
--- released where it lifts; a tap presses and releases.
---
--- The areas last until the program sends others; with none (nil or {}) it
--- leaves none, and the command has no payload. They are cells of the screen
--- it is sent on: the main and the alternate screen keep their own, leaving
--- the alternate screen drops its, and a full reset drops both. So the
--- program sends them again when what it drew moves, the size changes or it
--- switches screens, and touch() when it ends. Keep to TOUCH_MAX areas. Each
--- goes out as a map of c, r, w, h and drag, in that order. opts: n, q
--- (default 2).
function M.touch(areas, opts)
	if areas == nil or #areas == 0 then
		return command({ { "a", "touch" } }, nil, M.NO_REPLY, opts)
	end
	local out = { mp_map(1) .. mp_str("areas") .. mp_array(#areas) }
	for i, a in ipairs(areas) do
		out[i + 1] = mp_map(5)
			.. (mp_str("c") .. mp_int(a.c))
			.. (mp_str("r") .. mp_int(a.r))
			.. (mp_str("w") .. mp_int(a.w))
			.. (mp_str("h") .. mp_int(a.h))
			.. (mp_str("drag") .. mp_str(a.drag))
	end
	return command({ { "a", "touch" } }, join(out, #out), M.NO_REPLY, opts)
end

--- Commands already built, bracketed in synchronized output, so the host
--- shows all of them or none (SPEC §6.3). Takes the commands as arguments or
--- as one list.
function M.sync(...)
	local cmds = { ... }
	if #cmds == 1 and type(cmds[1]) == "table" then
		cmds = cmds[1]
	end
	return ESC .. "[?2026h" .. join(cmds) .. ESC .. "[?2026l"
end

-- Messages (SDK.md §3.9) --------------------------------------------------------

local function to_int(s)
	if type(s) == "string" and find(s, "^%-?%d+$") then
		return tonumber(s)
	end
	return nil
end

local Error = {}
Error.__index = Error
Error.__tostring = function(e)
	local s = "hotty: " .. (e.code or "")
	if e.detail and e.detail ~= "" then
		s = s .. ": " .. e.detail
	end
	if e.re then
		s = s
			.. " (re="
			.. e.re
			.. (e.surface and (", s=" .. e.surface) or "")
			.. (e.op and (", op " .. e.op) or "")
			.. ")"
	end
	return s
end
M.Error = Error

--- An error: a code (EINVAL, ENOENT, …) and a detail, and the action and
--- surface it answers when known, and, in an error answering a delta, the
--- index of the op at fault, from 0 as the wire has it (SPEC §6.1). tostring
--- names them.
function M.error(code, detail, re, surface, op)
	return setmetatable({ code = code, detail = detail, re = re, surface = surface, op = op }, Error)
end

-- The types of a body's fields (SPEC §3.3): a type's name; a list of one
-- type, an array of it; or a table of fields by name, or with "*" the type
-- of each value of a map keyed by strings. A field not named is not
-- checked, as one the SDK does not know is ignored (SDK.md §2.7).
local AREA = { c = "int", r = "int", w = "int", h = "int" }
local DRAG = { c = "int", r = "int", mods = "int", x = "int", y = "int", tx = "int", ty = "int" }
local ERROR = { code = "str", detail = "str" }
local CAPS = {
	v = "str",
	cellcss = { w = "float", h = "float" },
	scale = "float",
	scheme = "str",
	mod = "str",
	features = { "str" },
	limits = { ["*"] = "int" },
	net = { ["*"] = { "str" } },
	edit = { ["*"] = { "str" } },
	host = "str",
	version = "str",
}
-- Each kind's detail (SPEC §9); a kind not here carries none the SDK reads.
local DETAIL = {
	click = { value = "str", href = "str", url = "str", area = AREA, mods = "int", count = "int" },
	press = { area = AREA, mods = "int" },
	change = { checked = "bool", value = "str" },
	input = { value = "str" },
	submit = { fields = { { "str" } } },
	fit = { r = "int" },
	dragstart = DRAG,
	drag = DRAG,
	dragend = DRAG,
	hover = { c = "int", r = "int", out = "bool" },
	view = { ["in"] = { ["*"] = AREA }, ["end"] = "bool" },
	command = { name = "str", key = "str", text = "str" },
	caps = CAPS,
}

local MAX_INT = 2 ^ 53 - 1 -- SPEC §3.3
local NO_KINDS = {}

-- Whether v is of type t. kind is v's mark in its table, and kinds marks
-- the entries of v's tables (hotty.msgpack.decode): an entry is a float, a
-- bin, an array, a timestamp or an extension of another type when marked so,
-- and otherwise an int, a str, a bool or a map, which its Lua type tells
-- apart. An extension of another type is absent, v nil, so it is of no type.
local function typed(v, t, kind, kinds)
	if t == "int" then
		return kind == nil and type(v) == "number" and v == floor(v) and v >= -MAX_INT and v <= MAX_INT
	elseif t == "float" then
		return kind == "float" and type(v) == "number"
	elseif t == "str" then
		return kind == nil and type(v) == "string"
	elseif t == "bool" then
		return kind == nil and type(v) == "boolean"
	elseif type(v) ~= "table" or kind ~= (t[1] and "array" or nil) then
		return false
	end
	local marks = kinds[v] or NO_KINDS
	if t[1] then
		local n = 0
		for _ in pairs(v) do
			n = n + 1
		end
		for i in pairs(marks) do
			if v[i] == nil then -- an extension: a hole, or past the end
				return false
			end
		end
		for i = 1, n do
			if v[i] == nil or not typed(v[i], t[1], marks[i], kinds) then
				return false
			end
		end
		return true
	end
	local each = t["*"]
	if each then
		for k, x in pairs(v) do
			if not typed(x, each, marks[k], kinds) then
				return false
			end
		end
		for k in pairs(marks) do
			if v[k] == nil then -- an extension, where every field is known
				return false
			end
		end
		return true
	end
	for k, f in pairs(t) do
		if (v[k] ~= nil or marks[k]) and not typed(v[k], f, marks[k], kinds) then
			return false
		end
	end
	return true
end

-- Whether the msgpack bytes s are a map: decode marks nothing the whole
-- value is, so its first byte tells.
local function is_map(s)
	local c = byte(s, 1)
	return c ~= nil and ((c >= 0x80 and c <= 0x8F) or c == 0xDE or c == 0xDF)
end

-- A body's map when each field t names has its type: nil when it does not
-- decode, which leaves absent all it would fill (SDK.md §3.9).
local function typed_body(v, kinds, t)
	if type(v) == "table" and typed(v, t, nil, type(kinds) == "table" and kinds or NO_KINDS) then
		return v
	end
	return nil
end

local Message = {}
Message.__index = Message
M.Message = Message

local function message(control, keys, payload)
	return setmetatable({ control = control, keys = keys, payload = payload }, Message)
end

--- The body (SPEC §3.3), as hotty.msgpack.decode reads it: a map and its
--- kinds. nil when there is none, and nil and an error when it is not one
--- msgpack value, or that value is not a map.
function Message:body()
	if self.payload == "" then
		return nil
	end
	if self._body == nil then
		local v, kinds = msgpack.decode(self.payload)
		if type(v) == "table" and is_map(self.payload) then
			self._body, self._kinds = v, kinds
		else
			self._body = false
			self._err = v == nil and type(kinds) == "string" and kinds or "hotty: a body that is not a map"
		end
	end
	if not self._body then
		return nil, self._err
	end
	return self._body, self._kinds
end

-- m's body's map when each field t names has its type, or nil.
local function typed_message(m, t)
	local v, kinds = m:body()
	return typed_body(v, kinds, t)
end

local Reply = {}
Reply.__index = Reply
M.Reply = Reply

--- The message as a reply (SPEC §3.6), or nil if it is not one.
function Message:reply()
	local c = self.control
	if c.a ~= "ok" and c.a ~= "err" then
		return nil
	end
	local r = setmetatable({
		message = self,
		ok = c.a == "ok",
		re = c.re,
		n = to_int(c.n),
		surface = c.s,
		cols = to_int(c.c),
		rows = to_int(c.r),
		op = to_int(c.i),
	}, Reply)
	if r.op and r.op < 0 then
		r.op = nil
	end
	if not r.ok then
		local body = typed_message(self, ERROR)
		if body then
			r.code, r.detail = body.code, body.detail
		end
	end
	return r
end

local Caps = {}
Caps.__index = Caps
M.Caps = Caps

-- The capabilities in a body whose fields have their types.
local function new_caps(d)
	local c = setmetatable({ raw = d }, Caps)
	c.v = d.v or ""
	if d.cellcss and d.cellcss.w and d.cellcss.h then
		c.cell_css = { w = d.cellcss.w, h = d.cellcss.h }
	end
	c.scale = d.scale
	c.scheme = d.scheme or ""
	c.mod = d.mod
	c.features = d.features or {}
	c.limits = d.limits or {}
	c.net = d.net or {}
	c.edit = d.edit
	c.host = d.host
	c.version = d.version
	return c
end

--- What a host says about itself (SPEC §4), from the body of its reply to a
--- query, the msgpack bytes: plx's raw is the same. nil when there is no
--- body, or it does not decode (SDK.md §3.9). raw is the body's map, with
--- the fields the SDK does not know.
function M.caps(body)
	if type(body) ~= "string" or not is_map(body) then
		return nil
	end
	local v, kinds = msgpack.decode(body)
	local d = typed_body(v, kinds, CAPS)
	return d and new_caps(d) or nil
end

--- The capabilities a reply to a query carries, or nil: none, or a body
--- that does not decode.
function Reply:caps()
	if not self.ok or self.re ~= "q" then
		return nil
	end
	local d = typed_message(self.message, CAPS)
	return d and new_caps(d) or nil
end

--- The reply as an error, or nil when it is ok.
function Reply:err()
	if self.ok then
		return nil
	end
	return M.error(self.code or "", self.detail, self.re, self.surface, self.op)
end

local Event = {}
Event.__index = Event
M.Event = Event

--- The message as an event (SPEC §9), or nil if it is not one. Its detail
--- is read by its kind (SDK.md §3.9): the body's map when it decodes as the
--- kind's, and empty when it does not, or the kind is one the SDK does not
--- know, whose body is the message's.
function Message:event()
	local c = self.control
	if c.a ~= "ev" then
		return nil
	end
	local t = DETAIL[c.e]
	local d = t and typed_message(self, t)
	if d and c.e == "submit" then
		-- Each field is a pair of a name and a value, and no more.
		for _, f in ipairs(d.fields or {}) do
			if #f ~= 2 then
				d = nil
				break
			end
		end
	end
	return setmetatable({
		message = self,
		surface = c.s,
		kind = c.e,
		target = c.t or "", -- absent where no element is meant (SPEC §9)
		detail = d or {},
		_decoded = d ~= nil,
	}, Event)
end

--- The detail's value, a string: click, change, input.
function Event:value()
	local k = self.kind
	if k ~= M.EVENT_CLICK and k ~= M.EVENT_CHANGE and k ~= M.EVENT_INPUT then
		return nil
	end
	return self.detail.value
end

--- The detail's checked, a boolean: change.
function Event:checked()
	if self.kind ~= M.EVENT_CHANGE then
		return nil
	end
	return self.detail.checked
end

--- A submit's fields in tree order, a list of {name, value} pairs (two
--- fields of one name are two pairs); nil when its detail does not decode.
function Event:fields()
	if self.kind ~= M.EVENT_SUBMIT or not self._decoded then
		return nil
	end
	local out = {}
	for i, f in ipairs(self.detail.fields or {}) do
		out[i] = { f[1], f[2] }
	end
	return out
end

--- The modifier keys held, as the bits MOD_SHIFT, MOD_ALT, MOD_CTRL and
--- MOD_SUPER: in a click, a press and a drag's events (SPEC §9). 0 when none
--- is, and for any other kind.
function Event:mods()
	local k = self.kind
	if
		k == M.EVENT_CLICK
		or k == M.EVENT_PRESS
		or k == M.EVENT_DRAG_START
		or k == M.EVENT_DRAG
		or k == M.EVENT_DRAG_END
	then
		return self.detail.mods or 0
	end
	return 0
end

--- A link's click: its href, and its url, or nil when there is none.
function Event:link()
	local href = self.detail.href
	if self.kind ~= M.EVENT_CLICK or href == nil then
		return nil
	end
	return href, self.detail.url
end

--- A fit's rows.
function Event:fit_rows()
	if self.kind ~= M.EVENT_FIT then
		return nil
	end
	return self.detail.r
end

--- A drag's cell: {c, r}; its steps x and y for an element with data-steps,
--- and tx and ty in t, for a t with drop in its data-on and data-steps (SPEC
--- §9.1), each nil when the detail has none; 0 is a step like any other. The
--- keys held are the event's mods.
function Event:drag()
	local k = self.kind
	if k ~= M.EVENT_DRAG_START and k ~= M.EVENT_DRAG and k ~= M.EVENT_DRAG_END then
		return nil
	end
	local d = self.detail
	if d.c == nil or d.r == nil then
		return nil
	end
	return { c = d.c, r = d.r, x = d.x, y = d.y, tx = d.tx, ty = d.ty }
end

--- A hover's cell, {c, r, out = false}, or {out = true} when the pointer
--- left.
function Event:hover()
	if self.kind ~= M.EVENT_HOVER then
		return nil
	end
	local d = self.detail
	if d.out == true then
		return { out = true }
	end
	if d.c == nil or d.r == nil then
		return nil
	end
	return { c = d.c, r = d.r, out = false }
end

--- A click's place in its run of clicks on its element, as the user's
--- platform counts them (SPEC §9): 2 for the second click of a double
--- click, 1 for a single click or the keyboard's; nil for another kind.
function Event:count()
	if self.kind ~= M.EVENT_CLICK then
		return nil
	end
	local n = self.detail.count
	return type(n) == "number" and n > 1 and n or 1
end

--- A click's or a press's element, in cells from the surface's top left
--- cell: {c, r, w, h} (SPEC §9).
function Event:area()
	if self.kind ~= M.EVENT_CLICK and self.kind ~= M.EVENT_PRESS then
		return nil
	end
	local a = self.detail.area
	if not a or a.c == nil or a.r == nil or a.w == nil or a.h == nil then
		return nil
	end
	return { c = a.c, r = a.r, w = a.w, h = a.h }
end

--- A view's elements in view and whether the document shows its end (SPEC
--- §9.5): {areas = {[id] = {c, r, w, h}}, at_end = bool}, from the wire's
--- in and end, which are Lua keywords. An element whose area lacks a field
--- is left out. nil when the detail does not decode.
function Event:view()
	if self.kind ~= M.EVENT_VIEW or not self._decoded then
		return nil
	end
	local d, areas = self.detail, {}
	for id, a in pairs(d["in"] or {}) do
		if a.c ~= nil and a.r ~= nil and a.w ~= nil and a.h ~= nil then
			areas[id] = { c = a.c, r = a.r, w = a.w, h = a.h }
		end
	end
	return { areas = areas, at_end = d["end"] == true }
end

local function has(list, v)
	for _, x in ipairs(list) do
		if x == v then
			return true
		end
	end
	return false
end

--- An edit command's (SPEC §10.6, §10.7): {name, key, text}, key "" from the
--- terminal's menu or a pick from the program's, text nil when a paste
--- carries none; nil for another kind or a detail with no name.
function Event:command()
	local d = self.detail
	if self.kind ~= M.EVENT_COMMAND or type(d.name) ~= "string" then
		return nil
	end
	return { name = d.name, key = d.key or "", text = d.text }
end

--- A caps event's capabilities that changed (SPEC §4): a Caps whose raw has
--- only those fields, for Caps:merge. nil when its detail does not decode.
function Event:changed()
	if self.kind ~= M.EVENT_CAPS or not self._decoded then
		return nil
	end
	return new_caps(self.detail)
end

-- Whether a table is the empty value of its field's type: an empty map or
-- array, or an empty string (SPEC §9).
local function emptied(v)
	return v == "" or (type(v) == "table" and next(v) == nil)
end

--- These capabilities with the fields a caps event changed in place of
--- their own, and without those it empties: a field that became absent
--- comes as its type's empty value (SPEC §9), {}, [] or "".
function Caps:merge(changed)
	local d = {}
	for k, v in pairs(self.raw) do
		d[k] = v
	end
	for k, v in pairs(changed.raw) do
		if emptied(v) and CAPS[k] ~= nil then
			d[k] = nil
		else
			d[k] = v
		end
	end
	return new_caps(d)
end

--- Whether the host has an optional feature (SPEC §4): "passthrough",
--- "hover", "count" or "menu". Everything else a 0.3 host does, it does.
function Caps:has(feature)
	return has(self.features, feature)
end

--- Whether the terminal's scheme is light.
function Caps:light()
	return self.scheme == "light"
end

-- For hosts and relays (SDK.md §3.4.3, §3.4) --------------------------------------

local OP_NAMES = {}
for _, name in ipairs(M.OPS) do
	OP_NAMES[name] = true
end

-- A fault in a command a host or relay reads: an EINVAL error, naming the op
-- at fault by its index from 0 when there is one.
local function invalid(m, detail, op)
	return M.error(M.EINVAL, detail, m.control.a, m.control.s, op)
end

-- The elements of a decoded array, 1 to n: n counts the holes and
-- extensions too.
local function array_len(t, marks)
	local n = 0
	for i in pairs(t) do
		n = math.max(n, i)
	end
	for i in pairs(marks or NO_KINDS) do
		n = math.max(n, i)
	end
	return n
end

--- A delta command's ops (SPEC §6.1), as a host or a relay reads them,
--- checking the whole body first: a list of ops, each a table with op,
--- target, key and value (nil where the body has none). nil and an error
--- (EINVAL, with op, the index of the first op at fault from 0, when there
--- is one) when the body does not decode (SPEC §3.3) or has no ops, an op is
--- not a map, holds op, t, k or v as anything but a str, or names an op
--- there is none of, an op lacks the t or k it needs (an empty one is
--- none), or a reveal has a value other than start or end. A value an op
--- does not take is ignored, and so is a key this SDK does not know.
function M.delta_of(m)
	if m.control.a ~= "delta" then
		return nil, invalid(m, "not a delta command")
	end
	local v, kinds = m:body()
	if not v then
		return nil, invalid(m, "body does not decode")
	end
	kinds = type(kinds) == "table" and kinds or NO_KINDS
	local ops = v.ops
	if ops == nil and (kinds[v] or NO_KINDS).ops == nil then
		return nil, invalid(m, "no ops")
	elseif (kinds[v] or NO_KINDS).ops ~= "array" then
		return nil, invalid(m, "body does not decode")
	end
	local marks = kinds[ops]
	local n = array_len(ops, marks)
	local out = {}
	for i = 1, n do
		local o = ops[i]
		local omarks = kinds[o]
		if type(o) ~= "table" or (marks and marks[i]) then
			return nil, invalid(m, "op is not a map of strs", i - 1)
		end
		for _, f in ipairs({ "op", "t", "k", "v" }) do
			local x = o[f]
			if (x ~= nil and type(x) ~= "string") or (omarks and omarks[f]) then
				return nil, invalid(m, "op is not a map of strs", i - 1)
			end
		end
		out[i] = { op = o.op, target = o.t, key = o.k, value = o.v }
	end
	if n == 0 then
		return nil, invalid(m, "no ops")
	end
	for i, o in ipairs(out) do
		local name = o.op or ""
		if not OP_NAMES[name] then
			return nil, invalid(m, "unknown op " .. name, i - 1)
		elseif (o.target == nil or o.target == "") and name ~= "morph" then
			return nil, invalid(m, "missing t", i - 1)
		elseif (o.key == nil or o.key == "") and (name == "attr" or name == "unattr" or name == "var") then
			return nil, invalid(m, "missing k", i - 1)
		elseif name == "reveal" and o.value ~= nil and o.value ~= "start" and o.value ~= "end" then
			return nil, invalid(m, "reveal " .. o.value, i - 1)
		end
	end
	return out
end

-- The types of a menu's body (SPEC §10.7).
local MENU_ITEM = { key = "str", label = "str", name = "str", enabled = "bool" }
local MENU = { label = "str" }

-- Whether items, a decoded array, is a list of menu items (kinds marking its
-- entries), their own items too, at any depth.
local function menu_items(items, marks, kinds)
	if marks ~= nil then
		for _ in pairs(marks) do
			return false -- an item is a map, which carries no mark
		end
	end
	for i = 1, array_len(items, marks) do
		local it = items[i]
		if type(it) ~= "table" or not typed(it, MENU_ITEM, nil, kinds) then
			return false
		end
		local im = kinds[it]
		if it.items ~= nil or (im and im.items) then
			if not (im and im.items == "array") then
				return false
			end
			if not menu_items(it.items, kinds[it.items], kinds) then
				return false
			end
		end
	end
	return true
end

-- How deep items nest, the first level being one.
local function menu_depth(items)
	local d = 0
	for _, it in ipairs(items) do
		d = math.max(d, menu_depth(it.items))
	end
	return #items > 0 and d + 1 or 0
end

-- A menu's items as a tree reads them: key, label and name "" where
-- absent, enabled false where absent, and items an empty list.
local function menu_copy(items)
	local out = {}
	for i, it in ipairs(items or {}) do
		out[i] = {
			key = it.key or "",
			label = it.label or "",
			name = it.name or "",
			enabled = it.enabled == true,
			items = menu_copy(it.items),
		}
	end
	return out
end

--- An a=menu command's menu (SPEC §10.7), as a host or a relay reads it: a
--- tree, { label, items = { { key, label, name, enabled, items }… } }, with
--- "" for what the body leaves out, enabled false where it is absent, and
--- items {} for an item that is no group. nil, and no error, for a command
--- with no body, which leaves the program no menu. nil and an error (EINVAL)
--- for a body that is no menu, holds a field of another type, or nests its
--- items deeper than MENU_DEPTH. A command with show is not a menu: menu_show_of
--- reads it.
function M.menu_of(m)
	if m.control.a ~= "menu" then
		return nil, invalid(m, "not a menu command")
	end
	if m.payload == "" then
		return nil
	end
	local v, kinds = m:body()
	if not v or not typed(v, MENU, nil, type(kinds) == "table" and kinds or NO_KINDS) then
		return nil, invalid(m, "body does not decode")
	end
	kinds = type(kinds) == "table" and kinds or NO_KINDS
	local marks = kinds[v]
	local items = v.items
	if items ~= nil or (marks and marks.items) then
		if not (marks and marks.items == "array") or not menu_items(items, kinds[items], kinds) then
			return nil, invalid(m, "body does not decode")
		end
	end
	local tree = { label = v.label or "", items = menu_copy(items) }
	if menu_depth(tree.items) > M.MENU_DEPTH then
		return nil, invalid(m, "items nest deeper than eight")
	end
	return tree
end

--- An a=menu command's show body (SPEC §10.7), as a host or a relay reads it:
--- the keys typed, as the program names them, whose level to show, a list. No
--- body, or none in it, is the top level: an empty list, and no error. A
--- body that is no map, or whose seq is not an array of str, is nil and an
--- error (EINVAL).
function M.menu_show_of(m)
	if m.control.a ~= "menu" then
		return nil, invalid(m, "not a menu command")
	end
	if m.payload == "" then
		return {}
	end
	local v, kinds = m:body()
	if not v or not typed(v, { seq = { "str" } }, nil, type(kinds) == "table" and kinds or NO_KINDS) then
		return nil, invalid(m, "seq is not an array of str")
	end
	local out = {}
	for i, k in ipairs(v.seq or {}) do
		out[i] = k
	end
	return out
end

--- The level of tree that the keys seq reach (SPEC §10.7): its items, a
--- group's, for a host to show those that have a key. From the top level,
--- each key of seq enters the first group (an item with items) at the level
--- whose key is that key, compared as read_key compares: with mod read as
--- platform ({mod, edit}, or nil for ctrl) reads it. With no keys it is
--- the top level. nil when the keys reach no group, or tree is nil.
function M.menu_level_of(tree, platform, seq)
	if not tree then
		return nil
	end
	local items = tree.items
	for _, key in ipairs(seq or {}) do
		local typed_ = M.read_key(platform, key)
		if not typed_ then
			return nil
		end
		local next_
		for _, it in ipairs(items) do
			if it.items and #it.items > 0 and M.read_key(platform, it.key or "") == typed_ then
				next_ = it
				break
			end
		end
		if not next_ then
			return nil
		end
		items = next_.items
	end
	return items
end

--- The first item of tree named name, depth first (SPEC §10.7), or nil: a
--- pick of name is for it. An item with no name, as name "" asks for, is
--- never found.
function M.menu_find(tree, name)
	if not tree or name == nil or name == "" then
		return nil
	end
	local function find_in(items)
		for _, it in ipairs(items or {}) do
			if it.name == name then
				return it
			end
			local f = find_in(it.items)
			if f then
				return f
			end
		end
		return nil
	end
	return find_in(tree.items)
end

-- Decoder (SDK.md §3.6) ---------------------------------------------------------

M.NOT_HOTTY = "not_hotty"
M.PARTIAL = "partial"
M.COMPLETE = "complete"
M.INVALID = "invalid"

-- A control as SPEC §3.2 has it: key=value pairs separated by ":", each key
-- once, each value printable ASCII but ":", ";" and "=". nil when it is not
-- one. Returns the values by key, and the keys in order.
local function parse_control(s)
	if s == "" then
		return nil
	end
	local values, keys = {}, {}
	for part in (s .. ":"):gmatch("([^:]*):") do
		local k, v = part:match("^([A-Za-z][A-Za-z0-9_%-]*)=([ -9<>-~]*)$")
		if not k or values[k] ~= nil then
			return nil
		end
		values[k] = v
		keys[#keys + 1] = k
	end
	return values, keys
end

local Decoder = {}
Decoder.__index = Decoder
M.Decoder = Decoder

--- A decoder's max when it sets none: 16 MiB, enough for a document with
--- its images inline, and a bound on what a peer can make a decoder hold.
M.DEFAULT_MAX = 16 * 1024 * 1024

-- The most base64 a payload of max bytes is sent as: zlib may make it a
-- little longer than it decodes to.
local function encoded_max(max)
	return math.ceil((max + math.floor(max / 256) + 64) / 3) * 4
end

--- A Decoder turns OSC sequences into messages, one at a time, joining
--- chunked ones (SPEC §3.4). invalid counts the malformed messages dropped
--- (SPEC §3.7).
---
--- opts.max is the most bytes a message's payload may decode to, after
--- base64 and zlib; one that would decode to more is invalid, and its
--- chunks are not kept (SPEC §3.4 lets a host limit a message). nil or 0 is
--- M.DEFAULT_MAX. A host sets it to what it accepts from a program, at
--- least 1 MiB.
---
--- opts.inflate, a function from zlib bytes and the max to bytes (nil when
--- they are not zlib, or more than the max), replaces the inflate built in,
--- for a payload marked o=z.
function M.decoder(opts)
	local max = opts and opts.max
	return setmetatable({
		invalid = 0,
		pending = nil,
		max = max and max > 0 and max or M.DEFAULT_MAX,
		inflate = opts and opts.inflate or inflate.zlib,
	}, Decoder)
end

-- Drops the chunked message in progress, counted unless it was already,
-- when it passed max.
function Decoder:abort()
	if self.pending and not self.pending.over then
		self.invalid = self.invalid + 1
	end
	self.pending = nil
end

function Decoder:bad()
	self:abort()
	self.invalid = self.invalid + 1
	return M.INVALID, nil
end

-- A payload that decodes to more than max bytes is refused, and inflating
-- stops past it.
function Decoder:finish(values, keys, b64)
	local payload = #b64 <= encoded_max(self.max) and base64.decode(b64) or nil
	if payload and values.o == "z" then
		payload = self.inflate(payload, self.max)
	end
	if not payload or #payload > self.max then
		self.invalid = self.invalid + 1
		return M.INVALID, nil
	end
	local kept = {}
	for _, k in ipairs(keys) do
		if k ~= "m" and k ~= "o" then
			kept[#kept + 1] = k
		end
	end
	values.m, values.o = nil, nil
	return M.COMPLETE, message(values, kept, payload)
end

--- Takes one OSC sequence, ESC ] …, with or without its terminator (ST or
--- BEL), and returns its result (not_hotty, partial, complete, invalid) and,
--- when complete, the message.
function Decoder:feed(seq)
	if sub(seq, 1, #HEAD) ~= HEAD or find(seq, "^%d", #HEAD + 1) then
		return M.NOT_HOTTY, nil
	end
	local body = sub(seq, #HEAD + 1)
	if sub(body, -2) == ST then
		body = sub(body, 1, -3)
	elseif sub(body, -1) == "\7" then
		body = sub(body, 1, -2)
	end
	if sub(body, 1, 1) ~= ";" or find(body, "[\128-\255]") then
		return self:bad()
	end
	local semi = find(body, ";", 2, true)
	local ctl = sub(body, 2, semi and semi - 1 or -1)
	local b64 = semi and sub(body, semi + 1) or ""
	local values, keys = parse_control(ctl)
	if not values then
		return self:bad()
	end
	local only_mq = values.m ~= nil
	for _, k in ipairs(keys) do
		if k ~= "m" and k ~= "q" then
			only_mq = false
		end
	end
	if only_mq then
		-- A continuation: only m, and q.
		if not self.pending or (values.m ~= "0" and values.m ~= "1") then
			return self:bad()
		end
		local p = self.pending
		if not p.over and p.size + #b64 > encoded_max(self.max) then
			-- Too long: counted once, and its chunks dropped as they come.
			p.pieces, p.over = {}, true
			self.invalid = self.invalid + 1
		end
		if not p.over then
			p.pieces[#p.pieces + 1] = b64
			p.size = p.size + #b64
		end
		if values.m == "1" then
			return M.PARTIAL, nil
		end
		self.pending = nil
		if p.over then
			return M.INVALID, nil
		end
		return self:finish(p.values, p.keys, join(p.pieces))
	end
	-- Another message before the last chunk aborts the one in progress.
	self:abort()
	if values.m == "1" then
		local over = #b64 > encoded_max(self.max)
		if over then
			self.invalid = self.invalid + 1
		end
		self.pending =
			{ values = values, keys = keys, pieces = over and {} or { b64 }, size = over and 0 or #b64, over = over }
		return M.PARTIAL, nil
	end
	if values.m ~= nil and values.m ~= "0" then
		return self:bad()
	end
	return self:finish(values, keys, b64)
end

-- Scanner (SDK.md §3.7) ---------------------------------------------------------

local GROUND, OSC, DISCARD = 0, 1, 2
local DA1_PREFIX = ESC .. "[?"

local Scanner = {}
Scanner.__index = Scanner
M.Scanner = Scanner

--- A Scanner cuts HOTTY sequences out of a byte stream, however its reads
--- split it. With opts.da1, it also cuts out answers to Primary Device
--- Attributes. invalid counts the sequences it dropped.
function M.scanner(opts)
	return setmetatable({
		da1 = opts and opts.da1 or false,
		invalid = 0,
		mode = GROUND,
		held = "", -- a prefix of a segment, in GROUND
		parts = {}, -- the HOTTY sequence in progress, in OSC
		len = 0, -- its length
		esc = false, -- the last byte in OSC or DISCARD was ESC
	}, Scanner)
end

--- The bytes held for the next feed.
function Scanner:holding()
	if self.mode == OSC then
		return join(self.parts) .. (self.esc and ESC or "")
	end
	return self.held
end

--- Whether a HOTTY sequence is in progress, or one too long is being
--- dropped: the next feed goes on with it, and flush would drop it.
--- Otherwise what holding returns is the start of a segment, which a
--- program reading keys may flush after a moment, as typing.
function Scanner:in_sequence()
	return self.mode ~= GROUND
end

local function push(out, kind, data)
	local last = out[#out]
	if kind == "pass" and last and last.kind == "pass" then
		last.data = last.data .. data
	elseif data ~= "" then
		out[#out + 1] = { kind = kind, data = data }
	end
end

function Scanner:osc_start()
	self.mode, self.held, self.parts, self.len, self.esc = OSC, "", { PREFIX }, #PREFIX, false
end

function Scanner:osc_end(out, terminator)
	self.parts[#self.parts + 1] = terminator
	push(out, "osc", join(self.parts))
	self.mode, self.parts, self.len = GROUND, {}, 0
end

-- One byte in GROUND, with self.held the prefix of a segment so far.
function Scanner:ground(c, out)
	if self.held ~= "" then
		local cand = self.held .. c
		if sub(PREFIX, 1, #cand) == cand then
			if cand == PREFIX then
				self:osc_start()
			else
				self.held = cand
			end
			return
		end
		if self.da1 and self:da1_step(cand, out) then
			return
		end
		push(out, "pass", self.held)
		self.held = ""
	end
	if c == ESC then
		self.held = c
		return
	end
	push(out, "pass", c)
end

function Scanner:da1_step(cand, out)
	if sub(DA1_PREFIX, 1, #cand) == cand then
		self.held = cand
		return true
	end
	if sub(cand, 1, #DA1_PREFIX) == DA1_PREFIX then
		local last = sub(cand, -1)
		if last == "c" then
			push(out, "da1", cand)
			self.held = ""
			return true
		end
		if find(last, "^[%d;]$") then
			self.held = cand
			return true
		end
	end
	return false
end

-- One byte, whatever the mode.
function Scanner:byte(c, out)
	if self.mode == DISCARD then
		-- A HOTTY sequence longer than SCAN_MAX, dropped up to its end.
		if self.esc then
			self.esc = false
			self.mode = GROUND
			if c ~= "\\" then
				self.held = ESC -- an ESC that is not ST begins what follows
				self:ground(c, out)
			end
		elseif c == "\7" then
			self.mode = GROUND
		elseif c == ESC then
			self.esc = true
		end
		return
	end
	if self.mode == OSC then
		if self.esc then
			self.esc = false
			if c == "\\" then
				self:osc_end(out, ST)
				return
			end
			-- ESC without \ ends the sequence unfinished: it is dropped, and
			-- the ESC begins what follows.
			self.invalid = self.invalid + 1
			self.mode, self.parts, self.len, self.held = GROUND, {}, 0, ESC
			self:ground(c, out)
			return
		end
		if c == "\7" then
			self:osc_end(out, c)
			return
		end
		if c == ESC then
			-- Perhaps the terminator, which the limit does not count.
			self.esc = true
			return
		end
		if self.len >= M.SCAN_MAX then
			self.invalid = self.invalid + 1
			self.mode, self.parts, self.len = DISCARD, {}, 0
			return
		end
		self.parts[#self.parts + 1] = c
		self.len = self.len + 1
		return
	end
	self:ground(c, out)
end

--- Takes the next bytes of the stream, and returns segments, in order:
--- {kind = "pass", data = …} for bytes that are not HOTTY's, unchanged;
--- {kind = "osc", data = …} for one complete HOTTY sequence; and with the
--- da1 option, {kind = "da1", data = …} for a DA1 answer. Adjacent pass
--- segments are merged.
function Scanner:feed(data)
	local out = {}
	local i, n = 1, #data
	while i <= n do
		if self.mode == GROUND and self.held == "" then
			-- Everything up to the next ESC passes.
			local j = find(data, ESC, i, true)
			if not j then
				push(out, "pass", sub(data, i))
				break
			end
			if j > i then
				push(out, "pass", sub(data, i, j - 1))
			end
			self.held = ESC
			i = j + 1
		elseif (self.mode == OSC or self.mode == DISCARD) and not self.esc then
			-- Bytes up to the next BEL or ESC belong to the sequence.
			local j = find(data, "[\7\27]", i)
			local stop = j and j - 1 or n
			if stop >= i then
				if self.mode == OSC then
					local room = M.SCAN_MAX - self.len
					if stop - i + 1 > room then
						-- The byte after room is the one too many.
						if room > 0 then
							self.parts[#self.parts + 1] = sub(data, i, i + room - 1)
						end
						self.invalid = self.invalid + 1
						self.mode, self.parts, self.len, self.esc = DISCARD, {}, 0, false
						stop = i + room
					else
						self.parts[#self.parts + 1] = sub(data, i, stop)
						self.len = self.len + stop - i + 1
					end
				end
				i = stop + 1
			else
				self:byte(sub(data, i, i), out)
				i = i + 1
			end
		else
			self:byte(sub(data, i, i), out)
			i = i + 1
		end
	end
	return out
end

--- Ends the stream: what is held goes out as pass, except a HOTTY sequence
--- in progress, which is dropped as malformed.
function Scanner:flush()
	local out = {}
	if self.mode == OSC then
		self.invalid = self.invalid + 1
	elseif self.mode == GROUND and self.held ~= "" then
		push(out, "pass", self.held)
	end
	self.mode, self.held, self.parts, self.len, self.esc = GROUND, "", {}, 0, false
	return out
end

-- Detector (SDK.md §3.8) --------------------------------------------------------

M.DETECTING = "detecting"
M.NATIVE = "native"
M.TEXT = "text"

M.DETECT_TIMEOUT = 1500 -- ms: no answer at all
M.DETECT_AFTER_DA1 = 150 -- ms: a DA1 before any reply may answer an earlier question
M.DETECT_AFTER_REPLY = 300 -- ms: the DA1 behind the reply

local Detector = {}
Detector.__index = Detector
M.Detector = Detector

--- A Detector decides whether the terminal is a host, with the time passed
--- in, in milliseconds. opts.n is the query's number (1). A reply to the
--- query makes the terminal a host when it is ok and its capabilities decode
--- and name VERSION; any other reply to it, an error (EVERSION or another)
--- included, makes it text at once (SPEC §4). opts.late asks for a late
--- answer: once the state is text, the first reply to the query that would
--- make the terminal a host makes it one after all.
---
--- It exposes state (detecting, native or text), caps (the host's, when
--- native), decided, done, and deadline: when to call tick next, or nil
--- once done.
function M.detector(opts)
	return setmetatable({
		n = opts and opts.n or 1,
		late = opts and opts.late or false,
		state = M.DETECTING,
		caps = nil,
		decided = false,
		done = false,
		deadline = nil,
	}, Detector)
end

function Detector:update()
	if self.done or not self.timeout then
		self.deadline = nil
	elseif self.state == M.DETECTING then
		self.deadline = self.grace and math.min(self.timeout, self.grace) or self.timeout
	else
		self.deadline = self.after
	end
end

-- Whatever was due at or before now happens.
function Detector:fire(now)
	if self.done or not self.timeout then
		return
	end
	if self.state == M.DETECTING then
		if now >= self.timeout or (self.grace and now >= self.grace) then
			self.state, self.decided, self.done = M.TEXT, true, true
		end
	elseif now >= self.after then
		self.done = true
	end
end

--- Starts detection, and returns the query to send.
function Detector:start(now)
	self.timeout = now + M.DETECT_TIMEOUT
	self:update()
	return M.query(self.n, { late = self.late })
end

--- The time is now.
function Detector:tick(now)
	self:fire(now)
	self:update()
end

--- A DA1 answer arrived. Returns whether it was detection's.
function Detector:da1(now)
	self:fire(now)
	local took = false
	if not self.done then
		took = true
		if self.state == M.DETECTING then
			self.grace = self.grace or (now + M.DETECT_AFTER_DA1)
		else
			self.done = true
		end
	end
	self:update()
	return took
end

--- A reply arrived (a Reply). Returns whether it answers the query, ok or
--- an error: then it is detection's, whenever it arrives.
function Detector:reply(r, now)
	self:fire(now)
	local took = false
	if r and r.re == "q" and r.n == self.n then
		took = true
		-- A host this program can use: its capabilities decode, in the
		-- version the query listed. An error, capabilities that do not decode
		-- (a 0.1 host's JSON) or that name another version, or none, are no
		-- host it can use.
		local caps = r:caps()
		if caps and caps.v ~= M.VERSION then
			caps = nil
		end
		if self.state == M.DETECTING then
			self.state, self.decided = caps and M.NATIVE or M.TEXT, true
			self.caps = caps
			self.after = math.min(now + M.DETECT_AFTER_REPLY, self.timeout)
		elseif self.state == M.TEXT and self.late and caps then
			-- A late answer: a host after all. Decided and done stay so.
			self.state, self.caps = M.NATIVE, caps
		end
	end
	self:update()
	return took
end

--- The input ended, or the caller gave up: SDK.md's End, which is a keyword
--- in Lua. Detector["end"] is the same.
function Detector:finish(now)
	self:fire(now)
	if not self.decided then
		self.state, self.decided = M.TEXT, true
	end
	self.done = true
	self:update()
end
Detector["end"] = Detector.finish

-- Keys (SDK.md §3.10) ------------------------------------------------------------

local keys = require("hotty.keys")

M.keys = keys
M.MODIFIERS = keys.MODIFIERS
M.ACTIONS = keys.ACTIONS
M.MULTILINE_ACTIONS = keys.MULTILINE_ACTIONS
M.SCROLL_ACTIONS = keys.SCROLL_ACTIONS
M.MOVES = keys.MOVES
M.INSERT = keys.INSERT
M.TERMINAL_KEYS = keys.TERMINAL_KEYS
M.parse_key = keys.parse_key
M.key_text = keys.key_text
M.decode_keys = keys.decode_keys
M.keymap = keys.keymap
M.parse_keymap = keys.parse_keymap
M.resolve = keys.resolve
M.platform_of = keys.platform_of
M.read_key = keys.read_key
M.default_edit = keys.default_edit

-- A field in cells (SDK.md §4.6) --------------------------------------------------

M.field = require("hotty.field").new

return M
