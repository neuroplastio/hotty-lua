# hotty-lua in plx

How hotty-lua runs in plx, and what `hotty.plx`, the adapter of SDK.md §4.2
for plx scripts, is built on. plexos owns plx's side; this is what the two
agreed on 2026-10-07 (plexos `vault/tasks/hotty-sdks.md`, HOTTY-LUA-01).

## What runs today

- **plx-script has the wire layer built in.** Since plexos 8b1b3a0 it vendors
  a pinned copy of `lua/hotty/` (all but `nvim.lua`), embeds it, and
  preloads it into every script's state, so `require("hotty")` works with
  no `package.path`. `make hotty-lua REV=<sha>` in plexos refreshes the copy.
  The state is gopher-lua v1.1.2 with every standard library, no `bit`, and
  a registry raised for `table.concat` over many strings. `make check` here
  runs the conformance vectors and the unit tests under glua v1.1.2, the
  same interpreter.
- **A program in a pane needs nothing.** A pure Lua program (luajit,
  lua5.1, glua) in a plx pane that speaks HOTTY on its own terminal is
  already served by plx: plxd answers its query, `pkg/hottyrelay` names its
  surfaces, places them in the pane, and writes its events back to its
  input. With the wire layer it would read its terminal raw, with
  `hotty.scanner({ da1 = true })` and a Detector on its own clock; that is
  the Terminal of SDK.md §4.1, which hotty-lua does not have yet for plain
  Lua (it has no way to read a terminal without a C module, and luajit's FFI
  is the only one at hand).

## Native modules

`init.lua` reaches base64 and zlib only through `require("hotty.base64")`
and `require("hotty.inflate")`, when it loads. A host may put its own
modules with the same functions in `package.preload` (or `package.loaded`)
before the first `require("hotty")`; plx does, for base64, since gopher-lua
runs the Lua one at a few MB/s. `tests/unit.lua` checks that `init.lua`
uses what it is given, and pins the edges below.

- `hotty.base64.encode(s)`: the base64 of `s`, standard alphabet, padded.
- `hotty.base64.decode(s)`: the bytes, or nil. It removes every byte Lua's
  `%s` matches (space, `\t`, `\n`, `\v`, `\f`, `\r`), then up to two `=`
  at the end whatever the length; nil if a byte outside `A-Za-z0-9+/` is
  left, or the length is one more than a multiple of 4. Bits past the last
  byte are ignored.
- `hotty.inflate.zlib(s)`: the bytes, or nil and an error: a header that
  is not deflate (method 8, a window of at most 32 KiB, the check), a preset
  dictionary, a bad stream, an Adler-32 that does not match, or more than
  `MAX` bytes out (16 MiB; `init.lua` does not read it). Bytes after the
  checksum are ignored.

`hotty.json` and `hotty.join` are not seams: decode marks its tables
(`json.is_object`, `json.is_array`, `json.null`), and `hotty.caps` and
`Event` read those marks.

## The primitives

`hotty.plx` is a push environment: plx knows the host, reads the terminal
and writes for the script, so the adapter needs no Scanner, no Detector and
no fences. What plx-script gives it, as agreed:

1. **The caps, whole.** `ctx:hotty()` keeps `{ v, host, scheme, dark }`
   (nil for no host) and gains `raw`, the caps JSON as plx relays it. A
   change of host, and only a change (never the start), calls
   `on_hotty_caps(ctx, raw)`, raw nil for none, before the `on_show` it
   causes; it draws no frame itself. The adapter reads
   `hotty.caps(hotty.json.decode(raw))` and sends its documents again.
2. **Sending.** `ctx:hotty_send(s)` writes HOTTY commands (the builders'
   strings) for the script's own surfaces to the instance's output, in
   order with plx's frames and never inside one. The relay prefixes the
   names, and places them in the instance's own cells, moved and clipped
   with it. Any action passes; `a=q` is never answered. A name a `ui.hotty`
   uses is not the script's to send. It returns true toward a host; false,
   sending nothing, when there is none; and false and an error when the
   write fails. The relay takes `res`, `del`, `doc`, `delta`, `focus`,
   `blur`, `hide` and `place`, and ignores `detach`.
3. **Input.** `on_hotty(ctx, seq)` gets every HOTTY message plx routes to
   the instance, events and replies, each as one complete OSC 7279 sequence
   the way a host writes it (a long one chunked, several calls), never
   compressed, the surface named as the script named it. The adapter feeds
   one `hotty.decoder()` with every call. Each event then reaches
   `on_event` too, and one frame follows.
4. **Replies.** The relay numbers what it forwards on the host itself and
   hands back what a script's command asked for, through `on_hotty` (no
   `on_event` follows): an error unless `q=2`, an `ok` only when numbered
   (`q=0`). The reply carries the script's own `n` (none if it gave none),
   `s` renamed back when the host's has one, and the rest as the host wrote
   it; a resource's (`res`, `del` of one) is answered by `n` alone. For
   `doc`, `delta`, `res`, `del`, `focus` and `blur`, and for placements:
   - a numbered place with its rows given is answered at once, with its
     `c` and `r`;
   - at `r=auto` the relay measures on the next frame that shows the
     instance, and answers with the host's rows, so a hidden tool's answer
     can come after hotty.plx stopped waiting (it keeps the rows then);
   - the relay places a script's surfaces itself, so when the host rejects
     its placement of one (`ENOENT`: the host lost the document) the error
     goes to the script as `re=place`, if the script's last place of it
     asked for errors (`q` ≤ 1): with that place's `n` until its `ok` was
     given, and none after;
   - a numbered `hide` is answered too.
5. **Time.** `plx.after(ms, fn)` runs `fn(ctx)` once, shown or hidden, then
   draws when shown, and returns a handle with `:cancel()`; not at the top
   level. `plx.now()` is milliseconds on a monotonic clock. Requests time
   out on it.
6. **Geometry.** `ctx:size()` is the instance's cells, and
   `on_resize(ctx, cols, rows)` runs before the frame at the new size (a
   rail's rows are 1). A cell's pixels are in the caps (`cell`, `scale`).

`plx.has("hotty_send")` says whether a plx-script has 1–3, and
`plx.has("after")` whether it has 5. In plexos, 7a37ef4 has the seam,
6fedf38 has 1–3, 5 and 6, and 5ba420f and dee0eb4 have 4; dee0eb4 vendors
hotty-lua 8ee7185. A pane program's replies are still the plxd's own
(plexos HOTTY-PANE-REPLY-01, for the maintainer). hotty.plx (`lua/hotty/plx.lua`, the README's plx
section) is built on them, and `tests/plx.lua` tests it against a fake
plx-script with these details. Without `ctx:hotty_send`, a session is in
text mode.

## gopher-lua, for any script

Three limits of gopher-lua v1.1.2 shaped hotty-lua, and bite any plx
script:

- `table.concat` overflows the fixed-size registry at a few thousand
  strings ("registry overflow"). `RegistrySize` and `RegistryMaxSize` are
  options; plx-script raises them for every state.
- A pattern with a repetition over long input fails ("pattern/input too
  complex"). The limit is a constant in gopher-lua's `pm` package
  (`maxRecursionLevel`), not an option, so code avoids such patterns.
- Once `pcall` catches an error, a closure no longer shares its caller's
  locals: the caller's open upvalues are closed with the error.

```lua
local c = 0
local function inc() c = c + 1 end
inc(); pcall(error, "x"); inc()
print(c) -- 2 in Lua 5.1 and LuaJIT, 1 in gopher-lua v1.1.2
```

The third is a bug to report upstream, or to fix in a fork.
