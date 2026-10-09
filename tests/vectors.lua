-- Runs the conformance vectors' SDK sections against hotty: wire, build,
-- encode, decode, scan, detect, keys, keymap and edit (conformance/README.md
-- in neuroplastio/hotty). Characters are code points here, so the vectors
-- that require graphemes are skipped.
--
--   <lua> tests/vectors.lua [vectors.json]
--
-- under luajit, lua5.1, nvim -l and glua (gopher-lua). It reads the vectors
-- with hotty.json; under nvim -l it first checks that reading against
-- vim.json's, so that the decoder under test is not the only judge of what
-- the vectors say.

local root = ((arg and arg[0]) or ""):match("^(.-)/?tests/[^/]*$") or "."
if root == "" then
	root = "."
end
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local hotty = require("hotty")
local json = hotty.json
local null = json.null

-- What this SDK implements, for vectors marked "requires".
local FEATURES = {
	["place.hover"] = true,
	["event.hover"] = true,
	["caps.passthrough"] = true,
	["caps.version"] = true,
	["caps.lenient"] = true,
	["caps.drag-kinds"] = true,
	["options.unordered"] = true,
	["doc.scroll"] = true,
	["event.area"] = true,
	["caps.scroll"] = true,
	["decode.abort-count"] = true,
	["decode.unterminated"] = true,
	["scanner.da1"] = true,
}

local function runtime()
	if vim then
		return "nvim " .. tostring(vim.version())
	elseif jit then
		return jit.version
	end
	return _VERSION .. (rawget(_G, "channel") and " (gopher-lua)" or "")
end

local function read(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local s = f:read("*a")
	f:close()
	return s
end

local function show(v, depth)
	depth = depth or 0
	if v == nil or v == null then
		return "null"
	elseif type(v) == "string" then
		return string.format("%q", #v > 80 and (v:sub(1, 80) .. "…") or v)
	elseif type(v) ~= "table" or depth > 3 then
		return tostring(v)
	end
	local keys = {}
	for k in pairs(v) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local out = {}
	for _, k in ipairs(keys) do
		out[#out + 1] = tostring(k) .. "=" .. show(v[k], depth + 1)
	end
	return "{" .. table.concat(out, ", ") .. "}"
end

local function absent(v)
	return v == nil or v == null
end

-- Exact equality of plain data: tables by keys, null as nil, numbers as numbers.
local function equal(a, b)
	if absent(a) and absent(b) then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not equal(v, b[k]) then
			return false
		end
	end
	for k, v in pairs(b) do
		if absent(a[k]) and not absent(v) then
			return false
		end
	end
	return true
end

-- Every key of want matches got: objects recursively, anything else exactly.
local function match(got, want, path)
	for k, w in pairs(want) do
		local g = got[k]
		local where = path .. "." .. tostring(k)
		if json.is_object(w) then
			if type(g) ~= "table" then
				return false, where .. " = " .. show(g) .. ", want " .. show(w)
			end
			local ok, why = match(g, w, where)
			if not ok then
				return ok, why
			end
		elseif not equal(g, w) then
			return false, where .. " = " .. show(g) .. ", want " .. show(w)
		end
	end
	return true
end

-- A builder's or encoder's output as {raw = text} and {osc = seq} segments.
local function segments(out)
	local sc = hotty.scanner()
	local segs = sc:feed(out)
	for _, s in ipairs(sc:flush()) do
		segs[#segs + 1] = s
	end
	return segs
end

-- wire ------------------------------------------------------------------------

local function run_wire(v)
	local sc, dec = hotty.scanner(), hotty.decoder()
	local segs = sc:feed(v.stream)
	for _, s in ipairs(sc:flush()) do
		segs[#segs + 1] = s
	end
	local got = {}
	for _, s in ipairs(segs) do
		if s.kind == "osc" then
			local result, m = dec:feed(s.data)
			if result == hotty.COMPLETE then
				got[#got + 1] = m
			end
		end
	end
	local invalid = sc.invalid + dec.invalid
	if invalid ~= v.invalid then
		return false, "invalid " .. invalid .. ", want " .. v.invalid
	end
	if #got ~= #v.commands then
		return false, #got .. " commands, want " .. #v.commands
	end
	for i, m in ipairs(got) do
		local want = v.commands[i]
		if m.control.m or m.control.o then
			return false, "m or o left in " .. show(m.control)
		end
		for k, val in pairs(want.control) do
			if m.control[k] ~= val then
				return false, k .. "=" .. show(m.control[k]) .. ", want " .. show(val)
			end
		end
		if m.payload ~= want.payload then
			return false, "payload " .. show(m.payload)
		end
	end
	return true
end

-- build -----------------------------------------------------------------------

local function placement(p)
	local w = not absent(p.window) and { x = p.window.x, y = p.window.y, w = p.window.w, h = p.window.h } or nil
	return {
		cols = p.cols,
		rows = p.rows,
		window = w,
		z = p.z,
		press = p.press,
		fit = p.fit,
		hover = p.hover,
		keep_cursor = p.keep_cursor,
	}
end

local function build(b)
	local a = b.args or {}
	local o = b.options or {}
	local opts = { n = o.n, q = o.q, detached = o.detached, scroll = o.scroll }
	local name = b.build
	if name == "query" then
		return hotty.query(a.n, { late = o.late })
	elseif name == "withdraw_late" then
		return hotty.withdraw_late()
	elseif name == "doc" then
		return hotty.doc(a.surface, a.html, opts)
	elseif name == "place" then
		return hotty.place(a.surface, placement(a.placement), opts)
	elseif name == "place_at" then
		return hotty.place_at(a.surface, a.x, a.y, placement(a.placement), opts)
	elseif name == "hide" then
		return hotty.hide(a.surface, opts)
	elseif name == "delta" then
		return hotty.delta(a.surface, a.op, a.target, a.key, a.payload, opts)
	elseif name == "set_text" then
		return hotty.set_text(a.surface, a.target, a.text, opts)
	elseif name == "set_var" then
		return hotty.set_var(a.surface, a.target, a.name, a.value, opts)
	elseif name == "set_attr" then
		return hotty.set_attr(a.surface, a.target, a.name, a.value, opts)
	elseif name == "remove_attr" then
		return hotty.remove_attr(a.surface, a.target, a.name, opts)
	elseif name == "morph_to" then
		return hotty.morph_to(a.surface, a.target, a.html, opts)
	elseif name == "res" then
		return hotty.res(a.id, a.mime, a.data, opts)
	elseif name == "del_res" then
		return hotty.del_res(a.id, opts)
	elseif name == "del" then
		return hotty.del(a.surface, opts)
	elseif name == "del_all" then
		return hotty.del_all(opts)
	elseif name == "detach" then
		return hotty.detach(a.surface, opts)
	elseif name == "focus" then
		return hotty.focus(a.surface, a.target, opts)
	elseif name == "blur" then
		return hotty.blur(a.surface, opts)
	elseif name == "sync" then
		local cmds = {}
		for i, c in ipairs(a.commands) do
			cmds[i] = build(c)
		end
		return hotty.sync(cmds)
	end
	error("no builder " .. tostring(name))
end

local function run_build(v)
	local got = {}
	local dec = hotty.decoder()
	for _, s in ipairs(segments(build(v))) do
		if s.kind == "pass" then
			got[#got + 1] = { raw = s.data }
		else
			local result, m = dec:feed(s.data)
			if result ~= hotty.COMPLETE then
				return false, "a command did not decode: " .. result
			end
			got[#got + 1] = { cmd = { control = m.control, payload = m.payload } }
		end
	end
	local want = {}
	for i, seg in ipairs(v.out) do
		if seg.cmd then
			want[i] =
				{ cmd = { control = seg.cmd.control, payload = absent(seg.cmd.payload) and "" or seg.cmd.payload } }
		else
			want[i] = { raw = seg.raw }
		end
	end
	if not equal(got, want) then
		return false, "got " .. show(got)
	end
	return true
end

-- encode ----------------------------------------------------------------------

local function run_encode(v)
	local payload = v.payload_b64 and hotty.base64.decode(v.payload_b64) or v.payload
	local pairs_, keys = {}, {}
	for i, p in ipairs(v.control) do
		pairs_[i] = { p[1], p[2] }
		if p[1] ~= "m" and p[1] ~= "o" then -- Encode's to set
			keys[#keys + 1] = p[1]
		end
	end
	local out = hotty.encode(pairs_, payload)
	if v.bytes and out ~= v.bytes then
		return false, "bytes " .. show(out)
	end
	local seqs = {}
	for _, s in ipairs(segments(out)) do
		if s.kind == "osc" then
			seqs[#seqs + 1] = s.data
		end
	end
	if v.chunks then
		local got = {}
		for i, s in ipairs(seqs) do
			local inner = s:sub(#"\27]7279;" + 1, -3)
			local ctl, b64 = inner:match("^([^;]*);?(.*)$")
			got[i] = { control = ctl, len = #b64 }
		end
		if not equal(got, v.chunks) then
			return false, "chunks " .. show(got)
		end
	end
	local dec = hotty.decoder()
	local result, m
	for _, s in ipairs(seqs) do
		result, m = dec:feed(s)
	end
	if result ~= hotty.COMPLETE then
		return false, "does not decode"
	end
	if m.payload ~= payload then
		return false, "payload differs after the round trip"
	end
	if not equal(m.keys, keys) then
		return false, "control keys " .. show(m.keys)
	end
	return true
end

-- decode ----------------------------------------------------------------------

local function reply_view(r)
	return {
		ok = r.ok,
		re = r.re,
		n = r.n,
		surface = r.surface,
		cols = r.cols,
		rows = r.rows,
		code = r.code,
		detail = r.detail,
	}
end

local function event_view(e)
	local href, url = e:link()
	local w, h = e:size()
	return {
		surface = e.surface,
		kind = e.kind,
		target = e.target,
		value = e:value(),
		checked = e:checked(),
		fields = e:fields(),
		link = href and { href = href, url = url } or nil,
		size = w and { w = w, h = h } or nil,
		fit_rows = e:fit_rows(),
		drag = e:drag(),
		hover = e:hover(),
		area = e:area(),
	}
end

local function caps_view(c, want)
	local w, h = c:cell_css()
	local view = {
		v = c.v,
		ops = c.ops,
		events = c.events,
		cell = c.cell,
		scale = c.scale,
		scheme = c.scheme,
		limits = c.limits,
		net = c.net,
		passthrough = c.passthrough,
		scroll = c.scroll,
		host = c.host,
		version = c.version,
		drags = c:drags(),
		hovers = c:hovers(),
		light = c:light(),
		cell_css = { w = w, h = h },
		supports = {},
		sends = {},
	}
	for op in pairs(want.supports or {}) do
		view.supports[op] = c:supports(op)
	end
	for kind in pairs(want.sends or {}) do
		view.sends[kind] = c:sends(kind)
	end
	return view
end

local function run_decode(v)
	local dec = hotty.decoder()
	local results, msgs = {}, {}
	for i, s in ipairs(v.seqs) do
		local result, m = dec:feed(s)
		results[i] = result
		if result == hotty.COMPLETE then
			msgs[#msgs + 1] = m
		end
	end
	if not equal(results, v.results) then
		return false, "results " .. show(results)
	end
	if dec.invalid ~= v.invalid then
		return false, "invalid " .. dec.invalid .. ", want " .. v.invalid
	end
	if #msgs ~= #v.messages then
		return false, #msgs .. " messages"
	end
	for i, m in ipairs(msgs) do
		local want = v.messages[i]
		if not equal(m.control, want.control) then
			return false, "control " .. show(m.control)
		end
		if want.reply then
			local r = m:reply()
			if not r then
				return false, "not a reply"
			end
			local ok, why = match(reply_view(r), want.reply, "reply")
			if not ok then
				return ok, why
			end
		end
		if want.event then
			local e = m:event()
			if not e then
				return false, "not an event"
			end
			local ok, why = match(event_view(e), want.event, "event")
			if not ok then
				return ok, why
			end
		end
		if want.caps then
			local r = m:reply()
			local c = r and r:caps()
			if not c then
				return false, "no caps"
			end
			local ok, why = match(caps_view(c, want.caps), want.caps, "caps")
			if not ok then
				return ok, why
			end
		end
	end
	return true
end

-- scan ------------------------------------------------------------------------

local function merge(segs)
	local out = {}
	for _, s in ipairs(segs) do
		local last = out[#out]
		if s.kind == "pass" and last and last.kind == "pass" then
			last.data = last.data .. s.data
		else
			out[#out + 1] = { kind = s.kind, data = s.data }
		end
	end
	return out
end

local function scan_once(v, data, cuts)
	local da1 = false
	for _, r in ipairs(v.requires or {}) do
		da1 = da1 or r == "scanner.da1"
	end
	local sc = hotty.scanner({ da1 = da1 })
	local segs, prev = {}, 0
	cuts[#cuts + 1] = #data
	for _, c in ipairs(cuts) do
		for _, s in ipairs(sc:feed(data:sub(prev + 1, c))) do
			segs[#segs + 1] = s
		end
		prev = c
	end
	cuts[#cuts] = nil
	local held = sc:holding()
	local flushed = sc:flush()
	return merge(segs), held, flushed, sc.invalid
end

local function want_segments(list)
	local out = {}
	for _, s in ipairs(list or {}) do
		local kind, data = next(s)
		out[#out + 1] = { kind = kind, data = data }
	end
	return out
end

local function run_scan(v)
	local data = v.stream
	local want = want_segments(v.segments)
	local want_flush = want_segments(v.flush)
	local want_held = v.held or ""
	local n = #data
	-- Every offset, and byte by byte; a long stream is cut at every offset
	-- near its ends and at a stride between.
	local offsets = {}
	if n > 512 then
		for i = 1, 63 do
			offsets[#offsets + 1] = i
		end
		for i = 64, n - 65, 4999 do
			offsets[#offsets + 1] = i
		end
		for i = n - 64, n - 1 do
			offsets[#offsets + 1] = i
		end
	else
		for i = 1, n - 1 do
			offsets[#offsets + 1] = i
		end
	end
	local splits = { {} }
	for _, i in ipairs(offsets) do
		splits[#splits + 1] = { i }
	end
	local every = {}
	for i = 1, n - 1 do
		every[i] = i
	end
	splits[#splits + 1] = every
	for _, cuts in ipairs(splits) do
		local segs, held, flushed, invalid = scan_once(v, data, cuts)
		local where = "cut at " .. table.concat(cuts, ",", 1, math.min(#cuts, 3)) .. (#cuts > 3 and "…" or "")
		if not equal(segs, want) then
			return false, where .. ": segments " .. show(segs)
		end
		if held ~= want_held then
			return false, where .. ": held " .. show(held)
		end
		if not equal(flushed, want_flush) then
			return false, where .. ": flush " .. show(flushed)
		end
		if invalid ~= (v.invalid or 0) then
			return false, where .. ": invalid " .. invalid
		end
	end
	return true
end

-- detect ----------------------------------------------------------------------

local function run_detect(v)
	local det = hotty.detector({ n = v.n or 1, late = v.late })
	local dec = hotty.decoder()
	for i, st in ipairs(v.steps) do
		local at = st.at
		local took
		if st.start then
			det:start(at)
		elseif st.da1 then
			took = det:da1(at)
		elseif st.osc then
			local result, m = dec:feed(st.osc)
			local r = result == hotty.COMPLETE and m:reply() or nil
			took = r ~= nil and det:reply(r, at) or false
		elseif st.tick then
			det:tick(at)
		elseif st["end"] then
			det:finish(at)
		end
		local got = { took = took, state = det.state, decided = det.decided, done = det.done, deadline = det.deadline }
		for _, k in ipairs({ "took", "state", "decided", "done", "deadline" }) do
			if st[k] ~= nil and not equal(got[k], st[k]) then
				return false, string.format("step %d (at %d): %s = %s, want %s", i, at, k, show(got[k]), show(st[k]))
			end
		end
	end
	if v.caps then
		if not det.caps then
			return false, "no caps"
		end
		return match({ v = det.caps.v }, v.caps, "caps")
	end
	return true
end

-- main ------------------------------------------------------------------------

-- Values compared as JSON: null and vim.NIL alike, numbers as numbers.
local function same_json(a, b, path)
	local an = a == null or (vim and a == vim.NIL)
	local bn = b == null or (vim and b == vim.NIL)
	if an or bn then
		return an == bn, path
	end
	if type(a) ~= type(b) then
		return false, path
	end
	if type(a) ~= "table" then
		return a == b, path
	end
	for k, v in pairs(a) do
		local ok, where = same_json(v, b[k], path .. "." .. tostring(k))
		if not ok then
			return false, where
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false, path .. "." .. tostring(k)
		end
	end
	return true
end

-- keys, keymap, edit -----------------------------------------------------------

local function run_keys(v)
	if v.input ~= nil then
		local got = hotty.decode_keys(v.input)
		local same = #got == #v.keys
		for i, want in ipairs(v.keys) do
			local g = got[i] or nil
			same = same and ((absent(want) and g == nil) or g == want)
		end
		return same, show(got) .. ", want " .. show(v.keys)
	end
	local got = hotty.parse_key(v.key)
	return equal(got, v.canon), show(got) .. ", want " .. show(v.canon)
end

local function run_keymap(v)
	if v.program ~= nil or v.scroll ~= nil then
		-- An element's keymap outside a text field: no default keymap.
		local m = hotty.parse_keymap(table.concat(v.keys, " "))
		for key, want in pairs(v.program or {}) do
			local got = m:program(key)
			if got ~= want then
				return false, show(key) .. ": program " .. show(got) .. ", want " .. show(want)
			end
		end
		for key, want in pairs(v.scroll or {}) do
			local got = m:scroll(key)
			if not equal(got, want) then
				return false, show(key) .. ": scroll " .. show(got) .. ", want " .. show(want)
			end
		end
		return true, ""
	end
	if v.lookup == nil then
		local got = hotty.parse_keymap(v.parse ~= nil and v.parse or hotty.TERMINAL_KEYS):format()
		return got == v.format, show(got) .. ", want " .. show(v.format)
	end
	local layers = {}
	if v.terminal_keys then
		layers[1] = hotty.TERMINAL_KEYS
	end
	for _, k in ipairs(v.keys) do
		layers[#layers + 1] = k
	end
	local m = hotty.resolve(v.multiline, unpack(layers))
	for key, want in pairs(v.lookup) do
		local got = m:lookup(key)
		if not equal(got, want) then
			return false, show(key) .. ": " .. show(got) .. ", want " .. show(want)
		end
	end
	return true
end

local function run_edit(v)
	local f = v.field
	local fld = hotty.field({
		value = f.value,
		caret = f.caret,
		multiline = f.multiline == true,
		password = f.password == true,
		rows = not absent(f.rows) and f.rows or 1,
	})
	for i, st in ipairs(v.steps) do
		local changed
		if st["do"] ~= nil then
			changed = fld["do"](fld, st["do"])
		else
			changed = fld:type(st.type)
		end
		local got = { value = fld.value, caret = fld.caret, changed = changed }
		for _, k in ipairs({ "value", "caret", "changed" }) do
			if st[k] ~= nil and not equal(got[k], st[k]) then
				return false,
					"step "
						.. i
						.. " ("
						.. show(st["do"] or st.type)
						.. "): "
						.. k
						.. " "
						.. show(got[k])
						.. ", want "
						.. show(st[k])
			end
		end
	end
	return true
end

local function main()
	local path = arg and arg[1] or (root .. "/tests/vectors.json")
	local text = assert(read(path), "cannot read " .. path)
	local data, err = json.decode(text)
	assert(data, err)
	local failures, counts, skipped = {}, {}, 0
	local function check(section, name, ok, why)
		counts[section] = counts[section] or { 0, 0 }
		counts[section][ok and 1 or 2] = counts[section][ok and 1 or 2] + 1
		if not ok then
			failures[#failures + 1] = section .. ": " .. name .. ": " .. tostring(why)
		end
	end
	print("runtime " .. runtime())
	if vim and vim.json then
		local ok, where = same_json(data, vim.json.decode(text), "vectors")
		check("json", "hotty.json reads vectors.json as vim.json does", ok, "differs at " .. tostring(where))
	end
	-- The copy, against the spec's, when a checkout is at hand (HOTTY_DIR).
	local dir = os.getenv("HOTTY_DIR")
	if dir and dir ~= "" and path == root .. "/tests/vectors.json" then
		local spec = read(dir .. "/conformance/vectors.json")
		if spec then
			check("copy", "tests/vectors.json is the spec's", spec == text, "make vectors")
		end
	end
	if data.version ~= hotty.VERSION then
		print("the vectors are for " .. tostring(data.version) .. ", this SDK for " .. hotty.VERSION)
		os.exit(1)
	end
	local sections = {
		{ "wire", run_wire },
		{ "build", run_build },
		{ "encode", run_encode },
		{ "decode", run_decode },
		{ "scan", run_scan },
		{ "detect", run_detect },
		{ "keys", run_keys },
		{ "keymap", run_keymap },
		{ "edit", run_edit },
	}
	for _, s in ipairs(sections) do
		local section, run = s[1], s[2]
		for _, v in ipairs(data[section] or {}) do
			local runs = true
			for _, r in ipairs(v.requires or {}) do
				runs = runs and FEATURES[r] or false
			end
			if not runs then
				skipped = skipped + 1
			else
				local ok, res, why = pcall(run, v)
				if not ok then
					res, why = false, res
				end
				check(section, v.name, res, why)
			end
		end
	end
	for _, s in ipairs({
		"json",
		"copy",
		"wire",
		"build",
		"encode",
		"decode",
		"scan",
		"detect",
		"keys",
		"keymap",
		"edit",
	}) do
		local c = counts[s]
		if c then
			print(string.format("%-7s %d passed%s", s, c[1], c[2] > 0 and (", " .. c[2] .. " failed") or ""))
		end
	end
	if skipped > 0 then
		print("skipped " .. skipped .. " (requires)")
	end
	for _, f in ipairs(failures) do
		print("FAIL " .. f)
	end
	if #failures > 0 then
		os.exit(1)
	end
end

main()
