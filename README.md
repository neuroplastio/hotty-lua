# hotty-lua

hotty-lua is the Lua SDK for [HOTTY](https://github.com/neuroplastio/hotty),
HTML Over The TTY. With it, a Lua program shows small HTML documents, called
surfaces, on rectangles of cells, and hears what the user does in them. It
is written for two places: Neovim plugins, and plx scripts.

It meets [SDK.md](https://github.com/neuroplastio/hotty/blob/main/SDK.md)
in two layers:

- `require("hotty")` is the **wire layer** (SDK.md §3): it builds commands,
  decodes what the host sends, cuts HOTTY sequences out of a byte stream,
  and decides whether the terminal is a host. It does no I/O. It is Lua 5.1
  and the standard library only, so it runs under Neovim's LuaJIT, plain
  LuaJIT, PUC Lua 5.1, and gopher-lua, which plx embeds and which has no
  `bit` library.
- `require("hotty.nvim")` is the **SDK layer** for Neovim (SDK.md §4.2):
  surfaces anchored to buffer positions, placed where their text is after
  every redraw.

```lua
local hotty = require("hotty")

-- A document, placed at screen cell (4, 2): what a program writes.
local out = hotty.doc("demo-card", "<button id=go>Go</button>")
	.. hotty.place_at("demo-card", 4, 2, { cols = 20, rows = 1 })

-- What the host sends back, one OSC sequence at a time.
local dec = hotty.decoder()
local result, msg = dec:feed("\27]7279;a=ev:s=demo-card:e=click:t=go\27\\")
local ev = result == hotty.COMPLETE and msg:event()
if ev and ev.kind == hotty.EVENT_CLICK then
	-- ev.surface == "demo-card", ev.target == "go"
end
```

## The wire layer

The names are SDK.md's canonical ones in snake case (Appendix A). Options
are a table, absence is `nil`, and a function that fails returns `nil` and
an error.

| SDK.md | hotty |
| --- | --- |
| constants (§3.1) | `NUMBER`, `CHUNK`, `MAX_SIZE`, `MAX_NAME`, `VERSION`; `EVENT_CLICK` …, `EINVAL` …, `OP_MORPH` …, `REPLY_ALWAYS`, `REPLY_ON_ERROR`, `NO_REPLY` |
| Control (§3.2) | `hotty.control(pairs)`, `:get(k)` (value, present), `:with(k, v)` |
| Encode (§3.3) | `hotty.encode(control, payload, opts)` |
| commands (§3.4) | `query`, `doc`, `place`, `place_at`, `hide`, `delta`, `set_text`, `set_var`, `set_attr`, `remove_attr`, `morph_to`, `res`, `del_res`, `del`, `del_all`, `detach`, `focus`, `blur`, `sync` |
| reply options (§3.4.2) | the last argument: `{ n = 4, q = 2, detached = true }` |
| Placement (§3.4.1) | a table: `cols`, `rows`, `window = { x, y, w, h }`, `z`, `press`, `fit`, `hover`, `keep_cursor` |
| names (§3.5) | `valid_name(s)`, `surface_name(s)` |
| Decoder (§3.6) | `hotty.decoder()`, `:feed(seq)` (result, message), `.invalid` |
| Scanner (§3.7) | `hotty.scanner({ da1 = true })`, `:feed(bytes)` (segments), `:flush()`, `:holding()`, `.invalid` |
| Detector (§3.8) | `hotty.detector({ n = 1 })`, `:start(now)`, `:da1(now)`, `:reply(r, now)`, `:tick(now)`, `:finish(now)`; `.state`, `.caps`, `.decided`, `.done`, `.deadline` |
| messages (§3.9) | `msg:reply()`, `msg:event()`; `reply:caps()`, `reply:err()`; `event:value()`, `:checked()`, `:fields()`, `:link()`, `:size()`, `:fit_rows()`, `:drag()`, `:hover()`; `caps:supports(op)`, `:sends(kind)`, `:drags()`, `:hovers()`, `:light()`, `:cell_css()` |

Where Lua differs:

- **`end` is a keyword**, so the Detector's End is `finish`.
  `detector["end"]` is the same function.
- **Segments** are tables, `{ kind = "pass" | "osc" | "da1", data = … }`.
- **A message's control** is a table of keys to values, and `msg.keys` lists
  the keys in the order they came.
- **`link()` and `size()`** return two values (`href, url`; `w, h`), and
  `cell_css()` returns `w, h`. `drag()` and `hover()` return tables.
- **zlib.** Lua has none. `encode` compresses only when given a compressor
  (`opts.compress`, from bytes to zlib bytes), and a host never compresses
  what it sends (SPEC §3.3). The Decoder inflates `o=z` itself, with a
  small inflate in Lua, for a relay or a test that reads a program's output.

## Neovim

Neovim owns the terminal, so hotty.nvim reads nothing itself. The TUI hands
over each OSC sequence and each DA1 answer as `TermResponse`, without its
terminator, and the Decoder and the Detector take them from there; a plugin
writes with `nvim_ui_send`. It needs Neovim 0.12 (`nvim_ui_send`).

```lua
local hotty, hn = require("hotty"), require("hotty.nvim")

local session = hn.session({
	prefix = "myplugin", -- surface names: myplugin-<name>
	on_ready = function(mode, caps) end, -- "native", or "text": draw in cells
})

session:surface("card", {
	html = "<button id=go>Go</button> <span id=out></span>",
	anchor = { buf = 0, row = 4, below = true }, -- the rows below line 5
	cols = 40,
	rows = 2,
	keep = true,
	on_event = function(ev, surface)
		if ev.kind == hotty.EVENT_CLICK and ev.target == "go" then
			surface:set_text("out", "gone")
		end
	end,
})
```

[`examples/nvim/click.lua`](examples/nvim/click.lua) is that, whole.

- **The terminal** (`hn.term()`) is one per Neovim. It detects whether the
  terminal is a host, and again when the terminal can have changed: a UI
  attached (`UIEnter`), or a return from suspension (`VimResume`), which
  left the alternate screen and its surfaces with it. It numbers requests
  (`term:request(build, cb)`, 3 s) and fences (`term:fence(cb)`, 1 s), and
  hands every message no wait took to the sessions and to `term:listen(fn)`.
- **A session** (`hn.session(opts)`) holds a plugin's surfaces. A surface's
  anchor is a buffer position (`{ buf, row, col }`, an extmark, so it moves
  with edits), the rows below a line (`{ buf, row, below = true }`, with room
  made by virtual lines), or a screen cell (`{ screen = { x, y } }`).
- **Layout.** After the editor draws, the session places each surface at
  its anchor's cell, clipped to its window's text with a placement window,
  and sends only what changed: the document once, a placement when it moved,
  `hide` (with `keep`) or `del` when it went out of view. The passes run on
  `vim.schedule` from the editor's events (`WinScrolled`, `WinResized`,
  `VimResized`, `WinEnter`, `TextChanged`, …) and from every redraw (a
  decoration provider's `on_end`), since `nvim_ui_send`'s bytes go out at
  once while the TUI writes its frame when it flushes: sent from the event
  itself, a placement would land before the cells it goes with.
- **Floating windows and the popup menu** are cells, and every placement is
  above the cells (SPEC §5.2), so a surface they would cover is hidden while
  they do (`occlude = false` turns that off).
- **What the host loses** (`ENOENT` in answer to a placement) is sent again.
  A resize places every surface again: the TUI starts its redraw with an
  erase in display, which takes placements with it (SDK.md §4.3).
  `session:relayout(true)` places every surface again, changed or not.
- **Not yet: Ctrl-L.** Ctrl-L (and `:mode`) erases the screen too, and
  Neovim raises no event for it, so a surface stays gone until something
  moves it, or until the program calls `relayout(true)`. Which event
  should tell the adapter is an open question.
- **Rows auto** (`rows = nil`): the first placement is numbered, and the
  rows the host chose are kept; `fit = true` keeps them current.
- **Closing.** `session:close()` deletes the surfaces, `session:detach_all()`
  leaves them on the screen, detached. Sessions close on `VimLeavePre`.

## plx

The wire layer loads in plx's gopher-lua as it is, and a Lua program in a
plx pane is served by plx's relay like any other. plx-script does not yet
give a script what an SDK layer needs; [`docs/plx.md`](docs/plx.md) says
what it would.

## Conformance

`make check` is the gate. It runs, under luajit, lua5.1, `nvim -l` and glua
(gopher-lua v1.1.2, as plx embeds it, built with mise's Go):

- the conformance vectors' SDK sections, `tests/vectors.lua`: wire, build,
  encode, decode, scan and detect, every vector;
- the unit tests, `tests/unit.lua`: what the vectors leave out.

And under `nvim -l`, `tests/nvim/run.lua`: each test runs a Neovim in a
pseudo-terminal, plays its terminal with a fake host
(`tests/nvim/fakehost.lua`, the test host of SDK.md §4.4 as far as these
tests need it), drives it over RPC, and reads what the host was sent.
`HOTTY_TEST=<part of a name>` runs some of them.

The vectors are a copy of the spec's (`tests/vectors.json`). With a checkout
of neuroplastio/hotty at `HOTTY_DIR` (`../../hotty/main` by default), the
runner fails when the copy differs; `make vectors` updates it.

## gopher-lua

plx runs scripts in gopher-lua v1.1.2 with its default options. Three of its
limits shape this code, and any plx script:

- **`table.concat` overflows** its fixed-size registry at a few thousand
  strings, so the SDK joins in batches (`hotty.join`).
- **Its pattern matcher gives up** on a repetition over long input
  ("pattern/input too complex"), so nothing matches a pattern with `*` over
  a payload.
- **Once `pcall` catches an error, a closure no longer shares its caller's
  locals**: the caller's open upvalues are closed with the error. The SDK
  keeps what it changes in tables.

## Licence

Apache-2.0.
