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
local json = require("hotty.json")
local inflate = require("hotty.inflate")

local byte, char, sub, find, format, rep = string.byte, string.char, string.sub, string.find, string.format, string.rep
local floor = math.floor
local concat, insert = table.concat, table.insert
local join = require("hotty.join")

local M = {}

M.base64 = base64
M.json = json

-- Constants (SDK.md §3.1) -----------------------------------------------------

M.NUMBER = "7279" -- the OSC number
M.CHUNK = 4096 -- the most base64 bytes in one sequence
M.MAX_SIZE = 1000 -- the most columns or rows of a surface
M.MAX_NAME = 64 -- the longest surface name
M.VERSION = "0.1" -- the protocol version this SDK implements
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
M.EVENT_RESIZE = "resize"
M.EVENT_FIT = "fit"
M.EVENT_HOVER = "hover"
M.EVENT_DRAG_START = "dragstart"
M.EVENT_DRAG = "drag"
M.EVENT_DRAG_END = "dragend"
M.EVENTS = {
	"click",
	"change",
	"input",
	"submit",
	"press",
	"focus",
	"blur",
	"resize",
	"fit",
	"hover",
	"dragstart",
	"drag",
	"dragend",
}

-- Error codes (SPEC §3.6).
M.EINVAL = "EINVAL"
M.ENOENT = "ENOENT"
M.ENOTARGET = "ENOTARGET"
M.EDETACHED = "EDETACHED"
M.EQUOTA = "EQUOTA"
M.EBUDGET = "EBUDGET"
M.CODES = { "EINVAL", "ENOENT", "ENOTARGET", "EDETACHED", "EQUOTA", "EBUDGET" }

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
M.OPS =
	{ "morph", "inner", "replace", "append", "prepend", "before", "after", "remove", "attr", "unattr", "text", "var" }

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

local utf8_len = json.utf8_len

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
--- left out. payload is a string of bytes, or nil.
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
	local parts, quiet = {}, nil
	for _, p in ipairs(control_pairs(control)) do
		if p[1] ~= "o" and p[1] ~= "m" then -- Encode's to set
			local v = M.clean_value(p[2])
			parts[#parts + 1] = p[1] .. "=" .. v
			if p[1] == "q" then
				quiet = v
			end
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
	local tail = quiet and (":q=" .. quiet) or ""
	for i = 1, #b64, M.CHUNK do
		local piece = sub(b64, i, i + M.CHUNK - 1)
		if i == 1 then
			out[#out + 1] = PREFIX .. ctl .. ":m=1;" .. piece .. ST
		else
			local more = (i + M.CHUNK > #b64) and "0" or "1"
			out[#out + 1] = PREFIX .. "m=" .. more .. tail .. ";" .. piece .. ST
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
-- the order (SDK.md §3.4.2).
local function command(pairs_, payload, default_q, opts)
	local n, q = opts and opts.n, opts and opts.q
	if n ~= nil then
		pairs_[#pairs_ + 1] = { "n", int(n) }
	end
	if q == nil then
		q = n ~= nil and M.REPLY_ALWAYS or default_q
	end
	pairs_[#pairs_ + 1] = { "q", int(q) }
	return M.encode(pairs_, payload, opts)
end

--- Asks whether the terminal is a host: a=q with n (1 if nil), fenced by
--- DA1 (SPEC §4). opts.late asks for a late answer (late=1): what stands
--- between the program and the terminal may answer once there is a host.
function M.query(n, opts)
	local p = { { "a", "q" }, { "n", int(n or 1) } }
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
	if pl.press then
		p[#p + 1] = { "p", "1" }
	end
	if pl.fit then
		p[#p + 1] = { "f", "1" }
	end
	if pl.hover then
		p[#p + 1] = { "v", "1" }
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

--- Changes a surface's document (SPEC §6.1). target and key are sent only
--- when given (not nil or ""). opts: n, q (default 2).
function M.delta(surface, op, target, key, payload, opts)
	local p = { { "a", "delta" }, { "s", surface }, { "op", op } }
	if target and target ~= "" then
		p[#p + 1] = { "t", target }
	end
	if key and key ~= "" then
		p[#p + 1] = { "k", key }
	end
	return command(p, payload, M.NO_REPLY, opts)
end

--- Replaces the target's children with one text node: op=text.
function M.set_text(surface, target, text, opts)
	return M.delta(surface, "text", target, nil, text, opts)
end

--- Sets the custom property --name on the target: op=var.
function M.set_var(surface, target, name, value, opts)
	return M.delta(surface, "var", target, name, tostring(value), opts)
end

--- Sets the target's attribute name: op=attr.
function M.set_attr(surface, target, name, value, opts)
	return M.delta(surface, "attr", target, name, tostring(value), opts)
end

--- Removes the target's attribute name: op=unattr, no payload.
function M.remove_attr(surface, target, name, opts)
	return M.delta(surface, "unattr", target, name, nil, opts)
end

--- Morphs the target into html: op=morph with a target.
function M.morph_to(surface, target, html, opts)
	return M.delta(surface, "morph", target, nil, html, opts)
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

local function is_num(v)
	return type(v) == "number" and v == v
end

local function is_int(v)
	return is_num(v) and v == floor(v) and v > -math.huge and v < math.huge
end

local function to_int(s)
	if type(s) == "string" and find(s, "^%-?%d+$") then
		return tonumber(s)
	end
	return nil
end

local function str(v)
	return type(v) == "string" and v or nil
end

local Error = {}
Error.__index = Error
Error.__tostring = function(e)
	local s = "hotty: " .. (e.code or "")
	if e.detail and e.detail ~= "" then
		s = s .. ": " .. e.detail
	end
	if e.re then
		s = s .. " (re=" .. e.re .. (e.surface and (", s=" .. e.surface) or "") .. ")"
	end
	return s
end
M.Error = Error

--- An error: a code (EINVAL, ENOENT, …) and a detail, and the action and
--- surface it answers when known. tostring names them.
function M.error(code, detail, re, surface)
	return setmetatable({ code = code, detail = detail, re = re, surface = surface }, Error)
end

local Message = {}
Message.__index = Message
M.Message = Message

local function message(control, keys, payload)
	return setmetatable({ control = control, keys = keys, payload = payload }, Message)
end

--- The payload read as JSON, or nil.
function Message:json()
	if self.payload == "" then
		return nil
	end
	if self._json == nil then
		local v = json.decode(self.payload)
		self._json = v == nil and false or v
	end
	return self._json or nil
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
	}, Reply)
	if not r.ok then
		local body = self:json()
		if json.is_object(body) then
			r.code = str(body.code)
			r.detail = str(body.detail)
		end
	end
	return r
end

local Caps = {}
Caps.__index = Caps
M.Caps = Caps

--- The capabilities a reply to a query carries, or nil.
function Reply:caps()
	if not self.ok or self.re ~= "q" then
		return nil
	end
	local d = self.message:json()
	return M.caps(json.is_object(d) and d or {})
end

--- The reply as an error, or nil when it is ok.
function Reply:err()
	if self.ok then
		return nil
	end
	return M.error(self.code or "", self.detail, self.re, self.surface)
end

local Event = {}
Event.__index = Event
M.Event = Event

--- The message as an event (SPEC §9), or nil if it is not one.
function Message:event()
	local c = self.control
	if c.a ~= "ev" then
		return nil
	end
	local d = self:json()
	return setmetatable({
		message = self,
		surface = c.s,
		kind = c.e,
		target = c.t or "",
		detail = json.is_object(d) and d or {},
	}, Event)
end

--- The detail's value, a string: click, change, input.
function Event:value()
	return str(self.detail.value)
end

--- The detail's checked, a boolean: change.
function Event:checked()
	local v = self.detail.checked
	if type(v) == "boolean" then
		return v
	end
	return nil
end

--- A submit's fields by name: a string as it is, any other value as its
--- JSON, a null left out.
function Event:fields()
	if self.kind ~= M.EVENT_SUBMIT then
		return nil
	end
	local out = {}
	for k, v in pairs(self.detail) do
		if type(v) == "string" then
			out[k] = v
		elseif v ~= json.null then
			out[k] = json.encode(v)
		end
	end
	return out
end

--- A link's click: its href, and its url, or nil when there is none.
function Event:link()
	local href = self.detail.href
	if self.kind ~= M.EVENT_CLICK or type(href) ~= "string" then
		return nil
	end
	return href, str(self.detail.url)
end

--- A resize's w and h, in CSS pixels.
function Event:size()
	local w, h = self.detail.w, self.detail.h
	if self.kind ~= M.EVENT_RESIZE or not (is_num(w) and is_num(h)) then
		return nil
	end
	return w, h
end

--- A fit's rows.
function Event:fit_rows()
	local r = self.detail.r
	if self.kind ~= M.EVENT_FIT or not is_int(r) then
		return nil
	end
	return r
end

--- A drag's cell and the keys held: {c, r, keys}, and its steps x and y
--- for an element with data-steps (SPEC §9.1), each nil when the detail
--- has none or one that is not a whole number; 0 is a step like any other.
function Event:drag()
	local k = self.kind
	if k ~= M.EVENT_DRAG_START and k ~= M.EVENT_DRAG and k ~= M.EVENT_DRAG_END then
		return nil
	end
	local c, r, keys = self.detail.c, self.detail.r, self.detail.keys
	if not (is_int(c) and is_int(r)) then
		return nil
	end
	local out = {}
	if json.is_array(keys) then
		for _, key in ipairs(keys) do
			if type(key) == "string" then
				out[#out + 1] = key
			end
		end
	end
	local x, y = self.detail.x, self.detail.y
	return { c = c, r = r, keys = out, x = is_int(x) and x or nil, y = is_int(y) and y or nil }
end

--- A hover's cell, {c, r, out = false}, or {out = true} when the pointer
--- left.
function Event:hover()
	if self.kind ~= M.EVENT_HOVER then
		return nil
	end
	if self.detail.out == true then
		return { out = true }
	end
	local c, r = self.detail.c, self.detail.r
	if not (is_int(c) and is_int(r)) then
		return nil
	end
	return { c = c, r = r, out = false }
end

--- A click's or a press's element, in cells from the surface's top left
--- cell: {c, r, w, h} (SPEC §9).
function Event:area()
	if self.kind ~= M.EVENT_CLICK and self.kind ~= M.EVENT_PRESS then
		return nil
	end
	local a = self.detail.area
	if not json.is_object(a) then
		return nil
	end
	local c, r, w, h = a.c, a.r, a.w, a.h
	if not (is_int(c) and is_int(r) and is_int(w) and is_int(h)) then
		return nil
	end
	return { c = c, r = r, w = w, h = h }
end

local function strings(v)
	local out = {}
	if json.is_array(v) then
		for _, s in ipairs(v) do
			if type(s) == "string" then
				out[#out + 1] = s
			end
		end
	end
	return out
end

--- What a host says about itself (SPEC §4), from its JSON object. Each field
--- is read on its own: one of an unexpected type is ignored, as one the
--- program does not know is.
function M.caps(d)
	local c = setmetatable({ raw = d }, Caps)
	c.v = str(d.v) or ""
	c.ops = strings(d.ops)
	c.events = strings(d.events)
	if json.is_object(d.cell) and is_num(d.cell.w) and is_num(d.cell.h) then
		c.cell = { w = d.cell.w, h = d.cell.h }
	end
	c.scale = is_num(d.scale) and d.scale or nil
	c.scheme = str(d.scheme) or ""
	c.limits = {}
	if json.is_object(d.limits) then
		for k, v in pairs(d.limits) do
			if is_int(v) then
				c.limits[k] = v
			end
		end
	end
	c.net = {}
	if json.is_object(d.net) then
		for k, v in pairs(d.net) do
			if json.is_array(v) then
				c.net[k] = strings(v)
			end
		end
	end
	c.passthrough = d.passthrough == true
	c.scroll = d.scroll == true
	c.steps = d.steps == true
	c.host = str(d.host)
	c.version = str(d.version)
	return c
end

local function has(list, v)
	for _, x in ipairs(list) do
		if x == v then
			return true
		end
	end
	return false
end

--- Whether the host supports a delta op; one that lists none supports all.
function Caps:supports(op)
	return #self.ops == 0 or has(self.ops, op)
end

--- Whether the host sends an event kind; one that lists none sends all.
--- drag stands for dragstart, drag and dragend.
function Caps:sends(kind)
	if kind == M.EVENT_DRAG_START or kind == M.EVENT_DRAG_END then
		kind = M.EVENT_DRAG
	end
	return #self.events == 0 or has(self.events, kind)
end

--- Whether the host lists drag. One that lists no events does not: drags
--- came after the first hosts.
function Caps:drags()
	return has(self.events, M.EVENT_DRAG)
end

--- Whether the host lists hover. One that lists no events does not.
function Caps:hovers()
	return has(self.events, M.EVENT_HOVER)
end

--- Whether the terminal's scheme is light.
function Caps:light()
	return self.scheme == "light"
end

--- A cell's size in CSS pixels: cell divided by scale (1 when absent), and
--- a usual 9 x 18 when the host gave no cell.
function Caps:cell_css()
	local s = (self.scale and self.scale > 0) and self.scale or 1
	if not self.cell or self.cell.w <= 0 or self.cell.h <= 0 then
		return 9, 18
	end
	return self.cell.w / s, self.cell.h / s
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

--- A Decoder turns OSC sequences into messages, one at a time, joining
--- chunked ones (SPEC §3.4). invalid counts the malformed messages dropped
--- (SPEC §3.7).
---
--- opts.inflate, a function from zlib bytes to bytes (nil when they are not
--- zlib), replaces the inflate built in, for a payload marked o=z.
function M.decoder(opts)
	return setmetatable({ invalid = 0, pending = nil, inflate = opts and opts.inflate or inflate.zlib }, Decoder)
end

function Decoder:bad()
	if self.pending then
		self.pending = nil
		self.invalid = self.invalid + 1
	end
	self.invalid = self.invalid + 1
	return M.INVALID, nil
end

function Decoder:finish(values, keys, b64)
	local payload = base64.decode(b64)
	if payload and values.o == "z" then
		payload = self.inflate(payload)
	end
	if not payload then
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
		p.pieces[#p.pieces + 1] = b64
		if values.m == "1" then
			return M.PARTIAL, nil
		end
		self.pending = nil
		return self:finish(p.values, p.keys, join(p.pieces))
	end
	if self.pending then
		-- Another message before the last chunk aborts the one in progress.
		self.pending = nil
		self.invalid = self.invalid + 1
	end
	if values.m == "1" then
		self.pending = { values = values, keys = keys, pieces = { b64 } }
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
--- in, in milliseconds. opts.n is the query's number (1); opts.late asks for
--- a late answer (SPEC §4), and the first reply to the query once the state
--- is text makes the terminal a host after all.
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

--- A reply arrived (a Reply). Returns whether it answers the query.
function Detector:reply(r, now)
	self:fire(now)
	local took = false
	if r and r.ok and r.re == "q" and r.n == self.n then
		took = true
		if self.state == M.DETECTING then
			self.state, self.decided = M.NATIVE, true
			self.caps = r:caps()
			self.after = math.min(now + M.DETECT_AFTER_REPLY, self.timeout)
		elseif self.state == M.TEXT and self.late then
			-- A late answer: a host after all. Decided and done stay so.
			self.state, self.caps = M.NATIVE, r:caps()
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
M.INSERT = keys.INSERT
M.TERMINAL_KEYS = keys.TERMINAL_KEYS
M.parse_key = keys.parse_key
M.decode_keys = keys.decode_keys
M.keymap = keys.keymap
M.parse_keymap = keys.parse_keymap
M.resolve = keys.resolve

-- A field in cells (SDK.md §4.6) --------------------------------------------------

M.field = require("hotty.field").new

return M
