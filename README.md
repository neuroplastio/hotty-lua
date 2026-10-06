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
- `require("hotty.nvim")` is the **SDK layer** for Neovim (SDK.md §4.2).
  It is still being written.

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

## Conformance

`make check` is the gate. It runs, under luajit, lua5.1, `nvim -l` and glua
(gopher-lua v1.1.2, as plx embeds it, built with mise's Go):

- the conformance vectors' SDK sections, `tests/vectors.lua`: wire, build,
  encode, decode, scan and detect, every vector;
- the unit tests, `tests/unit.lua`: what the vectors leave out.

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
