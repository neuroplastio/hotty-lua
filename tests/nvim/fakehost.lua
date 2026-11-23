-- A fake host, for tests of hotty.nvim (the test host of SDK.md §4.4, as
-- small as those tests need). It reads what a Neovim writes to its terminal
-- and answers as a terminal and a hotty host would:
--
--   - the terminal: DA1, the status and cursor reports (DSR 5n and 6n), synchronized output's
--     DECRQM, the background colour; it follows the cursor through CUP and
--     ESC 7 / ESC 8, so it knows where each placement lands, and an erase in
--     display (ED 2 or 3) drops every placement, as hottyterm does;
--   - the host (when native): the query, answered in the highest version it
--     shares with the query (versions, "0.9" and "0.8"; version names one) or
--     with EVERSION, and every command, kept as
--     surfaces and placements, with replies as SPEC §3.6 has them. It lays
--     nothing out: r=auto gets auto_rows;
--   - not a host, a multiplexer's pane with no terminal attached: it holds a
--     query that asks for a late answer (SPEC §4), until another query takes
--     its place, and become_host answers it as the host does.
--
-- Strict: malformed messages, EINVAL and commands sent before a host attaches
-- fail the test. Lenient hosts keep these problems for inspection.

local hotty = require("hotty")
local mp = require("msgpack_writer")
local document = require("document")
local utf8 = require("hotty.utf8")
local input = require("userinput")

local M = {}
local Host = {}
Host.__index = Host

-- The capabilities, v the version answered.
local function caps_in(v)
	return mp.pack({
		v = v,
		cellcss = { w = mp.float(9), h = mp.float(18) },
		scale = mp.float(1),
		features = mp.array({}),
		scheme = "dark",
		-- message: the limit its decoder keeps (SPEC §13).
		limits = { surfaces = 64, message = hotty.DEFAULT_MAX },
		host = "fake",
		version = "0.0.1",
	})
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		native = opts.native ~= false,
		lenient = opts.lenient == true,
		-- the versions it speaks, highest first; the session's is the one it answered
		versions = opts.version and { opts.version } or opts.versions or { "0.9", "0.8" },
		session = nil,
		caps = opts.caps,
		platform = opts.platform,
		auto_rows = opts.auto_rows or 4,
		scanner = hotty.scanner(),
		decoder = hotty.decoder(),
		carry = "", -- the start of a terminal sequence, cut by a read
		cursor = { x = 0, y = 0 },
		saved = { x = 0, y = 0 },
		docs = {}, -- surface to { html, detached }
		placements = {}, -- surface to { x, y, c, r, window, z, p, f, v, C }
		resources = {},
		touch = { main = {}, alternate = {} },
		screen = "main",
		flags = {}, -- surface to { p, f, v }: they belong to the surface (SPEC §5.2)
		log = {}, -- every hotty command, in order: { a, s, control, payload }
		queries = 0,
		held = nil, -- the n of a query held for a late answer
		held_query = nil, -- its control
		withdrawn = 0, -- queries that took a held one's place and wanted no answer
		problems = {},
	}, Host)
end

local function reply(ctl, payload)
	return hotty.encode(ctl, payload)
end

-- The quiet level of a command (SPEC §3.5): its q, else 0 with n and 1
-- without.
local function quiet(c)
	return tonumber(c.q or ((c.n or c.a == "q" or c.a == "hit") and "0" or "1")) or 1
end

function Host:problem(problem)
	self.problems[#self.problems + 1] = problem
	if not self.lenient then
		error(problem)
	end
end

-- Answers a command as SPEC §3.6 has hosts do: an error unless q is 2, an ok
-- only when q is 0.
function Host:answer(m, err, extra, detail, body)
	if err == "EINVAL" then
		self:problem("invalid " .. (m.control.a or "command") .. ": " .. (detail or ""))
	end
	local q = quiet(m.control)
	local ctl = { { "a", err and "err" or "ok" } }
	if m.control.n then
		ctl[#ctl + 1] = { "n", m.control.n }
	end
	if m.control.s then
		ctl[#ctl + 1] = { "s", m.control.s }
	end
	ctl[#ctl + 1] = { "re", m.control.a or "" }
	for _, kv in ipairs(extra or {}) do
		ctl[#ctl + 1] = kv
	end
	if err then
		if q >= 2 then
			return ""
		end
		return reply(ctl, mp.pack({ code = err, detail = detail or m.control.s or "" }))
	end
	if q ~= 0 then
		return ""
	end
	return reply(ctl, body)
end

-- The highest of versions that v, the versions a query lists, comma-separated,
-- also lists, or nil.
local function shared(v, versions)
	local listed = {}
	for entry in ((v or "") .. ","):gmatch("([^,]*),") do
		listed[entry] = true
	end
	for _, version in ipairs(versions) do
		if listed[version] then
			return version
		end
	end
	return nil
end

-- Answers a query as a host does (SPEC §4): its capabilities, v the highest
-- version the query shares with it, which is the session's from then on, and
-- EVERSION, the versions it speaks (highest first, comma-separated) as its
-- detail, when it shares none; an error unless q is 2, an ok only when q is 0.
-- It lays nothing out, in either version of a session (SDK.md §4.4).
function Host:query_reply(c)
	local q = tonumber(c.q or "0") or 0
	local version = shared(c.v, self.versions)
	if q >= 2 or (version and q ~= 0) then
		return ""
	end
	local ctl = { { "a", version and "ok" or "err" } }
	if c.n then
		ctl[#ctl + 1] = { "n", c.n }
	end
	ctl[#ctl + 1] = { "re", "q" }
	if version then
		self.session = version
		return reply(ctl, self.caps or caps_in(version))
	end
	return reply(ctl, mp.pack({ code = "EVERSION", detail = table.concat(self.versions, ",") }))
end

function Host:cancel_pointer(surface, report)
	local down = self.pointer_button
	if not down or down.surface ~= surface then
		return ""
	end
	self.pointer_button = nil
	if report and down.moving then
		local last = down.last_cell or down.start
		return self:event(surface, "dragend", nil, { c = last.c, r = last.r, mods = last.mods, x = last.x, y = last.y })
	end
	return ""
end

local function decimal(value)
	if value and value:match("^%-?%d+$") then
		return tonumber(value)
	end
end

local function bounded(value, min, max)
	return value and value >= min and value <= max
end

local function touch_areas(message)
	if message.payload == "" then
		return {}
	end
	local body, kinds = message:body()
	if not body or not kinds[body] or kinds[body].areas ~= "array" or #body.areas > hotty.TOUCH_MAX then
		return nil
	end
	local area_marks = kinds[body.areas]
	if area_marks and next(area_marks) then
		return nil
	end
	for _, area in ipairs(body.areas) do
		if type(area) ~= "table" then
			return nil
		end
		for _, name in ipairs({ "c", "r", "w", "h" }) do
			local min = (name == "c" or name == "r") and 0 or 1
			if type(area[name]) ~= "number" or (kinds[area] and kinds[area][name]) or area[name] < min then
				return nil
			end
		end
		if area.drag ~= "x" and area.drag ~= "y" and area.drag ~= "xy" then
			return nil
		end
	end
	return body.areas
end

function Host:command(m)
	local c = m.control
	local entry = { a = c.a, s = c.s, control = c, payload = m.payload }
	if c.a == "q" then
		if not self.native then
			-- Any query takes a held one's place (SPEC §4).
			self.held = c.late == "1" and (c.n or "") or nil
			self.held_query = self.held and c or nil
			if c.q == "2" then
				self.withdrawn = self.withdrawn + 1
				return ""
			end
			self.queries = self.queries + 1
			return ""
		end
		if c.q == "2" then
			return ""
		end
		self.queries = self.queries + 1
		self.log[#self.log + 1] = entry
		return self:query_reply(c)
	end
	if not self.native then
		self:problem("a hotty command sent to a terminal that is not a host: a=" .. tostring(c.a))
		return ""
	end
	self.log[#self.log + 1] = entry
	local s = c.s
	if s and not hotty.valid_name(s) then
		return self:answer(m, "EINVAL", nil, "s")
	end
	if c.a == "doc" then
		if not s then
			return self:answer(m, "EINVAL", nil, "s")
		elseif not utf8.valid(m.payload) then
			return self:answer(m, "EINVAL", nil, "document is not UTF-8")
		end
		local ended = self:cancel_pointer(s, c.d ~= "1")
		self.docs[s] = { html = m.payload, tree = document.parse(m.payload), detached = c.d == "1" }
		self.flags[s] = self.flags[s] or {}
		if c.d == "1" and self.keyboard == s then
			self.keyboard, self.focused, self.prefix = nil, nil, nil
		end
		return ended .. input.fixup(self, s) .. self:answer(m)
	elseif c.a == "place" then
		if not self.docs[s] then
			return self:answer(m, "ENOENT")
		end
		local cols = decimal(c.c)
		local rows = (c.r == nil or c.r == "auto") and self.auto_rows or decimal(c.r)
		local z = c.z and decimal(c.z) or nil
		if
			not bounded(cols, 1, hotty.MAX_SIZE)
			or not bounded(rows, 1, hotty.MAX_SIZE)
			or (c.z and not bounded(z, -1000, 1000))
		then
			return self:answer(m, "EINVAL", nil, "placement")
		end
		local p = { x = self.cursor.x, y = self.cursor.y, c = cols, r = rows, auto = c.r == nil or c.r == "auto" }
		if c.x or c.y or c.w or c.h then
			local x, y = decimal(c.x or "0"), decimal(c.y or "0")
			local w, h = decimal(c.w) or (not c.w and x and cols - x), decimal(c.h) or (not c.h and y and rows - y)
			if
				not bounded(x, 0, cols - 1)
				or not bounded(y, 0, rows - 1)
				or not bounded(w, 1, cols - x)
				or not bounded(h, 1, rows - y)
			then
				return self:answer(m, "EINVAL", nil, "window")
			end
			p.window = { x = x, y = y, w = w, h = h }
		end
		p.z, p.C = z, c.C == "1"
		-- p, f and v are the surface's: 1 on, 0 off, held; any other value is
		-- as if absent.
		local fl = self.flags[s]
		for key, field in pairs({ p = "press", f = "fit", v = "hover" }) do
			if c[key] == "1" then
				fl[field] = true
			elseif c[key] == "0" then
				fl[field] = false
			end
			p[field] = fl[field] == true
		end
		self.placements[s] = p
		return self:answer(m, nil, { { "c", tostring(cols) }, { "r", tostring(rows) } })
	elseif c.a == "hit" then
		if not self.docs[s] then
			return self:answer(m, "ENOENT")
		end
		for _, key in ipairs({ "c", "r" }) do
			if not c[key] or not c[key]:match("^%-?%d+$") then
				return self:answer(m, "EINVAL")
			end
		end
		if self.docs[s].detached then
			return self:answer(m, "EDETACHED")
		end
		-- No layout: every cell holds no element, even on a placed surface.
		return self:answer(m, nil, nil, nil, mp.pack({}))
	elseif c.a == "hide" or c.a == "delta" or c.a == "detach" or c.a == "focus" or c.a == "blur" or c.a == "field" then
		local state = self.docs[s]
		if not s then
			return self:answer(m, "EINVAL", nil, "s")
		elseif not state then
			return self:answer(m, "ENOENT")
		end
		local out, code, detail = "", nil, nil
		if c.a == "delta" then
			local ops, err = hotty.delta_of(m)
			if err then
				return self:answer(m, "EINVAL", err.op and { { "i", tostring(err.op) } } or nil, err.detail)
			end
			local extra
			for i, op in ipairs(ops) do
				local target = op.target
				local node = target and target ~= "" and document.find(state.tree, target) or nil
				if node or ((not target or target == "") and (op.op == "morph" or op.op == "scroll")) then
					local missing = document.apply(state.tree, node or state.tree, op, self.focused)
					if missing and not code then
						code, detail, extra = "ENOTARGET", missing, { { "i", tostring(i - 1) } }
					end
				elseif not code then
					code, detail, extra = "ENOTARGET", target, { { "i", tostring(i - 1) } }
				end
			end
			return input.fixup(self, s) .. self:answer(m, code, extra, detail)
		elseif c.a == "field" then
			if state.detached then
				code = "EDETACHED"
			else
				code, detail = input.set_field(self, m)
			end
		elseif c.a == "focus" then
			if state.detached then
				code = "EDETACHED"
			else
				out, code = input.focus(self, s, c.t)
				detail = code and c.t
			end
		elseif c.a == "blur" then
			if self.keyboard == s then
				out = input.blur(self)
			end
		elseif c.a == "hide" then
			self.placements[s] = nil
			out = self:cancel_pointer(s, true)
		elseif c.a == "detach" then
			state.detached = true
			self:cancel_pointer(s, false)
			if self.keyboard == s then
				self.keyboard, self.focused, self.prefix = nil, nil, nil
			end
		end
		return out .. self:answer(m, code, nil, detail)
	elseif c.a == "del" then
		if s then
			if not self.docs[s] then
				return self:answer(m, "ENOENT")
			end
			if self.keyboard == s then
				self.keyboard, self.focused, self.prefix = nil, nil, nil
			end
			self:cancel_pointer(s, false)
			self.docs[s], self.placements[s], self.flags[s] = nil, nil, nil
		elseif c.id then
			self.resources[c.id] = nil
		else
			self.keyboard, self.focused, self.prefix, self.pointer_button = nil, nil, nil, nil
			self.docs, self.placements, self.flags = {}, {}, {}
		end
		return self:answer(m)
	elseif c.a == "res" then
		if not c.id or c.id == "" or not c.type or c.type == "" then
			return self:answer(m, "EINVAL", nil, "resource")
		end
		self.resources[c.id] = { type = c.type, bytes = m.payload }
		return self:answer(m)
	elseif c.a == "touch" then
		local areas = touch_areas(m)
		if not areas then
			return self:answer(m, "EINVAL", nil, "areas")
		end
		self.touch[self.screen] = areas
		return self:answer(m)
	end
	return self:answer(m, "EINVAL")
end

-- What the terminal answers in the bytes that are not hotty's, and the
-- cursor's moves.
function Host:terminal(data)
	data = self.carry .. data
	self.carry = ""
	local out = {}
	local i, n = 1, #data
	while i <= n do
		local j = data:find("\27", i, true)
		if not j then
			break
		end
		local rest = data:sub(j)
		local csi, final = rest:match("^\27%[([%d;?$>=<!]*)([@-~])")
		if csi then
			if final == "c" and (csi == "" or csi == "0") then
				out[#out + 1] = "\27[?62;22c"
			elseif final == "n" and csi == "5" then
				out[#out + 1] = "\27[0n"
			elseif final == "n" and csi == "6" then
				out[#out + 1] = ("\27[%d;%dR"):format(self.cursor.y + 1, self.cursor.x + 1)
			elseif final == "p" and csi == "?2026$" then
				out[#out + 1] = "\27[?2026;2$y"
			elseif csi == "?1049" and final == "h" then
				self.screen = "alternate"
			elseif csi == "?1049" and final == "l" then
				self.screen = "main"
				self.touch.alternate = {}
			elseif final == "J" and (csi == "2" or csi == "3") then
				self.placements = {} -- an erase in display takes them (SDK.md §4.3)
				self.erased = (self.erased or 0) + 1
			elseif final == "H" or final == "f" then
				local y, x = csi:match("^(%d*);?(%d*)$")
				self.cursor = { x = (tonumber(x) or 1) - 1, y = (tonumber(y) or 1) - 1 }
			end
			i = j + #csi + 3
		elseif rest:sub(1, 2) == "\27c" then
			self:forget()
			i = j + 2
		elseif rest:match("^\27[78]") then
			if rest:sub(2, 2) == "7" then
				self.saved = { x = self.cursor.x, y = self.cursor.y }
			else
				self.cursor = { x = self.saved.x, y = self.saved.y }
			end
			i = j + 2
		elseif rest:match("^\27%]") then
			local e = rest:find("\7", 1, true) or rest:find("\27\\", 1, true)
			if not e then
				self.carry = rest
				return table.concat(out)
			end
			if rest:match("^\27%]11;%?") then
				out[#out + 1] = "\27]11;rgb:0000/0000/0000\27\\"
			end
			i = j + e
		elseif #rest < 8 and not rest:match("^\27[^%[%]78]") then
			self.carry = rest -- perhaps the start of a sequence
			return table.concat(out)
		else
			i = j + 1
		end
	end
	return table.concat(out)
end

--- Takes what the Neovim wrote, and returns what the terminal answers.
function Host:feed(data)
	local out = {}
	for _, seg in ipairs(self.scanner:feed(data)) do
		if seg.kind == "osc" then
			local result, m = self.decoder:feed(seg.data)
			if result == hotty.COMPLETE then
				out[#out + 1] = self:command(m)
			elseif result == hotty.INVALID then
				self:problem("a malformed hotty message: " .. seg.data:sub(1, 60))
			end
		else
			out[#out + 1] = self:terminal(seg.data)
		end
	end
	return table.concat(out)
end

--- An event, as the host sends it; detail is a table, written as msgpack.
function Host:event(surface, kind, target, detail)
	local body = detail and mp.pack(detail) or nil
	local ctl = { { "a", "ev" }, { "s", surface }, { "e", kind } }
	if target and target ~= "" then
		ctl[#ctl + 1] = { "t", target } -- absent where no element is meant (SPEC §9)
	end
	return hotty.encode(ctl, body)
end

--- Play a key by name. Returns whether the surface used it, and events.
function Host:key(key)
	return input.key(self, key)
end

--- Play named-element pointer input with the cells supplied by the test.
function Host:pointer(surface, phase, target, button, at)
	return input.pointer(self, surface, phase, target, button or hotty.BUTTON_PRIMARY, at or {})
end

--- The terminal becomes a host, as one attaching to a multiplexer's pane
--- does, and returns the late answer to the query it held, if any: the
--- reply the host gives that query.
function Host:become_host()
	self.native = true
	local c = self.held_query
	self.held, self.held_query = nil, nil
	if not c then
		return ""
	end
	self.log[#self.log + 1] = { a = "q", control = c }
	return self:query_reply(c)
end

--- The host forgets every surface, as a full reset does.
function Host:forget()
	self.docs, self.placements, self.flags = {}, {}, {}
	self.resources, self.touch, self.screen = {}, { main = {}, alternate = {} }, "main"
	self.session, self.held, self.held_query = nil, nil, nil
	self.keyboard, self.focused, self.prefix, self.pointer_button, self.held_buttons = nil, nil, nil, nil, nil
end

--- The commands logged, of action a (and surface s).
function Host:commands(a, s)
	local out = {}
	for _, e in ipairs(self.log) do
		if e.a == a and (s == nil or e.s == s) then
			out[#out + 1] = e
		end
	end
	return out
end

return M
