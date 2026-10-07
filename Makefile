# hotty-lua. luajit, lua5.1 and nvim come from the system; Go (to build glua)
# and stylua from mise.toml: `mise install` first.
MISE        ?= mise x --
GO          ?= $(MISE) go
STYLUA      ?= $(MISE) stylua
NVIM        ?= nvim
HOTTY_DIR   ?= ../../hotty/main
# gopher-lua as plx embeds it (plexos go.mod), and its interpreter.
GOPHER_LUA  ?= v1.1.2
GLUA        := .bin/glua
# Every interpreter the core must run under: Neovim's LuaJIT, plain LuaJIT,
# PUC Lua 5.1, and gopher-lua (no bit library).
RUNTIMES    := luajit lua5.1 "$(NVIM) -l" $(GLUA)

export HOTTY_DIR

# One target at a time: the Neovim tests run on timers.
.NOTPARALLEL:

.PHONY: check fmt fmt-fix core nvim e2e vectors clean

check: fmt core nvim   ## the gate

fmt:   ## fails when stylua would change files
	$(STYLUA) --check $(wildcard lua tests examples)

fmt-fix:
	$(STYLUA) $(wildcard lua tests examples)

core: $(GLUA)   ## the conformance vectors, the unit tests and hotty.plx's, under every runtime
	@for r in $(RUNTIMES); do \
		echo "== $$r"; \
		$$r tests/vectors.lua || exit 1; \
		$$r tests/unit.lua || exit 1; \
		$$r tests/plx.lua || exit 1; \
	done

nvim:   ## hotty.nvim, in a Neovim whose terminal is a fake host (tests/nvim)
	$(NVIM) -l tests/nvim/run.lua

e2e:   ## the click example in hottyterm, on hotty-blitz's headless display; not in the gate
	sh tests/e2e/hottyterm.sh

$(GLUA):
	GOBIN=$(CURDIR)/.bin $(GO) install github.com/yuin/gopher-lua/cmd/glua@$(GOPHER_LUA)

vectors:   ## the conformance vectors, from a checkout of neuroplastio/hotty (HOTTY_DIR)
	cp $(HOTTY_DIR)/conformance/vectors.json tests/vectors.json

clean:
	rm -rf .bin
