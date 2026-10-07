-- A button that counts its clicks: the smallest plx tool that shows a
-- surface of its own and hears it. With plx-script's hotty.plx (plexos
-- vendors lua/hotty/; docs/plx.md), from this repository:
--
--   plx script register examples/plx/click.lua
--   plx tool open hotty-click
--
-- plx knows whether its terminal is a HOTTY host, and its relay places the
-- surface where the tool is on the screen and moves it with the tool.
-- hotty.plx sends the document once, places it in the tool's cells, and
-- hands back what the user did. On a terminal that is not a host, the tool
-- draws the same button in cells.
local hotty = require("hotty")
local hplx = require("hotty.plx")

local state = { clicks = 0 }

local function count()
	return state.clicks == 0 and "no clicks yet" or state.clicks == 1 and "1 click" or (state.clicks .. " clicks")
end

-- The document: HTML, laid out and drawn by the host. Its styles start from
-- the terminal's: its font, its colours (SPEC §8).
local function html()
	return [[
<style>
  body { display: flex; gap: 1ch; align-items: center; }
  button { font: inherit; padding: 0 1ch; }
</style>
<button id=go>Click me</button> <span id=count>]] .. count() .. "</span>"
end

local t = plx.tool({ id = "hotty-click", edge = "right", size = 32 })

-- The session takes the tool's on_hotty, on_hotty_caps and on_resize: a
-- script that sets its own after this calls session:hotty and the rest.
local session = hplx.session(t, {
	on_event = function(ev, surface)
		-- The user clicked: a=ev:s=card:e=click:t=go
		if ev.kind == hotty.EVENT_CLICK and ev.target == "go" then
			state.clicks = state.clicks + 1
			-- The answer is a delta: a=delta:op=text:t=count
			surface:set_text("count", count())
		end
	end,
})

function t.init(ctx)
	session:attach(ctx) -- reads the host plx knows
	local cols = ctx:size()
	state.card = session:surface("card", {
		html = html, -- called each time the document is sent: again on a new host
		x = 0,
		y = 0, -- the tool's top left cell
		cols = cols,
		rows = 2,
	})
end

function t.render(ctx)
	local cols = ctx:size()
	if state.card.spec.cols ~= cols then
		state.card:set({ cols = cols }) -- placed again only when it changed
	end
	if session:native() then
		return ui.box({ h = 2 }) -- the cells under the surface
	end
	local go = ctx:el("btn", "go", { on = { click = "go" } })
	return ui.box({
		dir = "row",
		gap = 1,
		ui.text({ id = go, fg = "accent", "[ Click me ]" }),
		ui.text({ fg = "muted", count() }),
	})
end

-- The cells' click. The surface's click reaches here too (ev.source "hotty"),
-- after the session's on_event has had it.
function t.on_event(ctx, ev)
	if ev.source == "cells" and ev.handler == "go" then
		state.clicks = state.clicks + 1
	end
end
