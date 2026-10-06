-- Tests of what the vectors leave out: base64, JSON and inflate on their own,
-- the Scanner's limit at its edge and under any split, names, Control,
-- errors. Runs under the same interpreters as tests/vectors.lua.

local root = ((arg and arg[0]) or ""):match("^(.-)/?tests/[^/]*$") or "."
if root == "" then
	root = "."
end
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. root .. "/tests/?.lua;" .. package.path

local hotty = require("hotty")
local base64, json = hotty.base64, hotty.json
local inflate = require("hotty.inflate")

-- Counted in a table: in gopher-lua v1.1.2, once pcall catches an error, a
-- closure no longer shares its caller's locals.
local failures, stats = {}, { passed = 0 }

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		stats.passed = stats.passed + 1
	else
		failures[#failures + 1] = name .. ": " .. tostring(err)
	end
end

local function q(v)
	if type(v) == "string" then
		return string.format("%q", #v > 60 and (v:sub(1, 60) .. "…") or v)
	end
	return tostring(v)
end

local function eq(got, want, what)
	if got ~= want then
		error((what and (what .. ": ") or "") .. "got " .. q(got) .. ", want " .. q(want), 2)
	end
end

local function ok(v, what)
	if not v then
		error(what or "not true", 2)
	end
end

-- A deterministic stream of bytes: a linear congruential generator, in
-- arithmetic.
local function bytes(n, seed)
	local t, x = {}, seed or 1
	for i = 1, n do
		x = (x * 1103515245 + 12345) % 2147483648
		t[i] = string.char(math.floor(x / 65536) % 256)
	end
	return require("hotty.join")(t)
end

-- base64 ----------------------------------------------------------------------

test("base64: RFC 4648 §10", function()
	local cases = {
		"",
		"",
		"f",
		"Zg==",
		"fo",
		"Zm8=",
		"foo",
		"Zm9v",
		"foob",
		"Zm9vYg==",
		"fooba",
		"Zm9vYmE=",
		"foobar",
		"Zm9vYmFy",
	}
	for i = 1, #cases, 2 do
		eq(base64.encode(cases[i]), cases[i + 1])
		eq(base64.decode(cases[i + 1]), cases[i])
	end
end)

test("base64: every byte, and lengths 0 to 70, round trip", function()
	local all = {}
	for b = 0, 255 do
		all[#all + 1] = string.char(b)
	end
	all = table.concat(all)
	eq(base64.decode(base64.encode(all)), all)
	eq(base64.encode(all):sub(1, 12), "AAECAwQFBgcI")
	for n = 0, 70 do
		local s = bytes(n, n + 1)
		eq(base64.decode(base64.encode(s)), s, "length " .. n)
	end
end)

test("base64: without padding, with whitespace; malformed", function()
	eq(base64.decode("Zm9vYg"), "foob")
	eq(base64.decode(" Zm9v\r\nYmE= "), "fooba")
	eq(base64.decode("Zm9vY"), nil, "a length no base64 has")
	eq(base64.decode("Zm=9v"), nil, "padding before the end")
	eq(base64.decode("Zm9v!"), nil, "a byte outside the alphabet")
	eq(base64.decode("Zm9v-_"), nil, "the URL alphabet")
end)

test("base64: a large payload, for gopher-lua's table.concat", function()
	local s = bytes(300000, 3)
	local b = base64.encode(s)
	eq(#b, 400000)
	eq(base64.decode(b), s)
end)

-- json ------------------------------------------------------------------------

test("json: values", function()
	local v = assert(json.decode(' {"a": [1, -2.5e3, true, false, null, "x"], "b": {}, "c": [] } '))
	eq(v.a[1], 1)
	eq(v.a[2], -2500)
	eq(v.a[3], true)
	eq(v.a[4], false)
	eq(v.a[5], json.null)
	eq(v.a[6], "x")
	ok(json.is_object(v.b) and json.is_array(v.c), "{} and [] told apart")
	ok(json.is_array(v.a) and json.is_object(v))
end)

test("json: strings and escapes", function()
	eq(json.decode('"a\\"\\\\\\/\\b\\f\\n\\r\\t"'), 'a"\\/\b\f\n\r\t')
	eq(json.decode('"\\u00e9\\u2014\\ud83d\\ude00"'), "é—😀")
	eq(json.decode('"é raw"'), "é raw")
	eq(json.decode('"\\ud83d"'), "\237\160\189", "a lone surrogate, as WTF-8")
end)

test("json: malformed", function()
	for _, s in ipairs({
		"",
		"{",
		"[1,]",
		'{"a"}',
		'{"a":1,}',
		"01",
		"1.",
		".5",
		"-",
		"1e",
		"tru",
		'"a\nb"',
		'"\\x"',
		"1 2",
		"nul",
		'{"a":1}x',
	}) do
		local v, err = json.decode(s)
		ok(v == nil and err, "accepted " .. q(s))
	end
	local deep = string.rep("[", 200) .. string.rep("]", 200)
	ok(json.decode(deep) == nil, "too deep")
end)

test("json: encode as Go's encoding/json", function()
	eq(json.encode(3), "3")
	eq(json.encode(-0.5), "-0.5")
	eq(json.encode(1e21), "1e+21")
	eq(json.encode(1e20), "100000000000000000000")
	eq(json.encode(0.000001), "0.000001")
	eq(json.encode(1e-7), "1e-7")
	eq(json.encode(0.1), "0.1")
	eq(json.encode(123456789.125), "123456789.125")
	eq(json.encode(true), "true")
	eq(json.encode(json.null), "null")
	eq(json.encode('<a href="x">&\n\1é'), '"\\u003ca href=\\"x\\"\\u003e\\u0026\\n\\u0001é"')
	eq(json.encode("bad \255 byte"), '"bad \\ufffd byte"')
	eq(json.encode(json.decode('{"b":[1,"x",{}],"a":[]}')), '{"a":[],"b":[1,"x",{}]}')
end)

-- inflate ---------------------------------------------------------------------

test("inflate: what Python's zlib made", function()
	for _, c in ipairs(require("zlib_fixtures")) do
		local data, stream = base64.decode(c[2]), base64.decode(c[3])
		local out, err = inflate.zlib(stream)
		eq(out, data, c[1] .. (err and (" (" .. err .. ")") or ""))
	end
end)

local function adler32(s)
	local a, b = 1, 0
	for i = 1, #s do
		a = (a + s:byte(i)) % 65521
		b = (b + a) % 65521
	end
	return b * 65536 + a
end

local function be32(n)
	return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

-- A zlib stream of stored blocks of at most 65535 bytes, built by hand.
local function stored(data)
	local parts, i = { "\120\1" }, 1
	repeat
		local piece = data:sub(i, i + 65534)
		i = i + #piece
		local last = i > #data and 1 or 0
		local len = #piece
		local nlen = 65535 - len
		parts[#parts + 1] = string.char(last, len % 256, math.floor(len / 256), nlen % 256, math.floor(nlen / 256))
			.. piece
	until i > #data
	parts[#parts + 1] = be32(adler32(data))
	return require("hotty.join")(parts)
end

test("inflate: stored blocks past 65535 bytes", function()
	local data = bytes(140000, 9)
	eq(inflate.zlib(stored(data)), data)
end)

test("inflate: malformed streams", function()
	local good = stored("hello")
	ok(inflate.zlib(good) == "hello")
	ok(inflate.zlib("") == nil, "empty")
	ok(inflate.zlib("\120\2" .. good:sub(3)) == nil, "a header whose check fails")
	ok(inflate.zlib(good:sub(1, -2) .. "x") == nil, "a checksum that does not match")
	ok(inflate.zlib(good:sub(1, 6)) == nil, "cut short")
	ok(inflate.zlib("\120\156\7\0") == nil, "a reserved block type")
end)

test("decoder: o=z is inflated, and bad zlib is malformed", function()
	local dec = hotty.decoder()
	local z = base64.encode(stored("<p>hi</p>"))
	local r, m = dec:feed("\27]7279;a=doc:s=x:o=z;" .. z .. "\27\\")
	eq(r, hotty.COMPLETE)
	eq(m.payload, "<p>hi</p>")
	eq(m.control.o, nil)
	r = dec:feed("\27]7279;a=doc:s=x:o=z;" .. base64.encode("not zlib") .. "\27\\")
	eq(r, hotty.INVALID)
	eq(dec.invalid, 1)
	local custom = hotty.decoder({
		inflate = function()
			return "mine"
		end,
	})
	r, m = custom:feed("\27]7279;a=doc:s=x:o=z;" .. z)
	eq(m.payload, "mine")
end)

-- encode ----------------------------------------------------------------------

test("encode: a compressor given is used only where it pays", function()
	local calls = 0
	local function compress(s)
		calls = calls + 1
		return "short"
	end
	local small = hotty.encode({ { "a", "doc" } }, string.rep("a", 255), { compress = compress })
	eq(calls, 0, "under 256 bytes")
	ok(not small:find("o=z"))
	local big = hotty.encode({ { "a", "doc" }, { "q", "2" } }, string.rep("a", 256), { compress = compress })
	eq(big, "\27]7279;a=doc:q=2:o=z;" .. base64.encode("short") .. "\27\\")
	local worse = hotty.encode({ { "a", "doc" } }, string.rep("a", 300), {
		compress = function(s)
			return s .. "!"
		end,
	})
	ok(not worse:find("o=z"), "not when it makes it larger")
end)

test("encode: a 1 MiB document chunks, and decodes back", function()
	local html = bytes(1048576, 5)
	local out = hotty.doc("big", html)
	local sc, dec = hotty.scanner(), hotty.decoder()
	local result, m
	local n = 0
	for _, s in ipairs(sc:feed(out)) do
		eq(s.kind, "osc")
		n = n + 1
		result, m = dec:feed(s.data)
	end
	eq(n, math.ceil(math.ceil(1048576 / 3) * 4 / 4096))
	eq(result, hotty.COMPLETE)
	eq(m.payload, html)
	eq(m.control.q, "1")
end)

test("encode: values are cleaned; numbers and booleans as tostring", function()
	eq(hotty.clean_value("a:b;c=d"), "a_b_c_d")
	eq(hotty.clean_value("é😀x"), "__x", "one _ for each code point")
	eq(hotty.clean_value("\255\254x"), "__x", "one _ for each byte that is not UTF-8")
	eq(hotty.clean_value("\226\130x"), "__x", "a sequence cut short is bytes that are not UTF-8")
	eq(hotty.clean_value(42), "42")
	eq(hotty.clean_value(true), "true")
end)

-- commands --------------------------------------------------------------------

test("place: the window rules", function()
	local function ctl(pl)
		local _, m = hotty.decoder():feed(hotty.place("s", pl))
		return m.control
	end
	eq(ctl({ cols = 10, rows = 3, window = { x = 0, y = 0, w = 0, h = 0 } }).x, nil, "all 0 is none")
	eq(ctl({ cols = 10, rows = 3, window = { x = 0, y = 0, w = 10, h = 3 } }).x, nil, "the whole surface")
	eq(ctl({ cols = 10, rows = 3, window = { x = 0, y = 1, w = 10, h = 2 } }).h, "2")
	eq(ctl({ cols = 10, window = { x = 0, y = 0, w = 10, h = 3 } }).h, "3", "with r=auto, always")
	eq(ctl({ cols = 10, z = 0, press = false }).z, nil)
	eq(ctl({ cols = 10, z = -1000 }).z, "-1000")
	eq(ctl({ cols = 10, rows = 2.0 }).r, "2", "a whole float is written as an integer")
end)

test("place_at: no leading zeros, and the placement given is left as it was", function()
	local pl = { cols = 5 }
	local out = hotty.place_at("s", 0, 9, pl)
	eq(out:sub(1, 9), "\27" .. "7\27[10;1H")
	eq(pl.keep_cursor, nil)
end)

test("reply options: q wins over n in either order; each key once", function()
	local _, m = hotty.decoder():feed(hotty.hide("s", { q = 1, n = 7 }))
	eq(m.control.q, "1")
	eq(m.control.n, "7")
	local count = 0
	for _, k in ipairs(m.keys) do
		count = count + ((k == "q" or k == "n") and 1 or 0)
	end
	eq(count, 2)
end)

test("doc's scroll: the axes as given; nil and 0 send no key", function()
	local function control(opts)
		local _, m = hotty.decoder():feed(hotty.doc("s", "<p>", opts))
		return m.control
	end
	eq(control({ scroll = hotty.SCROLL_VERTICAL + hotty.SCROLL_HORIZONTAL }).scroll, "3")
	eq(control({ scroll = hotty.scroll_horizontal }).scroll, "2")
	eq(control({ scroll = 4 }).scroll, "4", "for the host to judge")
	eq(control({}).scroll, nil)
	eq(control().scroll, nil)
end)

test("area: four whole numbers, in an object; caps.scroll: true only", function()
	local function area(detail)
		local _, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" }, { "s", "f" }, { "e", "click" } }, detail))
		return m:event():area()
	end
	eq(area('{"area":{"c":0,"r":1,"w":2,"h":3}}').h, 3)
	eq(area('{"area":{"c":0,"r":1,"w":2,"h":1.5}}'), nil)
	eq(area('{"area":{"c":0,"r":1,"w":2}}'), nil)
	eq(area('{"area":{"c":0,"r":1,"w":"2","h":3}}'), nil)
	eq(area('{"area":[0,1,2,3]}'), nil)
	eq(area('{"area":null}'), nil)
	eq(area(""), nil)
	ok(hotty.caps({ scroll = true }).scroll)
	eq(hotty.caps({ scroll = "yes" }).scroll, false)
	eq(hotty.caps({ scroll = 1 }).scroll, false)
end)

test("sync takes commands as arguments or a list", function()
	local a, b = hotty.set_text("x", "a", "1"), hotty.set_text("x", "b", "2")
	eq(hotty.sync(a, b), hotty.sync({ a, b }))
	eq(hotty.sync(), "\27[?2026h\27[?2026l")
end)

-- names, control, errors ------------------------------------------------------

test("names", function()
	ok(hotty.valid_name("a-B_9"))
	ok(not hotty.valid_name(""))
	ok(not hotty.valid_name(string.rep("a", 65)))
	ok(hotty.valid_name(string.rep("a", 64)))
	ok(not hotty.valid_name("a b"))
	eq(hotty.surface_name("my card"), "my_card")
	eq(hotty.surface_name("café"), "caf_")
	eq(hotty.surface_name(""), "_")
	eq(hotty.surface_name(string.rep("é", 70)), string.rep("_", 64))
	eq(hotty.surface_name("ok"), "ok")
end)

test("control: ordered, set in place", function()
	local c = hotty.control({ { "a", "doc" }, { "s", "x" } })
	c:with("q", 1):with("s", "y")
	local v, present = c:get("s")
	eq(v, "y")
	eq(present, true)
	v, present = c:get("n")
	eq(v, nil)
	eq(present, false)
	eq(hotty.encode(c), "\27]7279;a=doc:s=y:q=1\27\\")
end)

test("errors: a reply's error names its code and detail", function()
	local _, m =
		hotty.decoder():feed("\27]7279;a=err:s=x:re=delta;" .. base64.encode('{"code":"ENOTARGET","detail":"go"}'))
	local e = m:reply():err()
	eq(e.code, "ENOTARGET")
	eq(e.detail, "go")
	eq(tostring(e), "hotty: ENOTARGET: go (re=delta, s=x)")
	local _, okm = hotty.decoder():feed("\27]7279;a=ok:re=del")
	eq(okm:reply():err(), nil)
end)

test("messages: an err with a body that is not JSON has no code", function()
	local _, m = hotty.decoder():feed("\27]7279;a=err:re=doc;" .. base64.encode("oops"))
	local r = m:reply()
	eq(r.ok, false)
	eq(r.code, nil)
	eq(r:err().code, "")
	eq(m:event(), nil)
end)

-- scanner ---------------------------------------------------------------------

local function scan_all(data, cuts, opts)
	local sc = hotty.scanner(opts)
	local segs, prev = {}, 0
	local function add(list)
		for _, s in ipairs(list) do
			local last = segs[#segs]
			if s.kind == "pass" and last and last.kind == "pass" then
				last.data = last.data .. s.data
			else
				segs[#segs + 1] = { kind = s.kind, data = s.data }
			end
		end
	end
	for _, c in ipairs(cuts) do
		add(sc:feed(data:sub(prev + 1, c)))
		prev = c
	end
	add(sc:feed(data:sub(prev + 1)))
	add(sc:flush())
	local parts = {}
	for _, s in ipairs(segs) do
		parts[#parts + 1] = s.kind .. ":" .. s.data
	end
	return table.concat(parts, "|"), sc.invalid
end

test("scanner: the limit counts no terminator", function()
	local body = string.rep("A", hotty.SCAN_MAX - 7) -- 7 for ESC ] 7 2 7 9 ;
	for _, term in ipairs({ "\27\\", "\7" }) do
		local seq = "\27]7279;" .. body .. term
		eq(#seq - #term, hotty.SCAN_MAX)
		local segs, invalid = scan_all(seq .. "k", {})
		eq(invalid, 0, "65536 bytes and " .. q(term))
		eq(segs, "osc:" .. seq .. "|pass:k")
		segs, invalid = scan_all("\27]7279;A" .. body .. term .. "k", {})
		eq(invalid, 1, "65537 bytes and " .. q(term))
		eq(segs, "pass:k")
	end
end)

test("scanner: the same segments however the stream is split", function()
	local pieces = {
		"key",
		"\27]7279;a=ev:s=f:e=click:t=go\27\\",
		"\27[A",
		"\27]7279;a=ok:n=1:re=q\7",
		"\27]11;rgb:0/0/0\27\\",
		"\27[?62;22c",
		"\27]7279;a=ok\27[B",
		"\27",
		"\27]7279;m=0;AAAA\27\\",
		"é",
		"\27]72790;x\7",
		"\27[?1u",
	}
	local seed = 11
	for round = 1, 200 do
		local parts = {}
		for i = 1, 6 do
			seed = (seed * 1103515245 + 12345) % 2147483648
			parts[i] = pieces[seed % #pieces + 1]
		end
		local data = table.concat(parts)
		for _, da1 in ipairs({ false, true }) do
			local whole, inv = scan_all(data, {}, { da1 = da1 })
			local every = {}
			for i = 1, #data - 1 do
				every[i] = i
			end
			local split, inv2 = scan_all(data, every, { da1 = da1 })
			eq(split, whole, "round " .. round)
			eq(inv2, inv, "round " .. round)
			for i = 1, #data - 1 do
				local s, n = scan_all(data, { i }, { da1 = da1 })
				eq(s, whole, "round " .. round .. " cut at " .. i)
				eq(n, inv)
			end
		end
	end
end)

test("scanner: a key is never kept waiting", function()
	local sc = hotty.scanner({ da1 = true })
	local segs = sc:feed("abc\27[A")
	eq(#segs, 1)
	eq(segs[1].data, "abc\27[A")
	eq(sc:holding(), "")
	sc:feed("\27]72")
	eq(sc:holding(), "\27]72")
end)

-- detector --------------------------------------------------------------------

test("detector: end is finish", function()
	local d = hotty.detector()
	d:start(0)
	d["end"](d, 10)
	eq(d.state, hotty.TEXT)
	eq(d.done, true)
	eq(d.deadline, nil)
end)

test("detector: start returns the query with its n", function()
	local d = hotty.detector({ n = 9 })
	eq(d:start(0), hotty.query(9))
	eq(d.deadline, 1500)
end)

for _, f in ipairs(failures) do
	print("FAIL " .. f)
end
print(string.format("unit    %d passed%s", stats.passed, #failures > 0 and (", " .. #failures .. " failed") or ""))
if #failures > 0 then
	os.exit(1)
end
