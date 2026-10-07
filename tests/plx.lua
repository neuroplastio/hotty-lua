-- Tests of hotty.plx, against a fake plx-script: a ctx with the primitives
-- of docs/plx.md (hotty, hotty_send, size) and a plx with after and now on a
-- clock the test turns. Runs under the same interpreters as tests/unit.lua.

local root = ((arg and arg[0]) or ""):match("^(.-)/?tests/[^/]*$") or "."
if root == "" then
	root = "."
end
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local hotty = require("hotty")
local hplx = require("hotty.plx")

-- Counted in a table: in gopher-lua v1.1.2, once pcall catches an error, a
-- closure no longer shares its caller's locals.
local failures, stats = {}, { passed = 0 }

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		stats.passed = stats.passed + 1
	else
		failures[#failures + 1] = name .. ": " .. tostring(err)
	end
end

local function q(v)
	if type(v) == "string" then
		return string.format("%q", #v > 60 and (v:sub(1, 60) .. "…") or v)
	end
	return tostring(v)
end

local function eq(got, want, what)
	if got ~= want then
		error((what and (what .. ": ") or "") .. "got " .. q(got) .. ", want " .. q(want), 2)
	end
end

local function ok(v, what)
	if not v then
		error(what or "not true", 2)
	end
end

-- The fake ---------------------------------------------------------------------

local CAPS = '{"v":"0.1","events":["click","fit"],"cell":{"w":9,"h":18},"scheme":"dark",'
	.. '"limits":{"surfaces":64},"host":"fake","version":"0.0.1","future":{"x":[]}}'

-- plx's after and now, on a clock that moves only when the test says.
local function new_plx()
	local p = { t = 0, timers = {} }
	function p.now()
		return p.t
	end
	function p.after(ms, fn)
		local h = { at = p.t + ms, fn = fn }
		function h.cancel()
			h.cancelled = true
		end
		p.timers[#p.timers + 1] = h
		return h
	end
	function p.advance(ms, ctx)
		p.t = p.t + ms
		for _, h in ipairs(p.timers) do
			if not h.cancelled and not h.fired and h.at <= p.t then
				h.fired = true
				h.fn(ctx)
			end
		end
	end
	return p
end

-- A ctx: the instance's cells, the host plx knows (raw, or nil for none),
-- and what the script sent.
local function new_ctx(raw, cols, rows)
	local ctx = { raw = raw, cols = cols or 40, rows = rows or 20, out = {} }
	function ctx:hotty()
		if not self.raw then
			return nil
		end
		return { v = "0.1", host = "fake", scheme = "dark", dark = true, raw = self.raw }
	end
	function ctx:hotty_send(s)
		if not self.raw then
			return false
		end
		self.out[#self.out + 1] = s
		return true
	end
	function ctx:size()
		return self.cols, self.rows
	end
	return ctx
end

-- The HOTTY commands sent since the last call, each { a, s, control,
-- payload, at }, at being the cell a CUP before it moved to, from 0.
local function sent(ctx)
	local scanner, decoder = hotty.scanner(), hotty.decoder()
	local out, at = {}, nil
	for _, seg in ipairs(scanner:feed(table.concat(ctx.out))) do
		if seg.kind == "pass" then
			for y, x in seg.data:gmatch("\27%[(%d+);(%d+)H") do
				at = { x = tonumber(x) - 1, y = tonumber(y) - 1 }
			end
		else
			local r, m = decoder:feed(seg.data)
			assert(r == hotty.COMPLETE, "a malformed command: " .. q(seg.data))
			out[#out + 1] = { a = m.control.a, s = m.control.s, control = m.control, payload = m.payload, at = at }
			at = nil
		end
	end
	ctx.out = {}
	return out
end

local function actions(cmds)
	local t = {}
	for i, c in ipairs(cmds) do
		t[i] = c.a .. (c.s and (" " .. c.s) or "")
	end
	return table.concat(t, ", ")
end

local function event(s, kind, target, detail)
	return hotty.encode({ { "a", "ev" }, { "s", s }, { "e", kind }, { "t", target } }, detail)
end

local function err(re, s, code)
	return hotty.encode({ { "a", "err" }, { "re", re }, { "s", s } }, '{"code":"' .. code .. '","detail":"x"}')
end

local function card(spec)
	local t = { html = "<p id=n>0</p>", x = 2, y = 3, cols = 10, rows = 4 }
	for k, v in pairs(spec or {}) do
		t[k] = v
	end
	return t
end

-- A session on a host, attached.
local function setup(opts)
	opts = opts or {}
	local raw = opts.raw
	if raw == nil then
		raw = CAPS
	elseif raw == false then
		raw = nil
	end
	local p, ctx = new_plx(), new_ctx(raw, opts.cols, opts.rows)
	local s = hplx.session(opts.tool, {
		plx = p,
		prefix = opts.prefix,
		on_ready = opts.on_ready,
		on_event = opts.on_event,
		on_error = opts.on_error,
	})
	s:attach(ctx)
	return s, ctx, p
end

-- Tests --------------------------------------------------------------------------

test("no host: text, and nothing sent", function()
	local seen = {}
	local s, ctx = setup({
		raw = false,
		on_ready = function(mode, caps)
			seen.mode, seen.caps = mode, caps
		end,
	})
	eq(seen.mode, hotty.TEXT)
	eq(seen.caps, nil)
	eq(s:native(), false)
	local sf = s:surface("card", card())
	eq(sf:set_text("n", "1"), false)
	eq(#sent(ctx), 0)
end)

test("without ctx:hotty_send: text", function()
	local ctx = new_ctx(CAPS)
	ctx.hotty_send = nil
	local s = hplx.session(nil, { plx = new_plx() }):attach(ctx)
	eq(s.mode, hotty.TEXT)
end)

test("a host: the caps whole, then a document and its placement at its cells", function()
	local seen = {}
	local s, ctx = setup({
		on_ready = function(mode, caps)
			seen.mode, seen.caps = mode, caps
		end,
	})
	eq(seen.mode, hotty.NATIVE)
	eq(seen.caps.cell.w, 9)
	eq(seen.caps.host, "fake")
	ok(seen.caps.raw.future ~= nil, "unknown fields kept")
	eq(s.limit, 48)
	s:surface("card", card())
	local cmds = sent(ctx)
	eq(actions(cmds), "doc card, place card")
	eq(cmds[1].payload, "<p id=n>0</p>")
	eq(cmds[2].control.c, "10")
	eq(cmds[2].control.r, "4")
	eq(cmds[2].control.C, "1")
	eq(cmds[2].at.x, 2)
	eq(cmds[2].at.y, 3)
end)

test("deltas, under the prefix; only what changed goes out", function()
	local s, ctx = setup({ prefix = "app" })
	local sf = s:surface("card", card())
	eq(sf.id, "app-card")
	sent(ctx)
	ok(sf:set_text("n", "1"))
	local cmds = sent(ctx)
	eq(actions(cmds), "delta app-card")
	eq(cmds[1].control.op, "text")
	eq(cmds[1].payload, "1")
	sf:set({ x = 5 })
	cmds = sent(ctx)
	eq(actions(cmds), "place app-card")
	eq(cmds[1].at.x, 5)
	sf:set({ html = "<p>new</p>" })
	eq(actions(sent(ctx)), "doc app-card, place app-card")
	sf:set({ scroll = hotty.SCROLL_VERTICAL })
	cmds = sent(ctx)
	eq(actions(cmds), "doc app-card, place app-card")
	eq(cmds[1].control.scroll, "1")
	s:relayout()
	eq(#sent(ctx), 0, "nothing moved")
	s:relayout(true)
	eq(actions(sent(ctx)), "place app-card")
end)

test("clipped to the instance's cells, and out of view deleted or hidden", function()
	local s, ctx = setup({ cols = 20, rows = 10 })
	local a = s:surface("a", card({ x = 0, y = 8 }))
	local cmds = sent(ctx)
	eq(actions(cmds), "doc a, place a")
	eq(cmds[2].control.y, "0")
	eq(cmds[2].control.h, "2")
	eq(cmds[2].control.w, "10")
	a:set({ y = -1 })
	cmds = sent(ctx)
	eq(cmds[1].at.y, 0)
	eq(cmds[1].control.y, "1")
	eq(cmds[1].control.h, "3")
	a:set({ x = 30 })
	eq(actions(sent(ctx)), "del a")
	eq(a.sent, false)
	a:set({ x = 0, y = 0 })
	eq(actions(sent(ctx)), "doc a, place a")
	a:set({ keep = true, shown = false })
	eq(actions(sent(ctx)), "hide a")
	a:set({ shown = true })
	eq(actions(sent(ctx)), "place a")
end)

test("events: the SDK's Event, to the surface and the session", function()
	local got = {}
	local s, ctx = setup({
		on_event = function(ev, sf)
			got.session = ev.kind .. " " .. sf.name
		end,
	})
	s:surface(
		"card",
		card({
			on_event = function(ev)
				got.value, got.area = ev:value(), ev:area()
			end,
		})
	)
	sent(ctx)
	eq(s:hotty(ctx, event("card", "click", "b", '{"value":"v","area":{"c":1,"r":2,"w":3,"h":1}}')), true)
	eq(got.value, "v")
	eq(got.area.w, 3)
	eq(got.session, "click card")
	got.session = nil
	eq(s:hotty(ctx, event("other", "click", "b", "{}")), false, "a ui.hotty's")
	eq(got.session, nil)
end)

test("ENOENT, to a delta or to plx's own placement, sends the document again; EQUOTA lowers the limit", function()
	local errs = {}
	local s, ctx = setup({
		on_error = function(e, sf)
			errs[#errs + 1] = e.code .. " " .. sf.name
		end,
	})
	local a = s:surface("a", card())
	s:surface("b", card({ y = 9 }))
	sent(ctx)
	s:hotty(ctx, err("delta", "a", "ENOENT"))
	eq(actions(sent(ctx)), "doc a, place a")
	-- The relay's placement of a, rejected: re=place, and no n.
	s:hotty(ctx, err("place", "a", "ENOENT"))
	eq(actions(sent(ctx)), "doc a, place a")
	s:hotty(ctx, err("doc", "b", "EQUOTA"))
	eq(s.limit, 1)
	eq(a.sent, true)
	eq(table.concat(errs, ", "), "ENOENT a, ENOENT a, EQUOTA b")
end)

test("a new host: every document again; none: text", function()
	local modes = {}
	local s, ctx = setup({
		on_ready = function(mode)
			modes[#modes + 1] = mode
		end,
	})
	s:surface("card", card())
	sent(ctx)
	s:hotty_caps(ctx, CAPS:gsub('"surfaces":64', '"surfaces":8'))
	eq(actions(sent(ctx)), "doc card, place card")
	eq(s.limit, 8)
	ctx.raw = nil
	s:hotty_caps(ctx, nil)
	eq(s.mode, hotty.TEXT)
	eq(#sent(ctx), 0)
	eq(table.concat(modes, " "), "native native text")
end)

test("auto rows: a numbered placement, then the host's rows", function()
	local s, ctx = setup()
	local sf = s:surface("card", card({ rows = false }))
	local cmds = sent(ctx)
	eq(actions(cmds), "doc card, place card")
	eq(cmds[2].control.r, "auto")
	eq(cmds[2].control.n, "2")
	eq(cmds[2].control.q, "0")
	local reply =
		hotty.encode({ { "a", "ok" }, { "re", "place" }, { "n", "2" }, { "s", "card" }, { "c", "10" }, { "r", "5" } })
	eq(s:hotty(ctx, reply), true)
	eq(sf.rows, 5)
	cmds = sent(ctx)
	eq(actions(cmds), "place card")
	eq(cmds[1].control.r, "5")
	eq(cmds[1].control.n, nil)
end)

-- As plexos 5ba420f forwards them: the script's n, s renamed back when the
-- host's reply has one, and a resource's reply by n alone.
test("requests: a numbered delta's ok, and a resource's by n alone", function()
	local s, ctx = setup()
	s:surface("card", card())
	sent(ctx)
	local got = {}
	local n = s:request(function(o)
		return hotty.set_text("card", "n", "1", o)
	end, function(r)
		got.delta = r
	end)
	local cmds = sent(ctx)
	eq(actions(cmds), "delta card")
	eq(cmds[1].control.n, tostring(n))
	eq(cmds[1].control.q, "0")
	s:hotty(ctx, hotty.encode({ { "a", "ok" }, { "re", "delta" }, { "n", tostring(n) }, { "s", "card" } }))
	eq(got.delta.ok, true)
	eq(got.delta.surface, "card")
	local m = s:request(function(o)
		return hotty.res("logo", "image/png", "png", o)
	end, function(r)
		got.res = r
	end)
	eq(m, n + 1)
	s:hotty(ctx, hotty.encode({ { "a", "err" }, { "re", "res" }, { "n", tostring(m) } }, '{"code":"EBUDGET"}'))
	eq(got.res.ok, false)
	eq(got.res:err().code, "EBUDGET")
	eq(next(s.requests), nil)
	eq(s:hotty(ctx, hotty.encode({ { "a", "ok" }, { "re", "res" }, { "n", "99" } })), false, "no request of ours")
end)

test("a request times out on plx.after, and is not asked again", function()
	local s, ctx, p = setup()
	local sf = s:surface("card", card({ rows = false }))
	sent(ctx)
	p.advance(2999, ctx)
	eq(sf.measuring, true)
	p.advance(1, ctx)
	eq(sf.measuring, false)
	eq(next(s.requests), nil)
	s:relayout()
	eq(#sent(ctx), 0)
	sf:set({ x = 7 })
	local cmds = sent(ctx)
	eq(actions(cmds), "place card", "moved: placed, and measured, again")
	eq(cmds[1].at.x, 7)
	eq(cmds[1].control.n, "3")
end)

test("a placement's rows that come late are kept", function()
	local s, ctx, p = setup()
	local sf = s:surface("card", card({ rows = false }))
	sent(ctx)
	p.advance(3000, ctx)
	eq(next(s.requests), nil)
	local late =
		hotty.encode({ { "a", "ok" }, { "re", "place" }, { "n", "2" }, { "s", "card" }, { "c", "10" }, { "r", "5" } })
	eq(s:hotty(ctx, late), true)
	eq(sf.rows, 5)
	local cmds = sent(ctx)
	eq(actions(cmds), "place card")
	eq(cmds[1].control.r, "5")
	eq(s:hotty(ctx, late), false, "the same rows again")
	eq(#sent(ctx), 0)
end)

test("a fit event changes the rows", function()
	local s, ctx = setup()
	s:surface("card", card({ rows = false, fit = true }))
	sent(ctx)
	s:hotty(ctx, event("card", "fit", "", '{"r":6}'))
	local cmds = sent(ctx)
	eq(actions(cmds), "place card")
	eq(cmds[1].control.r, "6")
	eq(cmds[1].control.f, "1")
end)

test("limits.surfaces: no room, until one goes out of view", function()
	local s, ctx = setup({ raw = CAPS:gsub('"surfaces":64', '"surfaces":1') })
	local a = s:surface("a", card())
	local b = s:surface("b", card({ y = 9 }))
	eq(actions(sent(ctx)), "doc a, place a")
	ok(not b.sent, "no room for b")
	a:set({ keep = true, x = 50 })
	eq(actions(sent(ctx)), "hide a, del a, doc b, place b", "the one out of view makes room")
	ok(not a.sent)
end)

test("bind: the tool's callbacks, and the ones it had", function()
	local had = {}
	local tool = {
		on_hotty = function(_, seq)
			had.seq = seq
		end,
	}
	local p, ctx = new_plx(), new_ctx(CAPS, 20, 10)
	local s = hplx.session(tool, { plx = p })
	ok(tool.on_hotty_caps and tool.on_resize, "bound")
	local seq = event("card", "click", "b", "{}")
	tool.on_hotty(ctx, seq)
	eq(had.seq, seq)
	eq(s.ctx, ctx, "attached by the callback")
	s:surface("card", card({ y = 5 }))
	sent(ctx)
	ctx.rows = 7
	tool.on_resize(ctx, 20, 7)
	local cmds = sent(ctx)
	eq(actions(cmds), "place card")
	eq(cmds[1].control.h, "2")
	tool.on_hotty_caps(ctx, CAPS)
	eq(actions(sent(ctx)), "doc card, place card")
end)

test("on_ready may make surfaces", function()
	local ctx = new_ctx(CAPS)
	local s
	s = hplx.session(nil, {
		plx = new_plx(),
		on_ready = function(mode)
			if mode == hotty.NATIVE then
				s:surface("card", card())
			end
		end,
	})
	s:attach(ctx)
	eq(actions(sent(ctx)), "doc card, place card")
end)

test("remove deletes; close deletes the rest and stops", function()
	local s, ctx, p = setup()
	local a = s:surface("a", card())
	local b = s:surface("b", card({ y = 9 }))
	s:surface("c", card({ rows = false }))
	sent(ctx)
	a:remove()
	eq(actions(sent(ctx)), "del a")
	s:close()
	eq(actions(sent(ctx)), "del b, del c")
	eq(next(s.requests), nil)
	p.advance(5000, ctx)
	eq(a:set_text("n", "1"), false)
	eq(b:set_text("n", "1"), false)
	s:hotty_caps(ctx, CAPS)
	eq(#sent(ctx), 0)
end)

-- The example, in the fake: plx.tool and ui as plx-script has them, as far as
-- it uses them.
local function run_example(raw)
	local p, ctx = new_plx(), new_ctx(raw, 32, 10)
	local tools = {}
	function p.tool(t)
		tools[#tools + 1] = t
		return t
	end
	function ctx:el(_, key)
		return key
	end
	local ui = {}
	for _, kind in ipairs({ "box", "text" }) do
		ui[kind] = function(t)
			t.kind = kind
			return t
		end
	end
	-- Globals, as in plx-script, for as long as the example runs: the rest of
	-- the tests hand their session a plx of their own.
	_G.plx, _G.ui = p, ui
	dofile(root .. "/examples/plx/click.lua")
	local t = tools[1]
	t.init(ctx)
	return t, ctx, t.render(ctx)
end

test("examples/plx/click.lua: the surface, a click and its delta", function()
	local t, ctx, frame = run_example(CAPS)
	eq(frame.kind, "box")
	eq(frame.h, 2)
	local cmds = sent(ctx)
	eq(actions(cmds), "doc card, place card")
	eq(cmds[2].control.c, "32")
	ok(cmds[1].payload:find("no clicks yet", 1, true), "the document")
	t.on_hotty(ctx, event("card", "click", "go", "{}"))
	cmds = sent(ctx)
	eq(actions(cmds), "delta card")
	eq(cmds[1].payload, "1 click")
	ctx.cols = 20
	t.on_resize(ctx, 20, 10)
	t.render(ctx)
	cmds = sent(ctx)
	-- Clipped by the resize, then narrowed by the frame after it.
	eq(actions(cmds), "place card, place card")
	eq(cmds[1].control.w, "20")
	eq(cmds[2].control.c, "20")
	eq(cmds[2].control.w, nil)
end)

test("examples/plx/click.lua: no host, the cells", function()
	local t, ctx, frame = run_example(nil)
	eq(#sent(ctx), 0)
	eq(frame[1][1], "[ Click me ]")
	t.on_event(ctx, { source = "cells", handler = "go" })
	eq(t.render(ctx)[2][1], "1 click")
end)

for _, f in ipairs(failures) do
	print("FAIL " .. f)
end
print(string.format("plx     %d passed%s", stats.passed, #failures > 0 and (", " .. #failures .. " failed") or ""))
if #failures > 0 then
	os.exit(1)
end
