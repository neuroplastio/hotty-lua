--- hotty.nvim is HOTTY for a Neovim plugin: SDK.md §4.2, a push environment.
---
--- Neovim owns the terminal. Its TUI parses the input and raises
--- TermResponse with each OSC sequence, without its terminator, and with each
--- DA1 answer; a plugin writes to the terminal with nvim_ui_send, whose bytes
--- go out between the TUI's frames, in the order they were sent. So there is
--- no Scanner here: TermResponse feeds the Decoder and the Detector, and
--- waiting is timers and callbacks.
---
--- Two parts:
---   - the terminal (hotty.nvim.term()): one per Neovim. It detects whether
---     the terminal is a host, again whenever the terminal can have changed
---     (a UI attached, a return from suspension), sends commands, numbers
---     requests and fences, and hands events to whoever owns their surface;
---   - a session (hotty.nvim.session()): a plugin's surfaces, each anchored
---     to a buffer position or a screen cell. After the editor draws, the
---     session places each surface where its anchor is now, clipped to its
---     window, and sends only what changed (SDK.md §4.3).
---
--- The wire layer (require("hotty")) never requires vim; this module does.
local hotty = require("hotty")

local api, uv = vim.api, vim.uv or vim.loop

local M = {}

M.REQUEST_TIMEOUT = 3000 -- ms: a numbered command's reply (SDK.md §4.1)
M.FENCE_TIMEOUT = 1000 -- ms: the DA1 behind a fence
M.MAX_SURFACES = 48 -- a session's surfaces on the host, when it sets no lower limit (SDK.md §4.3)

local function now()
	return uv.hrtime() / 1e6
end

-- A one-shot timer whose callback runs on the main loop.
local function after(ms, fn)
	local t = uv.new_timer()
	t:start(math.max(0, math.ceil(ms)), 0, function()
		t:stop()
		t:close()
		vim.schedule(fn)
	end)
	return t
end

local function cancel(t)
	if t and not t:is_closing() then
		t:stop()
		t:close()
	end
end

local function is_da1(seq)
	return seq:find("^\27%[%?[%d;]*c$") ~= nil
end

-- The terminal ----------------------------------------------------------------

local Term = {}
Term.__index = Term

local term_singleton

--- Whether a UI that writes to a terminal is attached: nvim_ui_send reaches
--- only those (stdout_tty).
function M.has_tty()
	for _, ui in ipairs(api.nvim_list_uis()) do
		if ui.stdout_tty then
			return true
		end
	end
	return false
end

--- The terminal, made on first use. Its mode is nil before detection, then
--- "detecting", then "native" (a host) or "text" (not one).
function M.term()
	if not term_singleton then
		term_singleton = setmetatable({
			mode = nil,
			caps = nil,
			decoder = hotty.decoder(),
			next_n = 2, -- 1 is the query's
			requests = {}, -- n to {cb, timer}
			fences = {}, -- in order: {cb, timer, replies}
			listeners = {}, -- functions(message), each told every message no wait claimed
			sessions = {},
			waiting = {}, -- callbacks for the decision
		}, Term)
		term_singleton:attach()
	end
	return term_singleton
end

function Term:attach()
	local group = api.nvim_create_augroup("hotty", { clear = true })
	api.nvim_create_autocmd("TermResponse", {
		group = group,
		callback = function(ev)
			local seq = ev.data and ev.data.sequence or vim.v.termresponse
			if type(seq) == "string" then
				self:input(seq)
			end
		end,
	})
	-- The terminal can change: a UI attached (perhaps another terminal), or
	-- the editor came back from suspension, having left the alternate
	-- screen, which takes surfaces with it (SPEC §5.4).
	api.nvim_create_autocmd({ "UIEnter", "VimResume" }, {
		group = group,
		callback = function()
			self:changed()
		end,
	})
	api.nvim_create_autocmd("UILeave", {
		group = group,
		callback = function()
			vim.schedule(function()
				if not M.has_tty() then
					self:lost()
				end
			end)
		end,
	})
	api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			for _, s in ipairs(self.sessions) do
				s:close()
			end
		end,
	})
end

--- Writes commands to the terminal, in one write. Returns whether a
--- terminal took them.
function Term:send(data)
	if data == nil or data == "" or not M.has_tty() then
		return false
	end
	api.nvim_ui_send(data)
	return true
end

--- Calls fn(message) with every message the terminal sends that detection,
--- a request or a fence did not take. Returns a function that removes it.
function Term:listen(fn)
	table.insert(self.listeners, fn)
	return function()
		for i, f in ipairs(self.listeners) do
			if f == fn then
				table.remove(self.listeners, i)
				return
			end
		end
	end
end

--- Detects whether the terminal is a host, once (SDK.md §3.8), and calls
--- cb(mode, caps) when it is decided: at once if it is. Detection starts
--- when a terminal is attached.
function Term:detect(cb)
	if self.mode == hotty.NATIVE or self.mode == hotty.TEXT then
		if cb then
			cb(self.mode, self.caps)
		end
		return
	end
	if cb then
		table.insert(self.waiting, cb)
	end
	if self.mode == nil and M.has_tty() then
		self:start()
	end
end

function Term:start()
	self.mode = hotty.DETECTING
	self.caps = nil
	self.detector = hotty.detector({ n = 1 })
	self:send(self.detector:start(now()))
	self:arm()
end

-- A timer for the Detector's next deadline.
function Term:arm()
	cancel(self.timer)
	self.timer = nil
	local det = self.detector
	if det and det.deadline then
		self.timer = after(det.deadline - now(), function()
			if self.detector == det then
				det:tick(now())
				self:after_detector()
			end
		end)
	end
end

function Term:after_detector()
	local det = self.detector
	if det.decided and self.mode == hotty.DETECTING then
		self.mode, self.caps = det.state, det.caps
		local waiting = self.waiting
		self.waiting = {}
		for _, cb in ipairs(waiting) do
			cb(self.mode, self.caps)
		end
		for _, s in ipairs(self.sessions) do
			s:decided(self.mode, self.caps)
		end
	end
	if det.done then
		cancel(self.timer)
		self.timer = nil
	else
		self:arm()
	end
end

-- The terminal may be another: detect again, and have every session send its
-- documents again.
function Term:changed()
	self:lost()
	vim.schedule(function()
		if M.has_tty() and self.mode == nil then
			self:start()
		end
	end)
end

-- No terminal, or one that has forgotten everything.
function Term:lost()
	cancel(self.timer)
	self.timer, self.detector, self.mode, self.caps = nil, nil, nil, nil
	for _, s in ipairs(self.sessions) do
		s:forget()
	end
end

--- Takes one sequence the terminal sent, as TermResponse has it.
function Term:input(seq)
	local t = now()
	if is_da1(seq) then
		local det = self.detector
		if det and not det.done then
			det:da1(t) -- advisory: other listeners see the same answer
			self:after_detector()
		end
		local f = table.remove(self.fences, 1)
		if f then
			cancel(f.timer)
			f.cb(f.replies)
		end
		return
	end
	local result, msg = self.decoder:feed(seq)
	if result ~= hotty.COMPLETE then
		return
	end
	local r = msg:reply()
	if r then
		local det = self.detector
		if det and det:reply(r, t) then
			self:after_detector()
			return
		end
		local req = r.n and self.requests[r.n]
		if req then
			self.requests[r.n] = nil
			cancel(req.timer)
			req.cb(r)
			return
		end
	end
	local claimed = false
	for _, s in ipairs(self.sessions) do
		claimed = s:message(msg) or claimed
	end
	for _, fn in ipairs(self.listeners) do
		fn(msg)
	end
	if r and not claimed then
		for _, f in ipairs(self.fences) do
			table.insert(f.replies, r)
		end
	end
end

--- Sends one command numbered with n and calls cb(reply) when its reply
--- arrives, or cb(nil, err) after REQUEST_TIMEOUT. build(opts) returns the
--- command, given { n = … }: function(o) return hotty.place(name, pl, o) end.
--- An error reply is a reply. The number is never 1, the query's.
function Term:request(build, cb)
	local n = self.next_n
	self.next_n = n < 2147483647 and n + 1 or 2
	local req = { cb = cb }
	self.requests[n] = req
	req.timer = after(M.REQUEST_TIMEOUT, function()
		if self.requests[n] == req then
			self.requests[n] = nil
			cb(nil, "hotty: no reply in time")
		end
	end)
	if not self:send(build({ n = n })) then
		self.requests[n] = nil
		cancel(req.timer)
		cb(nil, "hotty: no terminal")
	end
	return n
end

--- Waits until the terminal has taken everything written before (it answers
--- DA1 in order), FENCE_TIMEOUT at most, and calls cb(replies): the replies
--- no request or session took meanwhile, such as the errors of commands sent
--- with q=1.
function Term:fence(cb)
	local f = { cb = cb, replies = {} }
	f.timer = after(M.FENCE_TIMEOUT, function()
		for i, x in ipairs(self.fences) do
			if x == f then
				table.remove(self.fences, i)
				cb(f.replies)
				return
			end
		end
	end)
	table.insert(self.fences, f)
	if not self:send("\27[c") then
		table.remove(self.fences)
		cancel(f.timer)
		cb({})
	end
end

-- Sessions --------------------------------------------------------------------

local Session = {}
Session.__index = Session

local Surface = {}
Surface.__index = Surface

local ns = api.nvim_create_namespace("hotty")

--- A plugin's surfaces. opts:
---   prefix      the start of every surface name: the plugin's (required)
---   on_ready    function(mode, caps): the mode is known ("native" or "text")
---   on_event    function(event, surface): what the user did, in any surface
---   on_error    function(err, surface): a command the host refused
---   max_surfaces  48 by default; the host's limits.surfaces when lower
---   occlude     hide a surface while a floating window or the popup menu
---               covers it (true): surfaces are above the cells, so
---               otherwise they would hide them
function M.session(opts)
	assert(opts and opts.prefix, "hotty.nvim.session: a prefix is required")
	local term = M.term()
	local s = setmetatable({
		term = term,
		prefix = hotty.surface_name(opts.prefix),
		on_ready = opts.on_ready,
		on_event = opts.on_event,
		on_error = opts.on_error,
		max_surfaces = opts.max_surfaces or M.MAX_SURFACES,
		occlude = opts.occlude ~= false,
		surfaces = {}, -- by full name
		order = {}, -- full names, in the order they were made
		mode = nil,
		closed = false,
	}, Session)
	table.insert(term.sessions, s)
	s:watch()
	term:detect()
	if term.mode == hotty.NATIVE or term.mode == hotty.TEXT then
		vim.schedule(function()
			s:decided(term.mode, term.caps)
		end)
	end
	return s
end

-- The editor's events that move what is on the screen. Each schedules one
-- layout pass, which runs after the editor has drawn: nvim_ui_send's bytes
-- go out at once, while the TUI writes a frame when it flushes, so a
-- placement sent from the event itself would land before the cells it goes
-- with.
function Session:watch()
	self.group = api.nvim_create_augroup("hotty-session-" .. self.prefix, { clear = true })
	api.nvim_create_autocmd({
		"WinScrolled",
		"WinResized",
		"WinClosed",
		"WinNew",
		"WinEnter", -- a buffer's anchor shows in the current window
		"BufWinEnter",
		"BufWinLeave",
		"TabEnter",
		"TextChanged",
		"TextChangedI",
		"CompleteChanged",
		"CompleteDone",
	}, {
		group = self.group,
		callback = function()
			self:schedule()
		end,
	})
	-- A resize redraws the whole screen, and the TUI erases it first (ED 2),
	-- which takes the placements with it (SDK.md §4.3): every surface is
	-- placed again, moved or not.
	api.nvim_create_autocmd("VimResized", {
		group = self.group,
		callback = function()
			self:schedule(true)
		end,
	})
	-- Anything else that moves text without an event of its own (a fold, a
	-- line that wraps anew) redraws: each redraw schedules a pass, which
	-- sends nothing when nothing moved.
	api.nvim_set_decoration_provider(ns, {
		on_end = function()
			for _, sess in ipairs(self.term.sessions) do
				if next(sess.surfaces) then
					sess:schedule()
				end
			end
		end,
	})
end

--- The full name of the session's surface name: prefix, a dash, the name,
--- made valid.
function Session:id(name)
	return hotty.surface_name(self.prefix .. "-" .. name)
end

--- A surface. spec:
---   html        the document: a string, or a function that returns one,
---               called each time the document is sent (again, when the
---               host lost it)
---   anchor      where it goes (one of):
---                 { buf, row, col }          over buffer position (row, col),
---                                            0-based, as extmarks count
---                 { buf, row, below = true } on the rows below line row,
---                                            col cells from the text's left
---                 { screen = { x, y } }      at a screen cell, from 0
---               buf 0 is the current buffer; win picks the window when the
---               buffer is in several (the current one, else the first)
---   cols        its width in cells (required)
---   rows        its height; nil is auto: the host's choice, measured with
---               the first placement
---   reserve     with below: make room with virtual lines, so it covers no
---               text (true)
---   z, press, fit, hover   as in a placement (SPEC §5.2)
---   keep        hide it rather than delete it when it is out of view
---   detached    send the document detached: the surface reports nothing
---   on_event    function(event, surface)
function Session:surface(name, spec)
	local id = self:id(name)
	local old = self.surfaces[id]
	if old then
		old:remove()
	end
	local sf = setmetatable({ session = self, name = name, id = id, spec = {} }, Surface)
	self.surfaces[id] = sf
	table.insert(self.order, id)
	sf:set(spec)
	return sf
end

function Session:decided(mode, caps)
	if self.closed or self.mode == mode then
		return
	end
	self.mode = mode
	if mode == hotty.NATIVE and caps and caps.limits.surfaces then
		self.limit = math.min(self.max_surfaces, caps.limits.surfaces)
	else
		self.limit = self.max_surfaces
	end
	if self.on_ready then
		self.on_ready(mode, caps)
	end
	self:schedule()
end

-- The host has forgotten every surface, or the terminal is gone.
function Session:forget()
	self.mode = nil
	for _, sf in pairs(self.surfaces) do
		sf.sent, sf.placed = false, nil
	end
end

--- Asks for a layout pass after the editor's next frame. force places every
--- surface again, changed or not: for a program that knows the host dropped
--- its placements.
function Session:schedule(force)
	self.force = self.force or force
	if self.pending or self.closed then
		return
	end
	self.pending = true
	vim.schedule(function()
		self.pending = false
		self:layout()
	end)
end
Session.relayout = Session.schedule

-- What the host sent: an event or an error for one of this session's
-- surfaces. Returns whether it was this session's.
function Session:message(msg)
	local s = msg.control.s
	local sf = s and self.surfaces[s]
	if not sf then
		return false
	end
	local ev = msg:event()
	if ev then
		if ev.kind == hotty.EVENT_FIT then
			local rows = ev:fit_rows()
			if rows and rows ~= sf.rows then
				sf.rows = rows
				self:schedule()
			end
		end
		if sf.spec.on_event then
			sf.spec.on_event(ev, sf)
		end
		if self.on_event then
			self.on_event(ev, sf)
		end
		return true
	end
	local r = msg:reply()
	if r and not r.ok then
		if r.code == hotty.ENOENT then
			-- The host lost the document (a reset, the alternate screen).
			sf.sent, sf.placed = false, nil
			self:schedule()
		elseif r.code == hotty.EQUOTA and r.re == "doc" then
			sf.sent, sf.placed = false, nil
			self.limit = math.max(0, self:count_sent())
		end
		if self.on_error then
			self.on_error(r:err(), sf)
		end
		return true
	end
	return false
end

function Session:count_sent()
	local n = 0
	for _, sf in pairs(self.surfaces) do
		if sf.sent then
			n = n + 1
		end
	end
	return n
end

local function intersect(a, b)
	local x0, y0 = math.max(a.x, b.x), math.max(a.y, b.y)
	local x1, y1 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
	if x1 <= x0 or y1 <= y0 then
		return nil
	end
	return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- The rectangles of what Neovim draws over windows: floating windows (with
-- their borders) and the popup menu.
local function overlays()
	local out = {}
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		local cfg = api.nvim_win_get_config(win)
		if cfg.relative and cfg.relative ~= "" and not cfg.hide then
			local pos = api.nvim_win_get_position(win)
			local b = (cfg.border and cfg.border ~= "none" and cfg.border ~= "") and 1 or 0
			out[#out + 1] = {
				win = win,
				x = pos[2] - b,
				y = pos[1] - b,
				w = api.nvim_win_get_width(win) + 2 * b,
				h = api.nvim_win_get_height(win) + 2 * b,
			}
		end
	end
	local pum = vim.fn.pum_getpos()
	if pum and pum.height then
		out[#out + 1] = { x = pum.col, y = pum.row, w = pum.width + (pum.scrollbar and 1 or 0), h = pum.height }
	end
	return out
end

-- The window a buffer anchor shows in: the anchor's own, the current one if
-- it shows the buffer, else the first in the tab page that does.
local function window_for(buf, win)
	if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
		if api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage() then
			return win
		end
		return nil
	end
	local cur = api.nvim_get_current_win()
	if api.nvim_win_get_buf(cur) == buf then
		return cur
	end
	for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_buf(w) == buf and api.nvim_win_get_config(w).relative == "" then
			return w
		end
	end
	return nil
end

-- The cells a window shows its buffer's text in, 0-based.
local function text_area(win)
	local info = vim.fn.getwininfo(win)[1]
	return {
		x = info.wincol - 1 + info.textoff,
		y = info.winrow - 1 + (info.winbar or 0),
		w = info.width - info.textoff,
		h = info.height,
	},
		info
end

-- Where a surface's top left cell is now, the cells it may show in, and its
-- window; nil when it has nowhere to be.
function Surface:locate()
	local a = self.spec.anchor or {}
	if a.screen then
		return { x = a.screen.x or a.screen[1], y = a.screen.y or a.screen[2] }, {
			x = 0,
			y = 0,
			w = vim.o.columns,
			h = vim.o.lines,
		}
	end
	local buf = self.buf
	if not buf or not api.nvim_buf_is_valid(buf) or not self.mark then
		return nil
	end
	local pos = api.nvim_buf_get_extmark_by_id(buf, ns, self.mark, {})
	if not pos or not pos[1] then
		return nil
	end
	local win = window_for(buf, a.win)
	if not win then
		return nil
	end
	local row = pos[1]
	local lnum = row + 1
	local area, info = text_area(win)
	if lnum < info.topline or lnum > info.botline then
		return nil
	end
	local closed = api.nvim_win_call(win, function()
		return vim.fn.foldclosed(lnum)
	end)
	if closed ~= -1 then
		return nil
	end
	if a.below then
		local sp = vim.fn.screenpos(win, lnum, 1)
		if sp.row == 0 then
			return nil
		end
		local h = api.nvim_win_text_height(win, { start_row = row, end_row = row })
		local text_rows = h.all - (h.fill or 0)
		return { x = area.x + (a.col or 0), y = sp.row - 1 + text_rows }, area, win
	end
	local sp = vim.fn.screenpos(win, lnum, (a.col or 0) + 1)
	if sp.row == 0 then
		return nil
	end
	return { x = sp.col - 1, y = sp.row - 1 }, area, win
end

-- One surface's placement now: where (x, y), the placement, and a key that
-- changes when either does. nil when it is out of view.
function Surface:want(covers)
	local spec = self.spec
	local at, area, win = self:locate()
	if not at then
		return nil
	end
	local cols = spec.cols
	local rows = spec.rows or self.rows
	local pl = { cols = cols, rows = rows, z = spec.z, press = spec.press, fit = spec.fit, hover = spec.hover }
	if not rows then
		-- Auto: placed whole, unclipped, until the host says how tall.
		if not intersect({ x = at.x, y = at.y, w = 1, h = 1 }, area) then
			return nil
		end
		return { x = at.x, y = at.y, placement = pl, measure = true, key = "auto" }
	end
	local rect = { x = at.x, y = at.y, w = cols, h = rows }
	local vis = intersect(rect, area)
	if not vis then
		return nil
	end
	for _, o in ipairs(covers) do
		if o.win ~= win and intersect(vis, o) then
			return nil
		end
	end
	if vis.w ~= cols or vis.h ~= rows then
		pl.window = { x = vis.x - rect.x, y = vis.y - rect.y, w = vis.w, h = vis.h }
	end
	local w = pl.window or { x = 0, y = 0, w = cols, h = rows }
	local key = table.concat({
		vis.x,
		vis.y,
		cols,
		rows,
		w.x,
		w.y,
		w.w,
		w.h,
		tostring(spec.z or 0),
		tostring(spec.press),
		tostring(spec.fit),
		tostring(spec.hover),
	}, ":")
	return { x = vis.x, y = vis.y, placement = pl, key = key }
end

-- The rows a below anchor reserves: virtual lines in its buffer.
function Surface:reserve()
	local a, spec = self.spec.anchor or {}, self.spec
	if not (a.below and spec.reserve ~= false and self.buf and self.mark) then
		return
	end
	local rows = spec.rows or self.rows or 0
	if self.session.mode ~= hotty.NATIVE then
		rows = 0
	end
	if rows == self.reserved then
		return
	end
	local pos = api.nvim_buf_get_extmark_by_id(self.buf, ns, self.mark, {})
	if not pos or not pos[1] then
		return
	end
	local lines = {}
	for i = 1, rows do
		lines[i] = { { "", "Normal" } }
	end
	api.nvim_buf_set_extmark(self.buf, ns, pos[1], pos[2], {
		id = self.mark,
		virt_lines = rows > 0 and lines or nil,
		right_gravity = false,
	})
	self.reserved = rows
end

function Session:layout()
	local force = self.force
	self.force = false
	if self.closed or self.mode ~= hotty.NATIVE or not M.has_tty() then
		for _, sf in pairs(self.surfaces) do
			sf:reserve()
		end
		return
	end
	local covers = self.occlude and overlays() or {}
	local cmds, measures = {}, {}
	local function add(c)
		cmds[#cmds + 1] = c
	end
	local t = now()
	for _, id in ipairs(self.order) do
		local sf = self.surfaces[id]
		if sf then
			sf:reserve()
			local want = sf:want(covers)
			if want then
				sf.seen = t
				if not sf.sent and self:room(sf) then
					local html = sf.spec.html
					if type(html) == "function" then
						html = html(sf)
					end
					add(hotty.doc(id, html or "", { detached = sf.spec.detached }))
					sf.sent, sf.placed = true, nil
				end
				if sf.sent and (force or sf.placed ~= want.key) then
					if want.measure then
						if not sf.measuring then
							sf.measuring = true
							measures[#measures + 1] = { sf, want }
						end
					else
						add(hotty.place_at(id, want.x, want.y, want.placement))
					end
					sf.placed = want.key
				end
			elseif sf.placed then
				if sf.spec.keep then
					add(hotty.hide(id))
				else
					add(hotty.del(id))
					sf.sent = false
				end
				sf.placed = nil
			end
		end
	end
	if #cmds == 1 then
		self.term:send(cmds[1])
	elseif #cmds > 1 then
		self.term:send(hotty.sync(cmds))
	end
	-- After the documents they place.
	for _, m in ipairs(measures) do
		self:measure(m[1], m[2])
	end
end

-- Whether the host has room for one more document, making room by deleting
-- the surfaces kept out of view, the longest unseen first.
function Session:room(sf)
	if self:count_sent() < self.limit then
		return true
	end
	local victim
	for _, other in pairs(self.surfaces) do
		if other ~= sf and other.sent and not other.placed then
			if not victim or (other.seen or 0) < (victim.seen or 0) then
				victim = other
			end
		end
	end
	if not victim then
		return false
	end
	self.term:send(hotty.del(victim.id))
	victim.sent = false
	return true
end

-- Places a surface whose rows are auto, numbered, and keeps the rows the
-- host chose.
function Session:measure(sf, want)
	self.term:request(function(o)
		return hotty.place_at(sf.id, want.x, want.y, want.placement, o)
	end, function(r)
		sf.measuring = false
		if r and r.ok and r.rows then
			sf.rows = r.rows
			sf.placed = nil
			self:schedule()
		elseif r then
			self:message(r.message)
		end
	end)
end

--- Deletes the session's surfaces, and stops.
function Session:close()
	self:finish(hotty.del)
end

--- Detaches the session's surfaces, which stay where they are and report
--- nothing more (SPEC §5.5), and stops.
function Session:detach_all()
	self:finish(hotty.detach)
end

function Session:finish(build)
	if self.closed then
		return
	end
	local cmds = {}
	for _, id in ipairs(self.order) do
		local sf = self.surfaces[id]
		if sf then
			if sf.sent and self.mode == hotty.NATIVE then
				cmds[#cmds + 1] = build(id)
			end
			sf:unmark()
		end
	end
	if #cmds > 0 then
		self.term:send(table.concat(cmds))
	end
	self.closed = true
	self.surfaces, self.order = {}, {}
	pcall(api.nvim_del_augroup_by_id, self.group)
	for i, s in ipairs(self.term.sessions) do
		if s == self then
			table.remove(self.term.sessions, i)
			break
		end
	end
end

-- Surfaces --------------------------------------------------------------------

--- Changes a surface's spec: the keys given replace the ones it had. A new
--- html sends the document again; a new anchor or size places it again.
function Surface:set(spec)
	local old = self.spec
	local new = {}
	for k, v in pairs(old) do
		new[k] = v
	end
	for k, v in pairs(spec or {}) do
		new[k] = v
	end
	assert(new.cols, "hotty.nvim: a surface needs cols")
	self.spec = new
	if spec and spec.anchor then
		self:mark_anchor(spec.anchor)
	end
	if spec and (spec.rows ~= nil or spec.html ~= nil) then
		self.rows = nil -- measured again, if auto
	end
	if spec and spec.html ~= nil and old.html ~= nil and self.sent then
		self.sent = false
	end
	self.placed = nil
	self.session:schedule()
	return self
end

function Surface:mark_anchor(a)
	self:unmark()
	if a.screen then
		return
	end
	local buf = (a.buf == nil or a.buf == 0) and api.nvim_get_current_buf() or a.buf
	self.buf = buf
	self.mark = api.nvim_buf_set_extmark(buf, ns, a.row or 0, a.below and 0 or (a.col or 0), {
		right_gravity = false,
	})
	self.reserved = 0
end

function Surface:unmark()
	if self.buf and self.mark and api.nvim_buf_is_valid(self.buf) then
		pcall(api.nvim_buf_del_extmark, self.buf, ns, self.mark)
	end
	self.buf, self.mark, self.reserved = nil, nil, nil
end

--- Sends commands for this surface, once its document is on the host. They
--- change the host's copy only: the document sent again, when the host lost
--- it, is spec.html's.
function Surface:send(cmd)
	local s = self.session
	if s.mode ~= hotty.NATIVE or not self.sent then
		return false
	end
	return s.term:send(cmd)
end

function Surface:delta(op, target, key, payload, opts)
	return self:send(hotty.delta(self.id, op, target, key, payload, opts))
end

function Surface:set_text(target, text, opts)
	return self:send(hotty.set_text(self.id, target, text, opts))
end

function Surface:set_var(target, name, value, opts)
	return self:send(hotty.set_var(self.id, target, name, value, opts))
end

function Surface:set_attr(target, name, value, opts)
	return self:send(hotty.set_attr(self.id, target, name, value, opts))
end

function Surface:remove_attr(target, name, opts)
	return self:send(hotty.remove_attr(self.id, target, name, opts))
end

function Surface:morph_to(target, html, opts)
	return self:send(hotty.morph_to(self.id, target, html, opts))
end

function Surface:focus(target, opts)
	return self:send(hotty.focus(self.id, target, opts))
end

function Surface:blur(opts)
	return self:send(hotty.blur(self.id, opts))
end

--- Removes the surface: deleted on the host, its anchor and room gone.
function Surface:remove()
	local s = self.session
	if s.surfaces[self.id] ~= self then
		return
	end
	if self.sent and s.mode == hotty.NATIVE then
		s.term:send(hotty.del(self.id))
	end
	self:unmark()
	s.surfaces[self.id] = nil
	for i, id in ipairs(s.order) do
		if id == self.id then
			table.remove(s.order, i)
			break
		end
	end
end

M.Term, M.Session, M.Surface = Term, Session, Surface
M.namespace = ns

return M
