-- Tests of hotty.nvim against a fake host: nvim -l tests/nvim/run.lua
--
-- Each test starts a Neovim (tests/nvim/init.lua) in a pseudo-terminal, as a
-- user would run it, and plays its terminal: what the Neovim writes goes to
-- the fake host (tests/nvim/fakehost.lua), and what the host answers goes to
-- its input, where the TUI parses it and raises TermResponse. The test drives
-- the Neovim over RPC and reads what the host was sent.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root
	.. "/lua/?.lua;"
	.. root
	.. "/lua/?/init.lua;"
	.. root
	.. "/tests/nvim/?.lua;"
	.. root
	.. "/tests/?.lua;"
	.. package.path

local fakehost = require("fakehost")

local W, H = 80, 24

local failures, passed = {}, 0

-- print under nvim -l drops the newline after a long line.
local function say(line)
	io.stdout:write(line, "\n")
end

local function fail(msg)
	error(msg, 0)
end

local function eq(got, want, what)
	if not vim.deep_equal(got, want) then
		fail((what and (what .. ": ") or "") .. "got " .. vim.inspect(got) .. ", want " .. vim.inspect(want))
	end
end

local function wait(cond, what, ms)
	if not vim.wait(ms or 3000, cond, 10) then
		fail("timed out waiting for " .. what)
	end
end

-- A Neovim in a pseudo-terminal, with a fake host for its terminal.
local function spawn(opts)
	opts = opts or {}
	local t = { host = fakehost.new(opts) }
	local sock = vim.fn.tempname()
	t.chan = vim.fn.jobstart({ vim.v.progpath, "--clean", "--listen", sock, "-u", root .. "/tests/nvim/init.lua" }, {
		pty = true,
		width = opts.width or W,
		height = opts.height or H,
		env = { TERM = "xterm-256color", HOTTY_LUA_ROOT = root, NVIM_TEST = "1" },
		on_stdout = function(_, data)
			local answer = t.host:feed(table.concat(data, "\n"))
			if answer ~= "" then
				vim.fn.chansend(t.chan, answer)
			end
		end,
	})
	wait(function()
		return vim.uv.fs_stat(sock) ~= nil
	end, "the Neovim's socket")
	t.rpc = vim.fn.sockconnect("pipe", sock, { rpc = true })
	function t.lua(code, ...)
		local v = vim.rpcrequest(t.rpc, "nvim_exec_lua", code, { ... })
		if v == vim.NIL then
			return nil -- RPC's nil
		end
		return v
	end
	-- What the host sends: an event, say.
	function t.send(bytes)
		vim.fn.chansend(t.chan, bytes)
	end
	function t.stop()
		pcall(vim.rpcnotify, t.rpc, "nvim_command", "qa!")
		vim.wait(200, function()
			return vim.fn.jobwait({ t.chan }, 0)[1] ~= -1
		end, 10)
		vim.fn.jobstop(t.chan)
	end
	-- The Neovim has drawn, and every pass it scheduled has run.
	function t.settle()
		vim.wait(60)
		t.lua("vim.cmd('redraw')")
		vim.wait(60)
	end
	-- The socket and the TUI are there before init.lua has run.
	wait(function()
		return t.lua("return _G.T ~= nil and T.ready == true and #vim.api.nvim_list_uis() > 0")
	end, "the Neovim's start")
	return t
end

-- HOTTY_TEST picks the tests whose names contain it.
local only = os.getenv("HOTTY_TEST")

local function test(name, fn)
	if only and only ~= "" and not name:find(only, 1, true) then
		return
	end
	local t
	local ok, err = pcall(function()
		t = fn(spawn)
	end)
	if type(t) == "table" and t.stop then
		t.stop()
	end
	if ok then
		passed = passed + 1
		say("ok   " .. name)
	else
		failures[#failures + 1] = name .. ": " .. tostring(err)
		say("FAIL " .. name .. ": " .. tostring(err))
	end
end

-- A buffer of 100 lines, and a session whose events and errors land in T.
local SETUP = [[
	local lines = {}
	for i = 1, 100 do lines[i] = "line " .. i end
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	local hn = require("hotty.nvim")
	T.term = hn.term()
	T.session = hn.session({
		prefix = "t",
		on_ready = function(mode, caps)
			T.mode = mode
			T.host = caps and caps.host
		end,
		on_event = function(ev, sf)
			table.insert(T.events, { kind = ev.kind, target = ev.target, name = sf.name })
		end,
		on_error = function(err, sf)
			table.insert(T.errors, { code = err.code, name = sf.name })
		end,
	})
]]

local CARD = [[
	T.card = T.session:surface("card", {
		html = "<button id=go>Go</button> <span id=label></span>",
		anchor = { buf = 0, row = 4, below = true },
		cols = 20,
		rows = 3,
		keep = true,
		on_event = function(ev, sf)
			if ev.kind == "click" and ev.target == "go" then
				sf:set_text("label", "clicked")
			end
		end,
	})
]]

local function card(t)
	t.lua(SETUP)
	wait(function()
		return t.lua("return T.mode") == "native"
	end, "native")
	t.lua(CARD)
	wait(function()
		return t.host.placements["t-card"] ~= nil
	end, "the card's placement")
	return t.host.placements["t-card"]
end

-- Detection -------------------------------------------------------------------

test("a host: detected native, with its capabilities", function(spawn)
	local t = spawn()
	t.lua(SETUP)
	wait(function()
		return t.lua("return T.mode") == "native"
	end, "native")
	eq(t.lua("return T.host"), "fake")
	eq(t.lua("return T.term.caps.v"), "0.2")
	eq(t.host.queries, 1)
	eq(t.host.problems, {})
	return t
end)

test("not a host: text after the DA1 and its grace, and nothing but the query sent", function(spawn)
	local t = spawn({ native = false })
	t.lua(SETUP)
	wait(function()
		return t.lua("return T.mode") == "text"
	end, "text")
	t.lua(CARD)
	t.settle()
	eq(t.host.queries, 1)
	eq(t.host.problems, {})
	eq(t.lua("return T.card.reserved"), 0, "no room made")
	eq(t.lua("return vim.fn.screenpos(0, 6, 1).row"), 6)
	return t
end)

test(
	"late: not a host until one attaches; its late answer makes the session native, and the card is drawn",
	function(spawn)
		local t = spawn({ native = false })
		t.lua(SETUP:gsub('prefix = "t",', 'prefix = "t", late = true,'))
		wait(function()
			return t.lua("return T.mode") == "text"
		end, "text")
		t.lua(CARD)
		t.settle()
		eq(t.host.held, "1", "the query held")
		eq(t.host.placements["t-card"], nil)
		t.send(t.host:become_host())
		wait(function()
			return t.lua("return T.mode") == "native"
		end, "native, late")
		wait(function()
			return t.host.placements["t-card"] ~= nil
		end, "the card's placement")
		eq(t.lua("return T.term.caps.v"), "0.2")
		eq(t.host.queries, 1)
		eq(t.host.problems, {})
		return t
	end
)

test(
	"late: a session that asks after detection settled on text asks again; leaving withdraws the query",
	function(spawn)
		local t = spawn({ native = false })
		t.lua(SETUP)
		wait(function()
			return t.lua("return T.mode") == "text"
		end, "text")
		eq(t.host.held, nil, "nothing held without late")
		t.lua([[T.late = require("hotty.nvim").session({ prefix = "l", late = true })]])
		wait(function()
			return t.host.held == "1"
		end, "a query held for a late answer")
		eq(t.host.queries, 2)
		pcall(vim.rpcrequest, t.rpc, "nvim_command", "qa!")
		wait(function()
			return t.host.withdrawn == 1
		end, "the query withdrawn")
		eq(t.host.held, nil)
		eq(t.host.problems, {})
		return t
	end
)

-- Placement -------------------------------------------------------------------

test("a surface below a line: its document once, placed on the row after, room made", function(spawn)
	local t = spawn()
	local p = card(t)
	eq({ p.x, p.y, p.c, p.r, p.window, p.C }, { 0, 5, 20, 3, nil, true })
	local doc = t.host:commands("doc", "t-card")
	eq(#doc, 1)
	eq(doc[1].payload, "<button id=go>Go</button> <span id=label></span>")
	eq(doc[1].control.q, "1", "a document answers errors")
	eq(doc[1].control.d, nil, "attached")
	eq(t.host:commands("place", "t-card")[1].control.q, "1")
	-- Line 6 is three rows lower: on screen row 8 (0-based), where it was on 5.
	eq(t.lua("return vim.fn.screenpos(0, 6, 1).row"), 9)
	eq(t.host.problems, {})
	return t
end)

test("a surface over a buffer position", function(spawn)
	local t = spawn()
	t.lua(SETUP)
	wait(function()
		return t.lua("return T.mode") == "native"
	end, "native")
	t.lua(
		[[T.session:surface("tag", { html = "<b>!</b>", anchor = { buf = 0, row = 2, col = 3 }, cols = 4, rows = 1 })]]
	)
	wait(function()
		return t.host.placements["t-tag"] ~= nil
	end, "the placement")
	local p = t.host.placements["t-tag"]
	eq({ p.x, p.y, p.c, p.r }, { 3, 2, 4, 1 })
	return t
end)

test("scroll goes with the document; a new scroll sends it again, another key does not", function(spawn)
	local t = spawn()
	t.lua(SETUP)
	wait(function()
		return t.lua("return T.mode") == "native"
	end, "native")
	t.lua([[T.list = T.session:surface("list", {
		html = "<ul></ul>", anchor = { buf = 0, row = 2, col = 0 }, cols = 10, rows = 3, scroll = 1,
	})]])
	wait(function()
		return t.host.placements["t-list"] ~= nil
	end, "the placement")
	eq(t.host:commands("doc", "t-list")[1].control.scroll, "1")
	t.lua("T.list:set({ z = 1 })")
	wait(function()
		local p = t.host.placements["t-list"]
		return p and p.z == 1
	end, "placed again")
	eq(#t.host:commands("doc", "t-list"), 1, "a placement key does not send the document")
	t.lua("T.list:set({ scroll = 0 })")
	wait(function()
		return #t.host:commands("doc", "t-list") == 2
	end, "the document again")
	eq(t.host:commands("doc", "t-list")[2].control.scroll, nil)
	eq(t.host.problems, {})
	return t
end)

test("a click reaches the surface's handler, whose delta reaches the host", function(spawn)
	local t = spawn()
	card(t)
	t.send(t.host:event("t-card", "click", "go"))
	wait(function()
		local d = t.host:commands("delta", "t-card")
		return #d == 1 and d[1].payload == "clicked"
	end, "the delta")
	local d = t.host:commands("delta", "t-card")[1]
	eq({ d.control.op, d.control.t, d.control.q }, { "text", "label", "2" })
	eq(t.lua("return T.events"), { { kind = "click", target = "go", name = "card" } })
	return t
end)

test("events of other surfaces, and other OSCs, are not the session's", function(spawn)
	local t = spawn()
	card(t)
	t.send(t.host:event("someone-else", "click", "go"))
	t.send("\27]11;rgb:ffff/ffff/ffff\27\\")
	t.send(t.host:event("t-card", "zoom", "map", { z = 2 }))
	wait(function()
		return #t.lua("return T.events") == 1
	end, "the zoom")
	eq(t.lua("return T.events"), { { kind = "zoom", target = "map", name = "card" } })
	return t
end)

-- Layout ----------------------------------------------------------------------

test("scrolling moves the surface; out of view, kept, it is hidden; back, placed without its document", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[vim.cmd("normal! 3\5")]])
	wait(function()
		return t.host.placements["t-card"] and t.host.placements["t-card"].y == 2
	end, "the placement on row 2")
	t.lua([[vim.cmd("normal! 2\5")]])
	wait(function()
		return t.host.placements["t-card"] == nil
	end, "the hide")
	eq(#t.host:commands("hide", "t-card"), 1)
	eq(#t.host:commands("del", "t-card"), 0)
	t.lua([[vim.cmd("normal! 5\25")]])
	wait(function()
		return t.host.placements["t-card"] and t.host.placements["t-card"].y == 5
	end, "the placement back on row 5")
	eq(#t.host:commands("doc", "t-card"), 1)
	return t
end)

test("a surface not kept is deleted out of view, and sent again in view", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[T.card:set({ keep = false })]])
	t.lua([[vim.cmd("normal! 6\5")]])
	wait(function()
		return #t.host:commands("del", "t-card") == 1
	end, "the del")
	t.lua([[vim.cmd("normal! 6\25")]])
	wait(function()
		return #t.host:commands("doc", "t-card") == 2 and t.host.placements["t-card"]
	end, "the document again")
	return t
end)

test("a surface set out of view is taken off the screen", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[T.card:set({ anchor = { screen = { 0, 500 } } })]])
	wait(function()
		return #t.host:commands("hide", "t-card") == 1
	end, "the hide")
	eq(t.host.placements["t-card"], nil)
	t.lua([[T.card:set({ anchor = { screen = { 2, 1 } } })]])
	wait(function()
		local p = t.host.placements["t-card"]
		return p and p.x == 2 and p.y == 1
	end, "placed again")
	eq(t.host.problems, {})
	return t
end)

test("a surface past the window's bottom shows the part in view, through a window", function(spawn)
	local t = spawn()
	card(t)
	-- The window shows rows 0 to 21; line 20 is on row 19, so the card
	-- takes rows 20 to 22, and row 22 is the status line.
	t.lua([[T.card:set({ anchor = { buf = 0, row = 19, below = true } })]])
	wait(function()
		local p = t.host.placements["t-card"]
		return p and p.y == 20
	end, "the placement on row 20")
	local p = t.host.placements["t-card"]
	eq(p.window, { x = 0, y = 0, w = 20, h = 2 })
	eq({ p.c, p.r }, { 20, 3 })
	return t
end)

test("edits above the anchor move the surface with its line", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new 1", "new 2" })]])
	wait(function()
		local p = t.host.placements["t-card"]
		return p and p.y == 7
	end, "the placement on row 7")
	return t
end)

test("a fold above the anchor moves the surface up: a redraw with no event of its own", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[vim.cmd("1,3fold")]])
	wait(function()
		local p = t.host.placements["t-card"]
		return p and p.y == 3
	end, "the placement on row 3")
	return t
end)

test("a split: the surface goes with the current window showing its buffer, clipped to it", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[vim.cmd("split")]])
	t.settle()
	-- Two windows of 10 and 11 rows: the top one is current.
	local top = t.host.placements["t-card"]
	eq({ top.x, top.y, top.window }, { 0, 5, nil })
	t.lua([[vim.cmd("wincmd j")]])
	wait(function()
		local p = t.host.placements["t-card"]
		return p and p.y > 10
	end, "the placement in the lower window")
	local info = t.lua("local i = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1] return { i.winrow, i.topline }")
	local p = t.host.placements["t-card"]
	eq(p.y, info[1] - 1 + (5 - (info[2] - 1)), "below line 5 in the lower window")
	return t
end)

test("a floating window over the surface hides it, and closing it places it again", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[
		local b = vim.api.nvim_create_buf(false, true)
		T.float = vim.api.nvim_open_win(b, false, { relative = "editor", row = 6, col = 4, width = 10, height = 2 })
	]])
	wait(function()
		return t.host.placements["t-card"] == nil
	end, "the hide")
	t.lua([[vim.api.nvim_win_close(T.float, true)]])
	wait(function()
		return t.host.placements["t-card"] ~= nil
	end, "the placement again")
	return t
end)

test("rows auto: measured by the first placement, then room made and clipped as any", function(spawn)
	local t = spawn({ auto_rows = 2 })
	t.lua(SETUP)
	wait(function()
		return t.lua("return T.mode") == "native"
	end, "native")
	t.lua(
		[[T.session:surface("auto", { html = "<p>a</p><p>b</p>", anchor = { buf = 0, row = 0, below = true }, cols = 30 })]]
	)
	wait(function()
		return #t.host:commands("place", "t-auto") >= 2
	end, "two placements")
	local places = t.host:commands("place", "t-auto")
	eq(places[1].control.r, "auto")
	eq(places[1].control.q, "0", "numbered, for the rows")
	eq(places[#places].control.r, "2")
	wait(function()
		return t.lua("return vim.fn.screenpos(0, 2, 1).row") == 4
	end, "two rows of room under line 1")
	return t
end)

-- What the host loses ----------------------------------------------------------

test("ENOENT to a placement: the document again, and the placement", function(spawn)
	local t = spawn()
	card(t)
	t.host:forget()
	t.lua([[vim.cmd("normal! \5")]])
	wait(function()
		return #t.host:commands("doc", "t-card") == 2 and t.host.placements["t-card"]
	end, "the document again")
	eq(t.lua("return T.errors"), { { code = "ENOENT", name = "card" } })
	return t
end)

test("the terminal can change: detected again, and the documents sent again", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[vim.api.nvim_exec_autocmds("VimResume", {})]])
	wait(function()
		return t.host.queries == 2 and #t.host:commands("doc", "t-card") == 2
	end, "a second query and document")
	eq(t.lua("return T.mode"), "native")
	return t
end)

test("a resize, which the TUI starts with an erase: every surface placed again", function(spawn)
	local t = spawn()
	card(t)
	local erased = t.host.erased or 0
	vim.fn.jobresize(t.chan, 100, 30)
	wait(function()
		return (t.host.erased or 0) > erased and t.host.placements["t-card"] ~= nil
	end, "the erase, then the placement again")
	local p = t.host.placements["t-card"]
	eq({ p.x, p.y }, { 0, 5 })
	return t
end)

test("relayout(true) places every surface again, changed or not", function(spawn)
	local t = spawn()
	card(t)
	t.lua("T.session:relayout(true)")
	wait(function()
		return #t.host:commands("place", "t-card") == 2
	end, "a second placement")
	return t
end)

-- The terminal's waits ---------------------------------------------------------

test("a request gets its reply; a fence returns when the DA1 behind it arrives", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[
		local hotty = require("hotty")
		T.term:request(function(o) return hotty.hide("t-card", o) end, function(r, err)
			T.reply = r and { ok = r.ok, re = r.re, n = r.n } or err
		end)
		T.term:fence(function(replies) T.fenced = #replies end)
	]])
	wait(function()
		return t.lua("return T.fenced") ~= nil
	end, "the fence")
	local r = t.lua("return T.reply")
	eq({ r.ok, r.re }, { true, "hide" })
	eq(r.n >= 2, true, "never 1")
	return t
end)

test("closing deletes the session's surfaces", function(spawn)
	local t = spawn()
	card(t)
	t.lua("T.session:close()")
	wait(function()
		return t.host.docs["t-card"] == nil
	end, "the del")
	eq(t.lua("return #vim.api.nvim_buf_get_extmarks(0, require('hotty.nvim').namespace, 0, -1, {})"), 0)
	return t
end)

test("examples/nvim/click.lua: a button that counts its clicks", function(spawn)
	local t = spawn()
	t.lua(
		[[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		T.example = dofile(...)
	]],
		root .. "/examples/nvim/click.lua"
	)
	wait(function()
		return t.host.placements["click-example-card"] ~= nil
	end, "the card")
	local p = t.host.placements["click-example-card"]
	eq({ p.x, p.y, p.c, p.r }, { 0, 2, 40, 2 })
	t.send(t.host:event("click-example-card", "click", "go"))
	t.send(t.host:event("click-example-card", "click", "go"))
	wait(function()
		local d = t.host:commands("delta", "click-example-card")
		return #d == 2 and d[2].payload == "2 clicks"
	end, "two deltas")
	eq(t.host:commands("delta", "click-example-card")[1].payload, "1 click")
	-- The second blur may come in a later read than the second delta.
	wait(function()
		return #t.host:commands("blur", "click-example-card") == 2
	end, "the keyboard back to the editor, twice")
	return t
end)

test("examples/nvim/click.lua, not a host: the button in cells", function(spawn)
	local t = spawn({ native = false })
	t.lua(
		[[
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two" })
		dofile(...)
	]],
		root .. "/examples/nvim/click.lua"
	)
	wait(function()
		return #t.lua(
			[[return vim.api.nvim_buf_get_extmarks(0, require("hotty.nvim").namespace, 0, -1, { details = true })]]
		) == 2
	end, "the fallback's virtual line")
	eq(t.host.problems, {})
	return t
end)

test("leaving Neovim deletes every session's surfaces", function(spawn)
	local t = spawn()
	card(t)
	t.lua([[
		T.other = require("hotty.nvim").session({ prefix = "u" })
		T.other:surface("x", { html = "<p>x</p>", anchor = { screen = { 40, 1 } }, cols = 5, rows = 1 })
	]])
	wait(function()
		return t.host.placements["u-x"] ~= nil
	end, "the second session's surface")
	pcall(vim.rpcrequest, t.rpc, "nvim_command", "qa!")
	wait(function()
		return #t.host:commands("del", "t-card") == 1 and #t.host:commands("del", "u-x") == 1
	end, "both deleted")
	return t
end)

say(string.format("nvim    %d passed%s", passed, #failures > 0 and (", " .. #failures .. " failed") or ""))
if #failures > 0 then
	os.exit(1)
end
