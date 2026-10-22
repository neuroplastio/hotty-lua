# hotty-lua

hotty-lua is the Lua SDK for [hotty](https://github.com/neuroplastio/hotty),
HTML over the TTY. With it, a Lua program shows small HTML documents, called
surfaces, on rectangles of cells, and hears what the user does in them. It
is written for two places: Neovim plugins, and plx scripts.

It speaks hotty 0.5: a host's replies and events carry msgpack bodies
(SPEC §3.3), a delta is one list of ops (SPEC §6.1), keys are named as
myelin key names 0.1 names them (SPEC §10.4), and its query lists the
version it speaks (`a=q:n=1:v=0.5`, SPEC §4). A terminal of another hotty
version, a 0.4 one included, is no host to it, and the program draws in
cells. [Upgrading from 0.4](#upgrading-from-04),
[from 0.3](#upgrading-from-03) and [from 0.2](#upgrading-from-02) list what callers change.

0.5.x speaks hotty 0.5; the patch number is this repository's own. It is
on luarocks.org as `hotty` (0.4.x so far; 0.5.0 is not published yet), for
Lua 5.1 and LuaJIT:

```
luarocks install hotty
```

`luarocks make` builds a checkout, from its rockspec
(`hotty-0.5.0-1.rockspec`).

It meets [SDK.md](https://github.com/neuroplastio/hotty/blob/v0.5.0/SDK.md)
in two layers:

- `require("hotty")` is the **wire layer** (SDK.md §3): it builds commands,
  decodes what the host sends, cuts hotty sequences out of a byte stream,
  decides whether the terminal is a host, and names keys and keymaps. It
  does no I/O. It is Lua 5.1
  and the standard library only, so it runs under Neovim's LuaJIT, plain
  LuaJIT, PUC Lua 5.1, and gopher-lua, which plx embeds and which has no
  `bit` library.
- `require("hotty.nvim")` is the **SDK layer** for Neovim (SDK.md §4.2):
  surfaces anchored to buffer positions, placed where their text is after
  every redraw.
- `require("hotty.plx")` is the **SDK layer** for plx scripts (SDK.md
  §4.2): surfaces at the cells of the script's tool or rail, which plx's
  relay moves with it. plx's own docs have how a script uses it, and the
  limits of gopher-lua that shape this code.

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
| constants (§3.1) | `NUMBER`, `CHUNK`, `MAX_SIZE`, `MAX_NAME`, `VERSION`; `EVENT_CLICK` …, `FEATURES`, `FEATURE_MENU` …, `MOD_SHIFT`, `MOD_ALT`, `MOD_CTRL`, `MOD_SUPER`, `EINVAL` …, `OP_MORPH` …, `REPLY_ALWAYS`, `REPLY_ON_ERROR`, `NO_REPLY`; `SCROLL_VERTICAL`, `SCROLL_HORIZONTAL`; `REVEAL_START` …, `MENU_DEPTH` |
| Control (§3.2) | `hotty.control(pairs)`, `:get(k)` (value, present), `:with(k, v)` |
| Encode (§3.3) | `hotty.encode(control, payload, opts)` |
| commands (§3.4) | `query` (`{ late = true }`), `withdraw_late`, `doc`, `place`, `place_at`, `hide`, `delta`, `set_text`, `set_var`, `set_attr`, `remove_attr`, `morph_to`, `reveal`, `set_field`, `res`, `del_res`, `del`, `del_all`, `detach`, `focus`, `blur`, `edit`, `menu`, `menu_show`, `menu_hide`, `touch`, `sync` |
| ops (§3.4.3) | `morph`, `inner`, `replace`, `append`, `prepend`, `before`, `after`, `remove`, `attr`, `unattr`, `text`, `var`, `reveal_op`: each returns an op, a table with `op`, `target`, `key` and `value`; `delta(surface, ops, opts)` sends a list of them as one delta |
| reply options (§3.4.2) | the last argument: `{ n = 4, q = 2 }`; `doc` also takes `detached = true` and `scroll = hotty.SCROLL_VERTICAL`. `q` goes out only where the wire does not imply it |
| Placement (§3.4.1) | a table: `cols`, `rows`, `window = { x, y, w, h }`, `z`, `press`, `fit`, `hover` (`true` is on, `false` is off, `nil` sends nothing: they belong to the surface), `keep_cursor` |
| a host or a relay | `delta_of(msg)` (the ops, or `nil` and an EINVAL error with `op` the index at fault), `menu_of(msg)`, `menu_show_of(msg)`, `menu_level_of(tree, platform, seq)`, `menu_find(tree, name)`, `read_key(platform, name)` |
| names (§3.5) | `valid_name(s)`, `surface_name(s)` |
| Decoder (§3.6) | `hotty.decoder()`, `:feed(seq)` (result, message), `.invalid` |
| Scanner (§3.7) | `hotty.scanner({ da1 = true })`, `:feed(bytes)` (segments), `:flush()`, `:holding()`, `:in_sequence()`, `.invalid` |
| Detector (§3.8) | `hotty.detector({ n = 1, late = false })`, `:start(now)`, `:da1(now)`, `:reply(r, now)`, `:tick(now)`, `:finish(now)`; `.state`, `.caps`, `.decided`, `.done`, `.deadline` |
| keys (§3.10) | `parse_key(name)`, `read_key(platform, name)`, `decode_keys(input)`, `key_text(key)`, `parse_keymap(platform, value)`, `resolve(platform, multiline, value…)`, `platform_of(caps)`, `default_edit(mod)`, `keymap:binds(key)`, `keymap:lookup(key)`, `keymap:selects(key)`, `keymap:program(key)`, `keymap:prefix(key)`, `keymap:scroll(key)`, `keymap:format()`; `TERMINAL_KEYS`, `ACTIONS`, `MOVES`, `SCROLL_ACTIONS`, `INSERT` |
| messages (§3.9) | `msg:reply()`, `msg:event()`, `msg:body()`; `reply:caps()`, `reply:err()`, `reply.op`; `event:value()`, `:checked()`, `:fields()`, `:mods()`, `:link()`, `:fit_rows()`, `:drag()`, `:hover()`, `:area()`, `:count()`, `:view()`, `:command()`, `:changed()`; `hotty.caps(body)`, `caps:merge(changed)`, `caps.cell_css`, `caps.features` and the other fields; `caps:has(feature)`, `:light()` |

Where Lua differs:

- **`end` is a keyword**, so the Detector's End is `finish`.
  `detector["end"]` is the same function.
- **Segments** are tables, `{ kind = "pass" | "osc" | "da1", data = … }`.
- **A message's control** is a table of keys to values, and `msg.keys` lists
  the keys in the order they came.
- **`link()`** returns two values (`href, url`). `drag()`, `hover()`,
  `area()` and `view()` return tables; `view()`'s is
  `{ areas = { [id] = area }, at_end = bool }`, from the wire's `in` and
  `end`, which are keywords. `fields()` is a list of `{ name, value }` pairs,
  and `mods()` the modifier bits (`MOD_SHIFT` …), 0 when there are none.
- **`caps.cell_css`** is `{ w, h }` in CSS pixels, `nil` when the host said
  none. `reply.op` and an error's `op` are the index of the op at fault as the
  wire has it, from 0, `nil` when there is none.
- **Op builders** take the names SDK.md's Appendix A gives Lua: `hotty.text`,
  `hotty.attr`, `hotty.var` and the rest, and `reveal_op` for `RevealOp`.
  An op is a plain table, `{ op = "text", target = "n", value = "1" }`; its
  `value` is `nil` for an op that takes none.
- **A menu** is a table, `{ label, items = { { key, label, name, enabled,
  items } } }`; `enabled` is true when `nil`. `menu_of` reads one the same
  way, with `""` for what the body leaves out and `enabled` false where it is
  absent.
- **A FieldChange** is a table, `{ rev, value, from, to, text, sel, checked }`,
  each but `rev` absent (`nil`) unless given, so an empty `value` or `text`
  and a position 0 are sent; `sel` is `{ anchor, caret }`. `set_field(surface,
  target, change, opts)` (SPEC §6.4) changes a control unless the user has
  since the `rev` the program last heard (`ev:rev()`); it replies on error
  (`q` 1), and `ESTALE` means the user typed first: do nothing, decide again
  from the next `input`. Positions are bytes of the value's UTF-8, which is
  what Lua's `#` and `string.sub` count. `ev:sel()` is `{ anchor, caret }`, in
  an `input` or a `caret` event (`data-on~=caret`). The sessions have
  `surface:set_field(target, change, opts)`.
- **Touch areas** are tables, `{ c, r, w, h, drag }`: the screen's cells
  where a finger drags as the mouse (SPEC §9.6), counted from 0, and
  `"x"`, `"y"` or `"xy"`. `touch(areas)` names them for the screen it is
  sent on, and `touch()` leaves none.
- **The scroll axes** are also `scroll_vertical` and `scroll_horizontal`,
  as SDK.md's Appendix A spells them for Lua; every other constant here is
  in upper case.
- **`decode_keys`** puts `false` where the input is no key, since `nil`
  would end the list.
- **Characters are code points,** CR LF one: Lua has no grapheme
  segmentation, so `decode_keys` and the Field split `e` and a combining
  accent in two, and the runner skips the vectors that require
  `graphemes` (SDK.md §4.6). Letters are written small, and
  `key_text` and `decode_keys` capitalise them, by the simple case mappings
  of ASCII, Latin-1, Latin Extended, Greek, Cyrillic, Armenian and the
  full-width Latin letters, from a table in `hotty.keys`: the runtimes'
  `string.lower` differs beyond ASCII.
- **A platform** is a table, `{ mod = "ctrl" | "super", edit = … }`, with
  `nil` for the zero Platform (`ctrl`, the default edit shortcuts);
  `platform_of(caps)` makes one. `parse_key` refuses `mod`; `read_key`
  reads it.
- **zlib.** Lua has none. `encode` compresses only when given a compressor
  (`opts.compress`, from bytes to zlib bytes; SDK.md §3.3 has it run at
  zlib's default level, 6), and a host never compresses what it sends (SPEC
  §3.3). The Decoder inflates `o=z` itself, with a
  small inflate in Lua, for a relay or a test that reads a program's output.
  It stops at the decoder's `max` (`opts.max`, 16 MiB by default), as it
  stops joining the chunks of a message that would decode past it.
- **msgpack.** Lua has none either. A host's bodies are msgpack (SPEC
  §3.3): `hotty.msgpack.decode` reads them, in Lua. A delta's ops, a menu
  and touch areas are written by `delta`, `menu` and `touch`, each str,
  int, array and map in the smallest form of its header. `msg:body()` is the
  body it decoded, a map, as a table with no metatable, and its kinds.
- **Numbers are doubles** in Lua 5.1, LuaJIT and gopher-lua, so `7` and
  `7.0` are one number, and a table is a map or an array. So
  `hotty.msgpack.decode` marks what a Lua value cannot show (a float, a
  bin, an array, a timestamp, an extension of another type), and each
  field of a body is read by its type (SDK.md §3.9), as in every other
  SDK: `7.0` in an int field, `2` in a float one, or `[]` in a map one,
  and the body does not decode. An int further than 2^53 − 1 from 0 does
  not decode either. [`docs/plx.md`](docs/plx.md) has the contract.

## Upgrading from 0.4

What a caller changes (SDK.md Appendix E). A program and its tests' fake hosts
move together:

- **`input` and `change` carry `rev`**: `ev:rev()`. A test that expects their
  detail exactly expects it too.
- **Complete a field with `set_field`**, not a new element: it sends the `rev`
  last heard, and the caret goes after the text.
- **`ESTALE` is not a failure.** The user typed first; wait for the next
  `input`, and do not resend with the `rev` the detail names.
- **`caret`** (`EVENT_CARET`) is a new event kind, and `input` carries `sel`
  for a field with `data-on~=caret`.
- **The version is `"0.5"`**: a 0.4 host is no host.

## Upgrading from 0.3

What a caller changes (SDK.md Appendix D). A program, its `data-keys` and
menus, and its tests' fake hosts move together:

- **Every key's name changes** to myelin key names 0.1: `Control+a` is
  `ctrl+a`, `Meta` is `super`, `ArrowLeft` is `arrow_left`, `Enter` is
  `enter`, `Space` is `space`. `hotty.MODIFIERS` is `super ctrl alt shift`.
- **`mod`, not `Mod`.** A binding writes `mod+s`; `mod` with `ctrl` or
  `super` is refused. A host's `mod` is `"ctrl"` or `"super"`, and its
  `edit` names keys the new way. `parse_key` refuses `mod`; a binding read
  on a platform goes through `read_key(platform, name)`, and the keymap
  functions do it themselves.
- **A capital is no Shift.** `G` reads as `g`, so Shift with a letter is
  `shift+g`. `key_text(key)` is what a key types: `shift+a` types `A`. A
  field types `hotty.key_text(key)`, not the key.
- **Shift falls back only from a key that is not a character.** An unbound
  `shift+arrow_left` is looked up as `arrow_left`; `shift+g` is a key of its
  own. `keymap:binds(key)` says whether a keymap binds a key, with that
  fallback, for a host that names a press twice, by its place and by what
  it types (`ctrl+key_w`, `ctrl+w`).
- **`MOD_CONTROL` and `MOD_META`** are `MOD_CTRL` and `MOD_SUPER`, with the
  same bits.
- **The version is `"0.5"`** alone: a 0.4 host is no host.

## Upgrading from 0.2

What a caller changes (SDK.md Appendix C):

- **`delta(surface, op, target, key, payload, opts)` is
  `delta(surface, ops, opts)`**, the ops built by `hotty.text`, `hotty.attr`
  and the rest. A frame's changes to one surface go in one delta. The
  one-op helpers (`set_text`, `set_var`, `set_attr`, `remove_attr`,
  `morph_to`, `reveal`) stay, and so do the sessions' `surface:set_text(…)`
  and the like; `surface:delta(op, target, key, payload, opts)` is
  `surface:delta(ops, opts)`.
- **`press`, `fit` and `hover` belong to the surface.** In a placement,
  `nil` sends nothing and leaves the flag as it was, `true` turns it on
  (`p=1`) and `false` off (`p=0`). A program that placed a surface without
  `press` to stop its presses now sends `press = false`. The sessions send
  them when they change.
- **Ask by feature.** `caps:supports`, `:sends`, `:drags`, `:hovers` and
  `:views`, and the fields `ops`, `events`, `passthrough`, `scroll`, `steps`,
  `drop`, `count`, `keys` and `menu` are gone: `caps:has(feature)` answers for
  `passthrough`, `hover`, `count` and `menu`.
- **The cell is in CSS pixels.** `caps.cell` and `caps:cell_css()` are
  `caps.cell_css`, a table `{ w, h }` or `nil`; there is no `resize` event
  or `ev:size()`: a new font is a `caps` event, which `caps:merge` folds in.
  The sessions keep `caps` current (`term.caps`, `session.caps`) and call
  `on_caps(caps, changed)`.
- **A submit's `ev:fields()`** is a list of `{ name, value }` pairs, in
  order, not a table by name.
- **A drag's `keys`** are `ev:mods()`, bits; clicks and presses carry them.
- **`hotty.menu(level)` is `hotty.menu(tree)`** with `name` and nested
  `items` in place of `seq`, `group` and the level a key reaches; send the
  tree when what the program can do changes, `menu_show(keys)` for each
  key of a sequence, and `menu_hide()` when it ends. A key sequence is the
  program's: bind its leader to `prefix` in the keymap.
- **`q` is left out where the wire implies it.** `{ n = 4 }` alone asks
  for the reply; a fake host answers a command without `q` only with an
  error.

## A field in cells

`hotty.field(opts)` is SDK.md §4.6's Field: a text field's value, caret and
selection, edited as a host edits one on a surface, for a program that
draws its fields in cells. With the same keymap on both sides, a field
edits the same in cells and on a surface, Shift selecting with a move:

```lua
local km = hotty.resolve(hotty.platform_of(caps), false, hotty.TERMINAL_KEYS) -- and data-keys="…" on the surface's root
local f = hotty.field({ value = "foo bar" }) -- opts: value, caret, anchor, multiline, password, rows
for _, key in ipairs(hotty.decode_keys(input)) do
	local action = key and km:lookup(key)
	if action == hotty.INSERT then
		f:type(hotty.key_text(key)) -- in place of the selection
	elseif action and km:selects(key) then
		f:extend(action) -- shift+arrow_left, ctrl+shift+end: the caret moves, the anchor stays
	elseif action and action ~= "submit" then
		f:do_action(action) -- true when the value changed
	end
end
local from, to = f:selection() -- equal when nothing is selected
```

**`do` is a keyword**, so the Field's Do is `do_action`; `f["do"]` is the
same function.

**The selection** runs from `f.anchor`, the end where it began, to the
caret: nothing is selected when the anchor is `nil` or at the caret.
`f:select(anchor, caret)` sets both, for a selection made with the pointer,
and `f:select(p, p)` puts the caret at `p` with nothing selected.

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
	late = true, -- text may turn native later, as in a multiplexer's pane (SPEC §4)
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
  left the alternate screen and its surfaces with it. A host that does not
  speak `VERSION` answers the query with `EVERSION`, and is text, as no
  host is (SPEC §4). It numbers requests
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
- **Flags.** A surface's `press`, `fit` and `hover` are sent with the
  placement when they change, not with every one (SPEC §5.2).
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

## Conformance

`make check` is the gate. It runs, under luajit, lua5.1, `nvim -l` and glua
(gopher-lua v1.1.2, as plx embeds it, built with mise's Go):

- the conformance vectors' SDK sections, `tests/vectors.lua`: wire, build,
  encode, decode, scan, detect, keys, keymap and edit, every vector but
  the few that require `graphemes`;
- the unit tests, `tests/unit.lua`: what the vectors leave out;
- hotty.plx's tests, `tests/plx.lua`, against a fake plx-script (a `ctx`
  with the primitives, and `plx.after` on a clock the test turns), and the
  plx example in it.

And under luajit, `tests/rockspec.lua`: the newest rockspec's MAJOR.MINOR is
`M.VERSION`, its source is its version's tag, and it builds every module in
`lua/hotty/`.

And under `nvim -l`, `tests/nvim/run.lua`: each test runs a Neovim in a
pseudo-terminal, plays its terminal with a fake host
(`tests/nvim/fakehost.lua`, the test host of SDK.md §4.4 as far as these
tests need it), drives it over RPC, and reads what the host was sent.
`HOTTY_TEST=<part of a name>` runs some of them.

CI (`.github/workflows/ci.yml`) runs `make check` on GitHub's hosted
Ubuntu, with Neovim 0.12.5, and checks that the vectors are the spec's.

A release adds the next rockspec, `hotty-X.Y.Z-R.rockspec`, whose source
is the tag `vX.Y.Z`. Once the tag is pushed, `.github/workflows/publish.yml`
(`gh workflow run publish.yml`) runs the gate and uploads the rockspec and
its source rock to luarocks.org.

`make e2e`, outside the gate, runs the click example in hottyterm, a native
host, on the private headless display of hotty-blitz's
`scripts/headless.sh`: it clicks the button through a virtual pointer,
presses Ctrl-L, scrolls and splits, and leaves a screenshot of each in
`$OUT`.

The vectors are a copy of the spec's (`tests/vectors.json`). With a checkout
of neuroplastio/hotty at `HOTTY_DIR` (`../../hotty/main` by default), the
runner fails when the copy differs; `make vectors` updates it.

## Licence

Apache-2.0.
