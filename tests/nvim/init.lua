-- The Neovim under test: hotty-lua on its runtimepath, and T for the test's
-- state, which tests/nvim/run.lua reads and changes over RPC.
local root = assert(os.getenv("HOTTY_LUA_ROOT"))
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false
vim.o.shada = ""
_G.T = { events = {}, errors = {} }
vim.api.nvim_create_autocmd("VimEnter", {
	callback = function()
		T.ready = true
	end,
})
