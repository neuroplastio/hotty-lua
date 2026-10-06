# hotty-lua in plx

What a plx adapter for hotty-lua would need, from plexos as of 36cb03b
(2026-10-06). Nothing here changes plexos; it is for whoever owns it.

## What runs today

- **The wire layer loads.** plx-script (`cmd/plx-script/vm.go`) makes each
  script's state with `lua.NewState()`: gopher-lua v1.1.2, its default
  options, every standard library, and no `bit`. `make check` runs the
  conformance vectors and the unit tests under glua v1.1.2, the same
  interpreter. A script finds the SDK by adding its `lua/` directory to
  `package.path`, which plx leaves at gopher-lua's default.
- **A program in a pane needs nothing.** A pure Lua program (luajit,
  lua5.1, glua) in a plx pane that speaks HOTTY on its own terminal is
  already served by plx: plxd answers its query, `pkg/hottyrelay` names its
  surfaces, places them in the pane, and writes its events back to its
  input. With the wire layer it would read its terminal raw, with
  `hotty.scanner({ da1 = true })` and a Detector on its own clock; that is
  the Terminal of SDK.md §4.1, which hotty-lua does not have yet for plain
  Lua (it has no way to read a terminal without a C module, and luajit's FFI
  is the only one at hand).

## What a plx script lacks

A script is a tool or a rail (`plx.tool{…}`, `plx.rail{…}`), run in its own
process in a pty, and draws with `ui.*` elements. Its HOTTY today is
`ui.hotty{id, html, css}`, `ctx:hotty()` (the host's name, version and
scheme) and events through `on_event` with `source = "hotty"`. An adapter
of SDK.md §4.2 would need, from plx:

1. **The capabilities, whole.** `ctx:hotty()` gives `v`, `host`, `scheme`
   and `dark`; the SDK reads every field (`hotty.caps(table)` takes the
   decoded object). plx already pushes the full caps to tools as the
   `hotty.caps` notification; handing the script the decoded object, or
   the raw JSON, is enough. A script would then not detect at all: plx
   knows (SDK.md §4.1's `known`).
2. **A way to send commands for its own surfaces**, at least `doc`, `delta`
   and `del`, with the relay keeping its prefix and placement: the
   builders' output (`hotty.set_text(...)`) as bytes, or the decoded
   messages. Writing raw OSC 7279 to stdout reaches the relay today (gopher-
   lua's `io.stdout` is the tool's pty, which plx scans), but it mixes with
   plxdk's own writes, and a query there is never answered.
3. **Events as messages.** `on_event` gets plx's own event table; the SDK's
   `Event` accessors (`value()`, `fields()`, `drag()` …) need the control
   and the payload: either `hotty.decoder()` fed the raw sequence, or plx
   building an `Event` with `hotty.Message`.
4. **Replies.** The errors of `q=1` commands, and the replies of numbered
   ones, for requests and for `ENOENT` (a lost document).
5. **One-shot timers.** `plx.timer(ms, fn)` repeats, from 100 ms, and only
   while the tool is shown. Requests (3 s), fences (1 s) and the Detector
   need a one-shot timer, or a clock (`now`) and a tick the script can ask
   for.
6. **Geometry and its changes.** A tool's own surfaces are placed by plx
   (the relay moves and clips them with the pane), so a script that only
   shows its own documents needs none. One that places surfaces itself
   needs its cell size and an event when it changes; today a resize only
   calls `render`.

## gopher-lua, for any script

Three limits of gopher-lua v1.1.2 under plx's default options shaped
hotty-lua, and bite any plx script:

- `table.concat` overflows the fixed-size registry at a few thousand
  strings ("registry overflow").
- A pattern with a repetition over long input fails ("pattern/input too
  complex").
- Once `pcall` catches an error, a closure no longer shares its caller's
  locals: the caller's open upvalues are closed with the error.

```lua
local c = 0
local function inc() c = c + 1 end
inc(); pcall(error, "x"); inc()
print(c) -- 2 in Lua 5.1 and LuaJIT, 1 in gopher-lua v1.1.2
```

The first two are options plx could raise (`RegistrySize`,
`RegistryMaxSize`); the third is a bug to report upstream, or to fix in a
fork.
