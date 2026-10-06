-- A button below the cursor's line that counts its clicks: the smallest
-- Neovim plugin that shows a surface and hears it. In a HOTTY host
-- (hottyterm, say), from this repository:
--
--   nvim -c "set rtp+=." -c "luafile examples/nvim/click.lua"
--
-- The HOTTY in it is three things: a document whose ids are the program's
-- handles, an event that names one of them, and a delta that changes the
-- host's copy of the document. hotty.nvim does the rest: it asks the
-- terminal whether it is a host, places the surface where its line is after
-- each redraw, and makes room for it.
local hotty = require("hotty")
local hn = require("hotty.nvim")

local buf = vim.api.nvim_get_current_buf()
local row = vim.api.nvim_win_get_cursor(0)[1] - 1
local clicks = 0

local session = hn.session({
	prefix = "click-example", -- surface names start with it: click-example-card
	on_ready = function(mode)
		if mode == hotty.TEXT then
			-- Not a host: the same thing, in cells.
			vim.api.nvim_buf_set_extmark(buf, hn.namespace, row, 0, {
				virt_lines = { { { "[ Click me ]  (this terminal shows no surfaces)", "Comment" } } },
			})
		end
	end,
})

-- The document: HTML, laid out and drawn by the host. Nothing runs in it;
-- the ids are how the program hears it and changes it. Its styles start
-- from the terminal's: its font, its colours (SPEC §8).
local html = [[
<style>
  body { display: flex; gap: 1ch; align-items: center; }
  button { font: inherit; padding: 0 1ch; }
</style>
<button id=go>Click me</button> <span id=count>no clicks yet</span>
]]

session:surface("card", {
	html = html, -- sent as a=doc:s=click-example-card
	anchor = { buf = buf, row = row, below = true }, -- the rows below the line, made with virtual lines
	cols = 40,
	rows = 2, -- placed as a=place:c=40:r=2, at the cell the line's rows end on
	keep = true, -- scrolled out of view: hidden (a=hide), not deleted
	on_event = function(ev, surface)
		-- The user clicked: a=ev:s=click-example-card:e=click:t=go
		if ev.kind == hotty.EVENT_CLICK and ev.target == "go" then
			clicks = clicks + 1
			-- The program answers with a delta: a=delta:op=text:t=count
			surface:set_text("count", clicks == 1 and "1 click" or (clicks .. " clicks"))
			-- A button takes the keyboard when clicked (SPEC §10.1), and would
			-- keep Enter and Space from the editor: give it back (a=blur).
			surface:blur()
		end
	end,
})

return session
