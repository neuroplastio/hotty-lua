-- The Neovim of tests/e2e/hottyterm.sh: the click example on a timeline the
-- script screenshots, with what the host sends written to E2E_LOG.
local root = assert(os.getenv("HOTTY_LUA_ROOT"))
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false
local logf = assert(io.open(assert(os.getenv("E2E_LOG")), "w"))
local t0 = vim.uv.hrtime()

local function log(...)
	local parts = { string.format("%6.0f", (vim.uv.hrtime() - t0) / 1e6) }
	for _, v in ipairs({ ... }) do
		parts[#parts + 1] = type(v) == "string" and v or vim.inspect(v, { newline = " ", indent = "" })
	end
	logf:write(table.concat(parts, " "), "\n")
	logf:flush()
end

local function at(ms, what, fn)
	vim.defer_fn(function()
		log("STEP", what)
		local ok, err = pcall(fn)
		if not ok then
			log("ERROR", err)
		end
	end, ms)
end

vim.api.nvim_create_autocmd("VimEnter", {
	callback = function()
		local lines = {}
		for i = 1, 60 do
			lines[i] = ("line %d: some text in the buffer, to scroll past"):format(i)
		end
		vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
		vim.api.nvim_win_set_cursor(0, { 3, 0 })
		local hn = require("hotty.nvim")
		hn.term():listen(function(msg)
			log("MSG", msg.control, msg.payload ~= "" and msg.payload or nil)
		end)
		hn.term():detect(function(mode, caps)
			local w, h = 0, 0
			if caps then
				w, h = caps:cell_css()
			end
			log("MODE", mode, caps and { host = caps.host, version = caps.version, v = caps.v } or nil)
			log("CELL", w, h)
		end)
		local session = dofile(root .. "/examples/nvim/click.lua")
		local card = session.surfaces["click-example-card"]
		local function state()
			log("PLACED", card.placed or "nothing")
		end
		-- The script screenshots each step's frame, and clicks the button
		-- between the first two.
		at(2500, "placed", state)
		at(6000, "clicked", state)
		at(8000, "Ctrl-L", function()
			vim.api.nvim_feedkeys(vim.keycode("<C-l>"), "n", false)
		end)
		at(10000, "scroll 2", function()
			vim.cmd("normal! 2\5")
		end)
		at(10600, "scrolled", state)
		at(12000, "split, then the lower window", function()
			vim.cmd("split")
			vim.cmd("wincmd j")
		end)
		at(12600, "split", state)
		at(14000, "quit", function()
			vim.cmd("qa!")
		end)
	end,
})
