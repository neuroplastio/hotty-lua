-- A fake host, for tests of hotty.nvim (the test host of SDK.md §4.4, as
-- small as those tests need). It reads what a Neovim writes to its terminal
-- and answers as a terminal and a HOTTY host would:
--
--   - the terminal: DA1, the cursor report (DSR 5n), synchronized output's
--     DECRQM, the background colour; it follows the cursor through CUP and
--     ESC 7 / ESC 8, so it knows where each placement lands;
--   - the host (when native): the query, and every command, kept as surfaces
--     and placements, with replies as SPEC §3.6 has them. It lays nothing
--     out: r=auto gets auto_rows.
--
-- Strict: a malformed HOTTY message, or a HOTTY command other than the query
-- sent to a terminal that is not a host, is recorded in problems.

local hotty = require("hotty")

local M = {}
local Host = {}
Host.__index = Host

local DEFAULT_CAPS = '{"v":"0.1","events":["click","change","input","submit","press","focus","blur","resize","fit","hover","drag"],'
	.. '"cell":{"w":9,"h":18},"scale":1,"scheme":"dark","limits":{"surfaces":64},"host":"fake","version":"0.0.1"}'

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		native = opts.native ~= false,
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
		return reply(ctl, string.format('{"code":"%s","detail":"%s"}', err, m.control.s or ""))
	end
	if q ~= 0 then
		return ""
	end
	return reply(ctl)
end

function Host:command(m)
	local c = m.control
	local entry = { a = c.a, s = c.s, control = c, payload = m.payload }
	if c.a == "q" then
		self.queries = self.queries + 1
		if not self.native then
			return ""
		end
		self.log[#self.log + 1] = entry
		return reply({ { "a", "ok" }, { "n", c.n or "" }, { "re", "q" } }, self.caps)
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

--- An event, as the host sends it.
function Host:event(surface, kind, target, detail)
	return hotty.encode({ { "a", "ev" }, { "s", surface }, { "e", kind }, { "t", target or "" } }, detail)
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
