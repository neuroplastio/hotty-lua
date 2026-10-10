-- A fake host, for tests of hotty.nvim (the test host of SDK.md §4.4, as
-- small as those tests need). It reads what a Neovim writes to its terminal
-- and answers as a terminal and a HOTTY host would:
--
--   - the terminal: DA1, the cursor report (DSR 5n), synchronized output's
--     DECRQM, the background colour; it follows the cursor through CUP and
--     ESC 7 / ESC 8, so it knows where each placement lands, and an erase in
--     display (ED 2 or 3) drops every placement, as hottyterm does;
--   - the host (when native): the query, answered in the one version it
--     speaks (version, "0.2") or with EVERSION, and every command, kept as
--     surfaces and placements, with replies as SPEC §3.6 has them. It lays
--     nothing out: r=auto gets auto_rows;
--   - not a host, a multiplexer's pane with no terminal attached: it holds a
--     query that asks for a late answer (SPEC §4), until another query takes
--     its place, and become_host answers it as the host does.
--
-- Strict: a malformed HOTTY message, or a HOTTY command other than the query
-- sent to a terminal that is not a host, is recorded in problems.

local hotty = require("hotty")
local mp = require("msgpack_writer")

local M = {}
local Host = {}
Host.__index = Host

local DEFAULT_CAPS = mp.pack({
	v = "0.2",
	events = { "click", "change", "input", "submit", "press", "focus", "blur", "resize", "fit", "hover", "drag" },
	cell = { w = 9, h = 18 },
	scale = mp.float(1),
	scheme = "dark",
	limits = { surfaces = 64 },
	host = "fake",
	version = "0.0.1",
})

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		native = opts.native ~= false,
		version = opts.version or "0.2", -- the one version it speaks
		caps = opts.caps or DEFAULT_CAPS,
		auto_rows = opts.auto_rows or 4,
		scanner = hotty.scanner(),
		decoder = hotty.decoder(),
		carry = "", -- the start of a terminal sequence, cut by a read
		cursor = { x = 0, y = 0 },
		saved = { x = 0, y = 0 },
		docs = {}, -- surface to { html, detached }
		placements = {}, -- surface to { x, y, c, r, window, z, p, f, v, C }
		log = {}, -- every HOTTY command, in order: { a, s, control, payload }
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

-- Answers a command as SPEC §3.6 has hosts do: an error unless q is 2, an ok
-- only when q is 0.
function Host:answer(m, err, extra)
	local q = tonumber(m.control.q or "0") or 0
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
		return reply(ctl, mp.pack({ code = err, detail = m.control.s or "" }))
	end
	if q ~= 0 then
		return ""
	end
	return reply(ctl)
end

-- Whether v, the versions a query lists, comma-separated, has version
-- exactly.
local function lists(v, version)
	for entry in ((v or "") .. ","):gmatch("([^,]*),") do
		if entry == version then
			return true
		end
	end
	return false
end

-- Answers a query as a host that speaks one version does (SPEC §4): its
-- capabilities when the query lists that version, whatever else it lists,
-- and EVERSION, the version as its detail, when it lists another or none;
-- an error unless q is 2, an ok only when q is 0.
function Host:query_reply(c)
	local q = tonumber(c.q or "0") or 0
	local speaks = lists(c.v, self.version)
	if q >= 2 or (speaks and q ~= 0) then
		return ""
	end
	local ctl = { { "a", speaks and "ok" or "err" } }
	if c.n then
		ctl[#ctl + 1] = { "n", c.n }
	end
	ctl[#ctl + 1] = { "re", "q" }
	if speaks then
		return reply(ctl, self.caps)
	end
	return reply(ctl, mp.pack({ code = "EVERSION", detail = self.version }))
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
		self.problems[#self.problems + 1] = "a HOTTY command sent to a terminal that is not a host: a=" .. tostring(c.a)
		return ""
	end
	self.log[#self.log + 1] = entry
	local s = c.s
	if c.a == "doc" then
		self.docs[s] = { html = m.payload, detached = c.d == "1" }
		return self:answer(m)
	elseif c.a == "place" then
		if not self.docs[s] then
			return self:answer(m, "ENOENT")
		end
		local cols = tonumber(c.c)
		local rows = c.r == "auto" and self.auto_rows or tonumber(c.r)
		local p = { x = self.cursor.x, y = self.cursor.y, c = cols, r = rows, auto = c.r == "auto" }
		if c.x then
			p.window = { x = tonumber(c.x), y = tonumber(c.y), w = tonumber(c.w), h = tonumber(c.h) }
		end
		p.z, p.press, p.fit, p.hover, p.C = tonumber(c.z), c.p == "1", c.f == "1", c.v == "1", c.C == "1"
		self.placements[s] = p
		return self:answer(m, nil, { { "c", tostring(cols) }, { "r", tostring(rows) } })
	elseif c.a == "hide" or c.a == "delta" or c.a == "detach" or c.a == "focus" or c.a == "blur" then
		if not self.docs[s] then
			return self:answer(m, "ENOENT")
		end
		if c.a == "hide" then
			self.placements[s] = nil
		elseif c.a == "detach" then
			self.docs[s].detached = true
		end
		return self:answer(m)
	elseif c.a == "del" then
		if s then
			if not self.docs[s] then
				return self:answer(m, "ENOENT")
			end
			self.docs[s], self.placements[s] = nil, nil
		elseif not c.id then
			self.docs, self.placements = {}, {}
		end
		return self:answer(m)
	elseif c.a == "res" then
		return self:answer(m)
	end
	return self:answer(m, "EINVAL")
end

-- What the terminal answers in the bytes that are not HOTTY's, and the
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
			elseif final == "p" and csi == "?2026$" then
				out[#out + 1] = "\27[?2026;2$y"
			elseif final == "J" and (csi == "2" or csi == "3") then
				self.placements = {} -- an erase in display takes them (SDK.md §4.3)
				self.erased = (self.erased or 0) + 1
			elseif final == "H" or final == "f" then
				local y, x = csi:match("^(%d*);?(%d*)$")
				self.cursor = { x = (tonumber(x) or 1) - 1, y = (tonumber(y) or 1) - 1 }
			end
			i = j + #csi + 3
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
				self.problems[#self.problems + 1] = "a malformed HOTTY message: " .. seg.data:sub(1, 60)
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
	return hotty.encode({ { "a", "ev" }, { "s", surface }, { "e", kind }, { "t", target or "" } }, body)
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
	self.docs, self.placements = {}, {}
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
