--- hotty.plx is HOTTY for a plx script (plexos's plx-script): SDK.md §4.2, a
--- push environment.
---
--- plx owns the terminal. It knows whether the terminal is a host and hands
--- the script the host's capabilities (ctx:hotty().raw, and on_hotty_caps
--- when the host changes); it writes what the script sends (ctx:hotty_send)
--- between its frames; and it hands the script every HOTTY message for its
--- surfaces (on_hotty), events and replies alike. Its relay names the
--- script's surfaces apart from every other program's, places them where the
--- script's tool or rail is on the screen, moves and clips them with it, and
--- hides them under whatever plx draws over it. So there is no Scanner, no
--- Detector and no fence here, and where a surface goes is in the instance's
--- own cells. docs/plx.md has the primitives.
---
--- A session is a script's surfaces, each at a rectangle of the instance's
--- cells. It sends a surface's document once, places it where it is now,
--- clipped to the instance, and sends only what changed (SDK.md §4.3).
---
--- The wire layer is all it requires.
local hotty = require("hotty")

local M = {}

M.REQUEST_TIMEOUT = 3000 -- ms: a numbered command's reply (SDK.md §4.1)
M.MAX_SURFACES = 48 -- a session's surfaces on the host, when it sets no lower limit (SDK.md §4.3)

local Session = {}
Session.__index = Session

local Surface = {}
Surface.__index = Surface

--- A script's surfaces. tool is what plx.tool{} or plx.rail{} returned, or
--- nil; given one, the session binds to it (Session:bind). opts:
---   prefix        the start of every surface name, then a dash (none): for
---                 a script whose ui.hotty ids could meet its surface names
---   on_ready      function(mode, caps): the mode is known, or the host
---                 changed ("native" or "text"; caps nil for text)
---   on_event      function(event, surface): what the user did, in any surface
---   on_error      function(err, surface): a command the host refused
---   max_surfaces  48 by default; the host's limits.surfaces when lower
---   plx           plx-script's plx table: the global plx by default
function M.session(tool, opts)
	opts = opts or {}
	local s = setmetatable({
		plx = opts.plx or _G.plx,
		prefix = opts.prefix and hotty.surface_name(opts.prefix) or nil,
		on_ready = opts.on_ready,
		on_event = opts.on_event,
		on_error = opts.on_error,
		max_surfaces = opts.max_surfaces or M.MAX_SURFACES,
		decoder = hotty.decoder(),
		surfaces = {}, -- by full name
		order = {}, -- full names, in the order they were made
		requests = {}, -- by n
		next_n = 2,
		ctx = nil,
		mode = nil,
		caps = nil,
		limit = opts.max_surfaces or M.MAX_SURFACES,
		closed = false,
	}, Session)
	if tool then
		s:bind(tool)
	end
	return s
end

--- Sets tool's on_hotty, on_hotty_caps and on_resize to the session's. Each
--- then calls the one the tool had, if any. A script that sets its own
--- afterwards calls Session:hotty, :hotty_caps and :resize from it.
function Session:bind(tool)
	local had = {
		on_hotty = tool.on_hotty,
		on_hotty_caps = tool.on_hotty_caps,
		on_resize = tool.on_resize,
	}
	tool.on_hotty = function(ctx, seq)
		self:hotty(ctx, seq)
		if had.on_hotty then
			return had.on_hotty(ctx, seq)
		end
	end
	tool.on_hotty_caps = function(ctx, raw)
		self:hotty_caps(ctx, raw)
		if had.on_hotty_caps then
			return had.on_hotty_caps(ctx, raw)
		end
	end
	tool.on_resize = function(ctx, cols, rows)
		self:resize(ctx, cols, rows)
		if had.on_resize then
			return had.on_resize(ctx, cols, rows)
		end
	end
	return self
end

--- Gives the session the instance's ctx, and reads the host from it the
--- first time. Call it from init: plx calls on_hotty_caps only when the host
--- changes, never at the start. The callbacks bind sets call it too.
function Session:attach(ctx)
	if self.ctx == ctx or self.closed then
		return self
	end
	self.ctx = ctx
	local h = type(ctx.hotty) == "function" and ctx:hotty() or nil
	self:host(type(h) == "table" and h.raw or nil)
	return self
end

-- The host is now the one whose capabilities raw is, the body of its reply
-- to plx's query (msgpack, as the host sent it), or none: so is a host whose
-- capabilities do not decode, or name another version than this SDK speaks,
-- or none (SPEC §4). Without ctx:hotty_send there is no way to reach one.
function Session:host(raw)
	local caps
	if type(self.ctx.hotty_send) == "function" then
		caps = hotty.caps(raw)
		if caps and caps.v ~= hotty.VERSION then
			caps = nil
		end
	end
	self:forget()
	self.mode, self.caps = caps and hotty.NATIVE or hotty.TEXT, caps
	self.limit = self.max_surfaces
	if caps and caps.limits.surfaces then
		self.limit = math.min(self.max_surfaces, caps.limits.surfaces)
	end
	if self.on_ready then
		self.on_ready(self.mode, caps)
	end
	self:schedule()
end

--- on_hotty_caps: the host changed, and has none of the surfaces.
function Session:hotty_caps(ctx, raw)
	if self.closed then
		return
	end
	self.ctx = ctx
	self:host(raw)
end

--- on_resize: the instance has other cells.
function Session:resize(ctx)
	self:attach(ctx)
	self:schedule()
end

--- on_hotty: one HOTTY message plx routed to the instance, as the host wrote
--- it. Returns whether it was this session's.
function Session:hotty(ctx, seq)
	self:attach(ctx)
	local result, msg = self.decoder:feed(seq)
	if result ~= hotty.COMPLETE then
		return false
	end
	local r = msg:reply()
	local req = r and r.n and self.requests[r.n]
	if req then
		self.requests[r.n] = nil
		if req.timer then
			req.timer:cancel()
		end
		req.cb(r)
		return true
	end
	return self:message(msg)
end

--- Whether the host draws the surfaces. When it does not, the script draws
--- them in cells.
function Session:native()
	return self.mode == hotty.NATIVE
end

--- Writes commands toward the host. false when there is none.
function Session:send(cmd)
	local ctx = self.ctx
	if self.closed or self.mode ~= hotty.NATIVE or not ctx then
		return false
	end
	return ctx:hotty_send(cmd) ~= false
end

--- Sends one command numbered with n and calls cb(reply) when its reply
--- arrives, or cb(nil, err) after REQUEST_TIMEOUT. build(opts) returns the
--- command, given { n = … }: function(o) return hotty.place(name, pl, o) end.
--- An error reply is a reply. plx numbers what it forwards on the host
--- itself, so n is the session's own.
function Session:request(build, cb)
	local n = self.next_n
	self.next_n = n < 2147483647 and n + 1 or 2
	local req = { cb = cb }
	self.requests[n] = req
	if self.plx and self.plx.after then
		req.timer = self.plx.after(M.REQUEST_TIMEOUT, function()
			if self.requests[n] == req then
				self.requests[n] = nil
				cb(nil, "hotty: no reply in time")
			end
		end)
	end
	if not self:send(build({ n = n })) then
		self.requests[n] = nil
		if req.timer then
			req.timer:cancel()
		end
		cb(nil, "hotty: no host")
	end
	return n
end

-- The host has none of the surfaces.
function Session:forget()
	for _, sf in pairs(self.surfaces) do
		sf.sent, sf.placed, sf.measuring = false, nil, false
		if not sf.spec.rows then
			sf.rows = nil
		end
	end
end

--- Lays the surfaces out now: plx writes what this sends between its
--- frames, never inside one. force places every surface again, changed or
--- not. A change made while a pass runs (from an html function, say) runs
--- another.
function Session:schedule(force)
	self.force = self.force or force
	if self.laying then
		self.again = true
		return
	end
	self.laying = true
	local ok, err
	repeat
		self.again = false
		ok, err = pcall(self.layout, self)
	until not ok or not self.again
	self.laying = false
	if not ok then
		error(err, 0)
	end
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
	if r and r.ok then
		-- A placement's rows that came after its request gave up (plx answers
		-- an instance's once it is on the screen): kept, as in time.
		if r.re == "place" and r.rows and not sf.spec.rows and r.rows ~= sf.rows then
			sf.rows, sf.measuring, sf.placed = r.rows, false, nil
			self:schedule()
			return true
		end
		return false
	end
	if r and not r.ok then
		if r.code == hotty.ENOENT then
			-- The host lost the document: plx's relay says so in answer to its
			-- own placement of the surface (re=place).
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

--- The full name of the session's surface name: the prefix and a dash when
--- there is one, then the name, made valid.
function Session:id(name)
	return hotty.surface_name(self.prefix and (self.prefix .. "-" .. name) or name)
end

--- A surface. spec:
---   html        the document: a string, or a function that returns one,
---               called each time the document is sent (again, when the
---               host lost it)
---   x, y        its top left cell in the instance's cells, from 0
---               (required); a surface the instance's cells do not reach
---               is out of view, and one they reach in part is clipped
---   cols        its width in cells (required)
---   rows        its height; nil is auto: the host's choice, measured with
---               the first placement
---   shown       false keeps it out of view (true)
---   z, press, fit, hover   as in a placement (SPEC §5.2)
---   keep        hide it rather than delete it when it is out of view
---   detached    send the document detached: the surface reports nothing
---   scroll      the axes along which the document scrolls in its cells, a
---               bitmask of hotty.SCROLL_VERTICAL and SCROLL_HORIZONTAL
---               (SPEC §5.1); a host that cannot ignores it and clips
---   on_event    function(event, surface)
--- A name a ui.hotty uses is not the session's to take.
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

local function intersect(a, b)
	local x0, y0 = math.max(a.x, b.x), math.max(a.y, b.y)
	local x1, y1 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
	if x1 <= x0 or y1 <= y0 then
		return nil
	end
	return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- One surface's placement now, in the instance's cells (area): where (x,
-- y), the placement, and a key that changes when either does. nil when it
-- is out of view.
function Surface:want(area)
	local spec = self.spec
	if spec.shown == false then
		return nil
	end
	local cols = spec.cols
	local rows = spec.rows or self.rows
	local pl = { cols = cols, rows = rows, z = spec.z, press = spec.press, fit = spec.fit, hover = spec.hover }
	local flags =
		table.concat({ tostring(spec.z or 0), tostring(spec.press), tostring(spec.fit), tostring(spec.hover) }, ":")
	if not rows then
		-- Auto: placed whole, unclipped, until the host says how tall; placed
		-- again where it is moved, should the host never say.
		if not intersect({ x = spec.x, y = spec.y, w = 1, h = 1 }, area) then
			return nil
		end
		local key = table.concat({ "auto", spec.x, spec.y, cols, flags }, ":")
		return { x = spec.x, y = spec.y, placement = pl, measure = true, key = key }
	end
	local rect = { x = spec.x, y = spec.y, w = cols, h = rows }
	local vis = intersect(rect, area)
	if not vis then
		return nil
	end
	if vis.w ~= cols or vis.h ~= rows then
		pl.window = { x = vis.x - rect.x, y = vis.y - rect.y, w = vis.w, h = vis.h }
	end
	local w = pl.window or { x = 0, y = 0, w = cols, h = rows }
	local key = table.concat({ vis.x, vis.y, cols, rows, w.x, w.y, w.w, w.h, flags }, ":")
	return { x = vis.x, y = vis.y, placement = pl, key = key }
end

function Session:layout()
	local force = self.force
	self.force = false
	if self.closed or self.mode ~= hotty.NATIVE or not self.ctx then
		return
	end
	local cols, rows = self.ctx:size()
	local area = { x = 0, y = 0, w = cols or 0, h = rows or 0 }
	local cmds, measures = {}, {}
	local function add(c)
		cmds[#cmds + 1] = c
	end
	local t = self.plx and self.plx.now and self.plx.now() or 0
	for _, id in ipairs(self.order) do
		local sf = self.surfaces[id]
		if sf then
			local want = sf:want(area)
			if want then
				sf.seen = t
				if not sf.sent and self:room(sf, add) then
					local html = sf.spec.html
					if type(html) == "function" then
						html = html(sf)
					end
					add(hotty.doc(id, html or "", { detached = sf.spec.detached, scroll = sf.spec.scroll }))
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
		self:send(cmds[1])
	elseif #cmds > 1 then
		self:send(hotty.sync(cmds))
	end
	-- After the documents they place.
	for _, m in ipairs(measures) do
		self:measure(m[1], m[2])
	end
end

-- Whether the host has room for one more document, making room by deleting
-- the surfaces kept out of view, the longest unseen first: add takes the
-- delete, in order with the pass's other commands.
function Session:room(sf, add)
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
	add(hotty.del(victim.id))
	victim.sent = false
	return true
end

-- Places a surface whose rows are auto, numbered, and keeps the rows the
-- host chose.
function Session:measure(sf, want)
	self:request(function(o)
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

--- Deletes the session's surfaces, and stops. (plx's relay takes no detach:
--- a session has no detach_all.)
function Session:close()
	if self.closed then
		return
	end
	local cmds = {}
	for _, id in ipairs(self.order) do
		local sf = self.surfaces[id]
		if sf and sf.sent then
			cmds[#cmds + 1] = hotty.del(id)
		end
	end
	if #cmds > 0 then
		self:send(table.concat(cmds))
	end
	self.closed = true
	self.surfaces, self.order = {}, {}
	for n, req in pairs(self.requests) do
		if req.timer then
			req.timer:cancel()
		end
		self.requests[n] = nil
	end
end

-- Surfaces --------------------------------------------------------------------

--- Changes a surface's spec: the keys given replace the ones it had. A new
--- html or scroll sends the document again; a new place or size places it
--- again.
function Surface:set(spec)
	local old = self.spec
	local new = {}
	for k, v in pairs(old) do
		new[k] = v
	end
	for k, v in pairs(spec or {}) do
		new[k] = v
	end
	assert(new.cols, "hotty.plx: a surface needs cols")
	assert(new.x and new.y, "hotty.plx: a surface needs x and y")
	self.spec = new
	if spec and (spec.rows ~= nil or spec.html ~= nil) then
		self.rows = nil -- measured again, if auto
	end
	if spec and self.sent and ((spec.html ~= nil and old.html ~= nil) or (new.scroll or 0) ~= (old.scroll or 0)) then
		self.sent = false
	end
	-- Placed again when its placement's key changes; kept until then, so one
	-- moved out of view is taken off the screen.
	self.session:schedule()
	return self
end

--- Sends commands for this surface, once its document is on the host. They
--- change the host's copy only: the document sent again, when the host lost
--- it, is spec.html's.
function Surface:send(cmd)
	if not self.sent then
		return false
	end
	return self.session:send(cmd)
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

--- Removes the surface: deleted on the host.
function Surface:remove()
	local s = self.session
	if s.surfaces[self.id] ~= self then
		return
	end
	if self.sent then
		s:send(hotty.del(self.id))
		self.sent = false
	end
	s.surfaces[self.id] = nil
	for i, id in ipairs(s.order) do
		if id == self.id then
			table.remove(s.order, i)
			break
		end
	end
end

M.Session, M.Surface = Session, Surface

return M
