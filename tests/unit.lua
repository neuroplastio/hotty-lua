-- Tests of what the vectors leave out: base64, msgpack and inflate on their
-- own, reading bodies, the Scanner's limit at its edge and under any split,
-- names, Control, errors. Runs under the same interpreters as
-- tests/vectors.lua.

local root = ((arg and arg[0]) or ""):match("^(.-)/?tests/[^/]*$") or "."
if root == "" then
	root = "."
end
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. root .. "/tests/?.lua;" .. package.path

local hotty = require("hotty")
local base64, msgpack = hotty.base64, hotty.msgpack
local inflate = require("hotty.inflate")
local mp = require("msgpack_writer") -- what a host writes

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

-- What a host's own hotty.base64 must do too (docs/plx.md): every byte %s
-- matches is skipped, up to two "=" at the end are dropped whatever the
-- length, and bits past the last byte are ignored.
test("base64: the edges a native hotty.base64 keeps", function()
	eq(base64.decode("Zm\t9v\vYm\fE="), "fooba", "%s, not only CR and LF")
	eq(base64.decode("Zm9vYg="), "foob", "one = where two belong")
	eq(base64.decode("Zm9vYmE=="), "fooba", "two = where one belongs")
	eq(base64.decode("Zm9v="), "foo", "= after a whole group")
	eq(base64.decode("Zm9v==="), nil, "three =")
	eq(base64.decode("Zm9vYh"), "foob", "bits past the last byte")
	eq(base64.decode(""), "")
	eq(base64.encode(""), "")
end)

test("base64: a large payload, for gopher-lua's table.concat", function()
	local s = bytes(300000, 3)
	local b = base64.encode(s)
	eq(#b, 400000)
	eq(base64.decode(b), s)
end)

-- msgpack ---------------------------------------------------------------------

-- What a host's own hotty.msgpack must do too (docs/plx.md).

local function hex(h)
	return (h:gsub("%s", ""):gsub("%x%x", function(x)
		return string.char(tonumber(x, 16))
	end))
end

local function one(h, what)
	local v, kinds = msgpack.decode(hex(h))
	ok(type(kinds) == "table", (what or h) .. ": " .. tostring(kinds))
	return v, kinds
end

local function fails(h, what)
	local v, err = msgpack.decode(hex(h))
	ok(v == nil and type(err) == "string" and err:sub(1, 9) == "msgpack: ", "accepted " .. (what or h))
end

local function count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

test("msgpack: every form of an int, within 2^53 - 1 of 0", function()
	for _, c in ipairs({
		{ "00", 0 },
		{ "7f", 127 },
		{ "e0", -32 },
		{ "ff", -1 },
		{ "cc ff", 255 },
		{ "cd ffff", 65535 },
		{ "ce ffffffff", 4294967295 },
		{ "cf 001fffffffffffff", 2 ^ 53 - 1 },
		{ "cf 0000000000000007", 7 },
		{ "d0 80", -128 },
		{ "d0 07", 7 },
		{ "d1 8000", -32768 },
		{ "d2 80000000", -2147483648 },
		{ "d3 ffe0000000000001", -(2 ^ 53 - 1) },
		{ "d3 ffffffffffffffff", -1 },
		{ "d3 001fffffffffffff", 2 ^ 53 - 1 },
	}) do
		local v, kinds = one(c[1])
		eq(v, c[2], c[1])
		eq(next(kinds), nil, c[1] .. ": no kinds")
	end
	fails("cf 0020000000000000", "2^53")
	fails("cf ffffffffffffffff", "2^64 - 1")
	fails("d3 ffe0000000000000", "-2^53")
	fails("d3 8000000000000000", "-2^63")
	fails("d3 0020000000000000", "2^53, signed")
end)

test("msgpack: floats of 32 and 64 bits", function()
	eq(one("ca 3fc00000"), 1.5)
	eq(one("cb 3ff8000000000000"), 1.5)
	eq(one("cb 3fb999999999999a"), 0.1)
	eq(one("ca 3dcccccd"), 0.10000000149011612, "float32's 0.1")
	eq(one("cb 0000000000000001"), 2 ^ -1074, "the least subnormal")
	eq(one("ca 00000001"), 2 ^ -149)
	eq(one("cb 7fefffffffffffff"), 1.7976931348623157e308)
	eq(one("cb 4000000000000000"), 2, "whole")
	local z = one("cb 8000000000000000")
	ok(z == 0 and 1 / z < 0, "-0")
	ok(one("cb 7ff0000000000000") > 1.7976931348623157e308, "infinity")
	ok(one("ca ff800000") < -1.7976931348623157e308, "-infinity")
	local nan = one("cb 7ff8000000000000")
	ok(nan ~= nan, "NaN")
end)

test("msgpack: booleans, strings and bins in every form", function()
	eq(one("c2"), false)
	eq(one("c3"), true)
	eq(one("a0"), "")
	eq(one("a3 616263"), "abc")
	eq(one("d9 03 616263"), "abc")
	eq(one("da 0003 616263"), "abc")
	eq(one("db 00000003 616263"), "abc")
	eq(one("d9 20" .. string.rep("78", 32)), string.rep("x", 32))
	eq(one("a2 c3a9"), "é")
	eq(one("c4 03 616263"), "abc")
	eq(one("c5 0002 ff00"), "\255\0", "a bin is any bytes")
	eq(one("c6 00000000"), "")
end)

test("msgpack: arrays and maps in every form", function()
	for _, h in ipairs({ "92 01 a1 61", "dc 0002 01 a1 61", "dd 00000002 01 a1 61" }) do
		local v = one(h)
		eq(count(v), 2, h)
		eq(v[1], 1)
		eq(v[2], "a")
	end
	for _, h in ipairs({ "81 a1 61 01", "de 0001 a1 61 01", "df 00000001 a1 61 01" }) do
		local v = one(h)
		eq(count(v), 1, h)
		eq(v.a, 1)
	end
	eq(next((one("90"))), nil, "[]")
	eq(next((one("80"))), nil, "{}")
	for _, h in ipairs({ "81 a1 61 01", "81 d9 01 61 01", "81 da 0001 61 01", "81 db 00000001 61 01" }) do
		eq(one(h).a, 1, h .. ": a key in each form of a str")
	end
	eq(one("81 a0 01")[""], 1, "the empty str")
	local v = one("82 a1 61 01 a1 62 02")
	ok(getmetatable(v) == nil, "no metatable")
	eq(count(v), 2)
end)

test("msgpack: an array keeps no length of its own", function()
	local v = one("93 01 d4 05 00 03")
	eq(v[1], 1)
	eq(v[2], nil, "a hole")
	eq(v[3], 3)
	eq(next((one("92 d4 05 00 c7 00 05"))), nil, "nothing but absent extensions")
end)

test("msgpack: a timestamp in 4, 8 or 12 bytes; any other extension is absent", function()
	local function ts(h, sec, nsec)
		local v = one(h)
		eq(v.sec, sec, h)
		eq(v.nsec, nsec, h)
		ok(getmetatable(v) == nil and count(v) == 2, "only sec and nsec")
	end
	ts("d6 ff 00000001", 1, 0)
	ts("c7 04 ff 00000001", 1, 0)
	ts("d7 ff 00000004 00000002", 2, 1)
	ts("d7 ff ee6b27ff 00000003", 3 * 2 ^ 32 + 3, 999999999)
	ts("c7 0c ff 00000003 ffffffffffffffff", -1, 3)
	ts("c7 0c ff 3b9ac9ff 001fffffffffffff", 2 ^ 53 - 1, 999999999)
	fails("c7 03 ff 000000", "a timestamp of 3 bytes")
	fails("d8 ff 00000000000000000000000000000000", "a timestamp of 16 bytes")
	fails("d7 ff ee6b2800 00000000", "a second of nanoseconds")
	ts("c7 0c ff 00000000 ffe0000000000001", -(2 ^ 53 - 1), 0)
	fails("c7 0c ff 00000000 0020000000000000", "seconds past 2^53 - 1")
	fails("c7 0c ff 00000000 ffe0000000000000", "seconds of -2^53")
	fails("c7 0c ff 00000000 7fffffffffffffff", "seconds of 2^63 - 1")
	fails("81 a1 61 c7 0c ff 00000000 0020000000000000", "seconds past 2^53 - 1, in a map")
	local _, err = msgpack.decode(hex("c7 0c ff 00000000 0020000000000000"))
	ok(err:find("timestamp", 1, true), "says so: " .. err)
	for _, h in ipairs({
		"d4 01 00",
		"d5 01 0000",
		"d6 01 00000000",
		"d7 01 0000000000000000",
		"d8 01 00000000000000000000000000000000",
		"c7 00 05",
		"c8 0001 05 00",
		"c9 00000001 05 00",
		"d6 fe 00000000",
	}) do
		eq(one(h), nil, h)
		local v = one("82 a1 61 " .. h .. " a1 62 01")
		eq(count(v), 1, h .. " in a map")
		eq(v.b, 1)
		v = one("93 01 " .. h .. " 03")
		eq(count(v), 2, h .. " in an array")
		eq(v[1], 1)
		eq(v[2], nil, "a hole")
		eq(v[3], 3)
	end
	eq(one("c7 01 05 c0"), nil, "an extension's data is not read: no nil there")
	eq(one("91 c7 02 05 81 01")[1], nil, "nor a key")
end)

test("msgpack: kinds marks each entry whose type a Lua value cannot show", function()
	local v, kinds = one(
		"8d"
			.. " a1 61 cb 3ff0000000000000" -- a: 1.0
			.. " a1 62 01" -- b: 1
			.. " a1 63 95 cb 4000000000000000 02 c4 01 78 d4 05 00 d6 ff 00000001" -- c: [2.0, 2, bin, ext, time]
			.. " a1 64 81 a1 65 ca 40600000" -- d: {e: float32 3.5}
			.. " a1 66 81 a1 67 01" -- f: {g: 1}
			.. " a1 68 c4 02 6162" -- h: bin
			.. " a1 69 90" -- i: []
			.. " a1 6a 80" -- j: {}
			.. " a1 6b d6 ff 00000002" -- k: a timestamp
			.. " a1 6c d4 05 00" -- l: an extension of type 5
			.. " a1 6d a1 73" -- m: "s"
			.. " a1 6e c3" -- n: true
			.. " a1 6f c7 00 05" -- o: an extension of type 5 and no data
	)
	eq(v.a, 1)
	eq(v.b, 1, "1.0 and 1 are one number in Lua")
	eq(kinds[v].a, "float")
	eq(kinds[v].b, nil, "an int")
	eq(kinds[v].c, "array")
	eq(kinds[v.c][1], "float")
	eq(kinds[v.c][2], nil)
	eq(kinds[v.c][3], "bin")
	eq(v.c[3], "x")
	eq(kinds[v.c][4], "ext")
	eq(v.c[4], nil, "a hole, marked")
	eq(kinds[v.c][5], "time")
	eq(v.c[5].sec, 1)
	eq(kinds[v].d, nil, "a map")
	eq(kinds[v.d].e, "float", "a float of 32 bits")
	eq(kinds[v.f], nil, "only tables holding a marked entry")
	eq(kinds[v].h, "bin")
	eq(v.h, "ab")
	eq(kinds[v].i, "array", "an empty array")
	eq(next(v.i), nil)
	eq(kinds[v.i], nil)
	eq(kinds[v].j, nil, "an empty map")
	eq(next(v.j), nil)
	eq(kinds[v].k, "time")
	eq(v.k.sec, 2)
	eq(kinds[v.k], nil, "a timestamp's table marks nothing")
	eq(kinds[v].l, "ext")
	eq(v.l, nil, "a key left out, marked")
	eq(kinds[v].o, "ext")
	eq(kinds[v].m, nil, "a str")
	eq(kinds[v].n, nil, "a bool")
	eq(count(kinds), 3)
	eq(count(kinds[v]), 7)
	eq(count(kinds[v.c]), 4)
	v, kinds = one("92 90 80")
	eq(kinds[v][1], "array", "the whole value's own entries")
	eq(kinds[v][2], nil)
	eq(count(kinds), 1)
	for _, h in ipairs({ "cb 3ff0000000000000", "c4 01 61", "90", "80", "91 01", "d6 ff 00000001", "d4 05 00" }) do
		v, kinds = one(h)
		eq(next(kinds), nil, h .. ": the whole value has no table to be marked in")
	end
end)

test("msgpack: a key given twice, in any map, whatever its values", function()
	local _, err = msgpack.decode(hex("82 a1 61 01 a1 61 01"))
	eq(err, "msgpack: a key given twice")
	fails("82 a1 61 01 a1 61 01", "the same value")
	fails("82 a1 61 01 a1 61 a1 62", "another value")
	fails("83 a1 61 01 a1 62 01 a1 61 01", "not next to each other")
	fails("82 a0 01 a0 01", "the empty str")
	fails("82 a1 61 01 d9 01 61 01", "a fixstr and a str 8")
	fails("82 da 0001 61 01 db 00000001 61 01", "a str 16 and a str 32")
	fails("82 a2 c3a9 01 d9 02 c3a9 01", "a name past ASCII, in two forms")
	fails("82 a1 61 d4 05 00 a1 61 01", "the first value absent")
	fails("82 a1 61 01 a1 61 d4 05 00", "the second absent")
	fails("82 a1 61 d4 05 00 a1 61 d4 05 00", "both absent")
	fails("82 a1 61 d6 ff 00000001 a1 61 d6 ff 00000001", "two timestamps")
	fails("de 0002 a1 61 01 a1 61 01", "in a map 16")
	fails("81 a1 61 82 a1 62 01 a1 62 01", "in a nested map")
	fails("91 82 a1 62 01 a1 62 01", "in a map in an array")
	fails(string.rep("81 a1 61 ", 30) .. "82 a1 62 01 a1 62 01", "31 levels deep")
	fails("82 a1 61 c4 01 78 a1 61 c4 01 78", "two bins")
	local v = one("82 a1 61 01 a1 41 01")
	eq(count(v), 2, "a and A are two keys")
	v = one("82 a1 61 81 a1 62 01 a1 63 81 a1 62 02")
	eq(v.a.b, 1, "one name in two maps")
	eq(v.c.b, 2)
	v = one("81 a1 61 81 a1 61 01")
	eq(v.a.a, 1, "a map's key in the map it holds")
	v = one("92 81 a1 61 01 81 a1 61 02")
	eq(v[2].a, 2, "in two maps of an array")
end)

test("msgpack: what is not one value", function()
	for _, h in ipairs({
		"",
		"01 02",
		"81 a1 61 01 c0",
		"cd 00",
		"a3 6162",
		"d9",
		"92 01",
		"81 a1 61",
		"cb 3ff00000",
		"d6 ff 0000",
		"c4 05 61",
		"dd ffffffff",
		"df ffffffff",
		"db ffffffff",
		"c9 ffffffff 01",
	}) do
		fails(h)
	end
	fails("c1", "0xc1, which no type starts with")
	local v, err = msgpack.decode(nil)
	ok(v == nil and err:sub(1, 9) == "msgpack: ", "not a string")
end)

test("msgpack: nil is not one value, anywhere", function()
	fails("c0", "alone")
	fails("91 c0", "in an array")
	fails("93 01 c0 03", "inside an array")
	fails("81 a1 61 c0", "a map's value")
	fails("81 c0 01", "a map's key")
	fails("81 a1 61 81 a1 62 91 c0", "deep")
	fails("82 a1 61 c0 a1 61 01", "in a value a key given again replaces")
	fails("82 a1 61 d4 05 00 a1 62 c0", "after an absent extension")
end)

test("msgpack: a map key that is not a str", function()
	fails("81 01 01", "an int")
	fails("81 ff 01", "a negative int")
	fails("81 cc ff 01", "a uint 8")
	fails("81 cb 3ff8000000000000 01", "a float")
	fails("81 cb 7ff8000000000000 01", "NaN")
	fails("81 c3 01", "true")
	fails("81 c2 01", "false")
	fails("81 c4 01 61 01", "a bin")
	fails("81 c0 01", "nil")
	fails("81 90 01", "an array")
	fails("81 80 01", "a map")
	fails("81 d6ff00000000 01", "a timestamp")
	fails("81 d4 01 00 01", "an extension no one defines")
	fails("82 a1 61 01 01 01", "after a str")
	fails("81 a1 61 81 01 01", "in a nested map")
	fails("91 81 01 01", "in a map in an array")
	fails("82 a1 61 81 01 01 a1 61 01", "in a value a key given again replaces")
	local _, err = msgpack.decode(hex("81 01 01"))
	eq(err, "msgpack: a map key that is not a str")
	_, err = msgpack.decode(hex("81"))
	eq(err, "msgpack: cut short", "no key at all")
end)

test("msgpack: a str is UTF-8, a bin any bytes", function()
	fails("a1 ff")
	fails("a2 c328", "a sequence cut short")
	fails("a2 c080", "an overlong form")
	fails("a3 eda080", "a surrogate")
	fails("a4 f4908080", "past U+10FFFF")
	fails("81 a1 ff 01", "a key")
	eq(one("a4 f09f9880"), "😀")
	eq(one("c4 01 ff"), "\255")
end)

test("msgpack: 32 levels deep, the outermost the first", function()
	local deep = string.rep("91 ", 31) .. "90"
	local v = one(deep, "32 arrays")
	for _ = 1, 31 do
		v = v[1]
	end
	eq(next(v), nil, "the 32nd")
	fails("91 " .. deep, "33 arrays")
	one(string.rep("81 a1 61 ", 31) .. "80", "32 maps")
	fails(string.rep("81 a1 61 ", 32) .. "80", "33 maps")
	fails(string.rep("91 ", 5000) .. "90", "5000 arrays")
	one(string.rep("81 a1 61 ", 31) .. "01", "31 maps and an int")
end)

-- messages ----------------------------------------------------------------------

local function ev(kind, body)
	local _, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" }, { "s", "f" }, { "e", kind } }, body))
	return m:event()
end

local function caps(body)
	local _, m = hotty.decoder():feed(hotty.encode({ { "a", "ok" }, { "n", "1" }, { "re", "q" } }, body))
	return m:reply():caps()
end

test("messages: the body, decoded once, or nil and why", function()
	local _, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" } }, mp.pack({ w = mp.float(2) })))
	local v, kinds = m:body()
	eq(v.w, 2)
	eq(kinds[v].w, "float")
	eq(m:body(), v, "the same table")
	_, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" } }, "\1\2"))
	local none, err = m:body()
	eq(none, nil)
	eq(type(err), "string")
	_, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" } }, "\1"))
	none, err = m:body()
	eq(none, nil, "a body is a map")
	eq(type(err), "string")
	for _, h in ipairs({ "90", "92 a1 76 a3 302e32", "dc 0000", "d4 05 00", "d6 ff 00000001" }) do
		_, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" } }, hex(h)))
		none, err = m:body()
		eq(none, nil, h)
		eq(err, "hotty: a body that is not a map", h)
	end
	for _, h in ipairs({ "80", "de 0000", "df 00000000" }) do
		_, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" } }, hex(h)))
		eq(next((m:body())), nil, h .. ": an empty map")
	end
	_, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" } }, hex("82 a1 61 01 a1 61 01")))
	none, err = m:body()
	eq(err, "msgpack: a key given twice")
	_, m = hotty.decoder():feed(hotty.encode({ { "a", "ev" } }))
	eq(m:body(), nil, "none")
end)

test("area: four ints, in a map; another kind's detail is not read", function()
	eq(ev("click", mp.pack({ area = { c = 0, r = 1, w = 2, h = 3 } })):area().h, 3)
	eq(ev("click", mp.pack({ area = { c = 0, r = 1, w = 2 } })):area(), nil)
	local e = ev("click", mp.pack({ value = "v", area = { c = 0, r = 1, w = "2", h = 3 } }))
	eq(e:area(), nil, "a str for an int")
	eq(e:value(), nil, "and so nothing the detail carries")
	eq(ev("click", mp.pack({ area = { 0, 1, 2, 3 } })):area(), nil, "an array for a map")
	eq(ev("click", ""):area(), nil)
	eq(ev("submit", mp.pack({ value = "v" })):value(), nil, "a form's field named value")
	eq(ev("submit", mp.pack({ value = "v" })):fields().value, "v")
	eq(ev("submit", ""):fields(), nil, "no detail")
	eq(ev("resize", mp.pack({ w = 320, h = 48 })):size(), nil, "ints for floats")
	eq(ev("zoom", mp.pack({ value = "v" })):value(), nil, "a kind the SDK does not know")
	eq(next(ev("zoom", mp.pack({ value = "v" })).detail), nil)
end)

-- A nil, a key that is not a str or a key given twice, anywhere, and the
-- body does not decode (SPEC §3.3): msgpack.decode fails it.
test("bodies: a nil, a key that is not a str or a key given twice, in any field", function()
	eq(
		ev("click", hex("82 a5 76616c7565 a1 61 a5 76616c7565 a1 61")):value(),
		nil,
		"a known field given twice, the same"
	)
	eq(
		ev("click", hex("82 a5 76616c7565 a1 61 a6 667574757265 82 a1 61 01 d9 01 61 01")):value(),
		nil,
		"a key given twice in a field the SDK does not know"
	)
	eq(ev("click", mp.pack({ value = mp.NIL, href = "#x" })):link(), nil, "nil in a known field")
	eq(
		ev("click", mp.pack({ href = "#x", future = { 1, mp.NIL } })):link(),
		nil,
		"nil in a field the SDK does not know"
	)
	eq(caps(hex("82 a1 76 a3 302e32 a3 6f7073 92 a1 61 c0")), nil, "nil at an array's end")
	eq(caps(hex("82 a1 76 a3 302e32 01 02")), nil, "a key that is not a str where fields are read")
	eq(caps(hex("82 a1 76 a3 302e32 a3 6f7073 81 01 a1 61")), nil, "a map keyed 1 to n for an array")
	eq(
		caps(hex("82 a1 76 a3 302e32 a6 667574757265 81 c4 01 78 a1 61")),
		nil,
		"a bin key in a field the SDK does not know"
	)
end)

-- A known field is read by its type, as msgpack tells kinds apart: an
-- int, a str, a bool and a map unmarked, a float and an array marked so;
-- a bin, a timestamp or an extension of another type, which kinds marks,
-- is no field's type (docs/plx.md).
test("typed reading: a known field of another kind fails the body", function()
	local V = "a1 76 a3 302e32 " -- v: "0.2"
	-- A body of v and n - 1 fields more.
	local function cap(n, h)
		return caps(hex(string.format("%02x ", 0x80 + n) .. V .. h))
	end
	-- What a host sends decodes, and an unknown field of any kind is skipped.
	local c = cap(
		5,
		"a3 6f7073 90" -- ops: []
			.. " a6 6c696d697473 80" -- limits: {}
			.. " a4 63656c6c 82 a1 77 09 a1 68 12" -- cell: {w: 9, h: 18}
			.. " a5 7363616c65 cb 4000000000000000" -- scale: 2.0
	)
	ok(c and #c.ops == 0, "an empty array")
	ok(next(c.limits) == nil, "an empty map")
	eq(c.cell.h, 18)
	eq(c.scale, 2)
	c = cap(
		7,
		"a1 61 c4 01 78 a1 62 d6 ff 00000001 a1 63 d4 05 00 a1 64 cb 3ff0000000000000 a1 65 90 a1 66 92 c4 00 d4 05 00"
	)
	eq(c and c.v, "0.2", "unknown fields of every kind")
	eq(c.raw.a, "x")
	eq(cap(3, "a3 6e6574 81 a1 61 90 a3 6e6574 80"), nil, "a key given twice")
	eq(caps(hex("de 0001 " .. V)).v, "0.2", "a map 16")
	eq(caps(hex("df 00000001 " .. V)).v, "0.2", "a map 32")

	for _, x in ipairs({
		{ "a1 76 c4 03 302e32", "a bin for a str" },
		{ "a1 76 d6 ff 00000001", "a timestamp for a str" },
		{ "a1 76 d4 05 00", "an extension for a str" },
		{ "a1 76 91 a3 302e32", "an array for a str" },
	}) do
		eq(caps(hex("81 " .. x[1])), nil, x[2])
	end
	for _, x in ipairs({
		{ "a3 6f7073 80", "an empty map for an array" },
		{ "a3 6f7073 81 a1 61 a1 61", "a map for an array" },
		{ "a3 6f7073 c4 01 61", "a bin for an array" },
		{ "a3 6f7073 d6 ff 00000001", "a timestamp for an array" },
		{ "a3 6f7073 d4 05 00", "an extension for an array" },
		{ "a3 6f7073 92 a1 61 d4 05 00", "an extension at an array's end" },
		{ "a3 6f7073 93 a1 61 d4 05 00 a1 62", "an extension before an element" },
		{ "a3 6f7073 91 d4 05 00", "an array of an extension" },
		{ "a3 6f7073 92 a1 61 c4 01 62", "a bin in an array of strs" },
		{ "a3 6f7073 91 d6 ff 00000001", "a timestamp in an array of strs" },
		{ "a3 6f7073 91 90", "an array in an array of strs" },
		{ "a4 63656c6c 90", "an empty array for a map" },
		{ "a4 63656c6c 92 09 12", "an array for a map" },
		{ "a4 63656c6c d6 ff 00000001", "a timestamp for a map" },
		{ "a4 63656c6c c7 0c ff 00000000 0000000000000001", "a timestamp of 12 bytes for a map" },
		{ "a4 63656c6c d4 05 00", "an extension for a map" },
		{ "a4 63656c6c c4 00", "a bin for a map" },
		{ "a4 63656c6c 82 a1 77 cb 4022000000000000 a1 68 12", "a float for an int" },
		{ "a4 63656c6c 82 a1 77 09 a1 68 d4 05 00", "an extension for an int" },
		{ "a4 63656c6c 82 a1 77 09 a1 68 d6 ff 00000001", "a timestamp for an int" },
		{ "a4 63656c6c 82 a1 77 09 a1 68 c4 01 12", "a bin for an int" },
		{ "a6 6c696d697473 90", "an empty array for a map of ints" },
		{ "a6 6c696d697473 d6 ff 00000001", "a timestamp for a map of ints" },
		{ "a6 6c696d697473 81 a1 61 d4 05 00", "an extension in a map of ints" },
		{ "a6 6c696d697473 82 a1 61 01 a1 62 d4 05 00", "an extension after an int" },
		{ "a6 6c696d697473 81 a1 61 cb 3ff0000000000000", "a float in a map of ints" },
		{ "a3 6e6574 81 a1 61 80", "an empty map for an array, in a map" },
		{ "a3 6e6574 81 a1 61 91 c4 01 61", "a bin, deeper" },
		{ "a5 7363616c65 02", "an int for a float" },
		{ "a5 7363616c65 d4 05 00", "an extension for a float" },
		{ "a6 7363726f6c6c d4 05 00", "an extension for a bool" },
		{ "a6 7363726f6c6c 01", "an int for a bool" },
	}) do
		eq(cap(2, x[1]), nil, x[2])
	end
	ok(cap(2, "a3 6e6574 81 a1 61 90"), "an empty array, in a map")
	eq(caps(hex("92 a1 76 a3 302e32")), nil, "an array for the body")
	eq(caps(hex("91 81 a1 76 a3 302e32")), nil, "a map in an array for the body")
	eq(hotty.caps(hex("92 a1 76 a3 302e32")), nil, "an array for the body, as plx relays it")

	local function detail(kind, h)
		return ev(kind, hex(h)).detail
	end
	eq(next(detail("click", "82 a4 68726566 a2 2378 a5 76616c7565 d4 05 00")), nil, "an extension for a str")
	eq(next(detail("click", "81 a5 76616c7565 c4 01 61")), nil, "a bin for a str")
	eq(next(detail("click", "81 a5 76616c7565 d6 ff 00000001")), nil, "a timestamp for a str")
	eq(next(detail("change", "82 a7 636865636b6564 d4 05 00 a5 76616c7565 a1 61")), nil, "an extension for a bool")
	eq(next(detail("submit", "82 a1 61 a1 78 a1 62 d4 05 00")), nil, "an extension in a form")
	eq(next(detail("submit", "81 a1 61 c4 01 78")), nil, "a bin in a form")
	eq(next(detail("dragend", "81 a4 6b657973 92 a1 61 d4 05 00")), nil, "an extension in keys")
	eq(next(detail("dragend", "81 a4 6b657973 80")), nil, "an empty map for keys")
	eq(next(detail("click", "81 a4 61726561 90")), nil, "an empty array for an area")
	eq(next(detail("resize", "82 a1 77 cb 4000000000000000 a1 68 d6 ff 00000001")), nil, "a timestamp for a float")
	eq(detail("click", "82 a5 76616c7565 a1 61 a6 667574757265 d4 05 00").value, "a", "an unknown field's extension")
	eq(detail("dragend", "81 a4 6b657973 90").keys[1], nil, "an empty array of keys")
	eq(next(detail("click", "92 a5 76616c7565 a1 61")), nil, "an array for the body")
end)

test("caps: from a body's bytes, as plx relays them; scroll is a bool", function()
	local c = hotty.caps(mp.pack({ v = "0.2", scale = mp.float(2), cell = { w = 18, h = 36 }, future = { 1, "x" } }))
	eq(c.v, "0.2")
	eq(c.scale, 2)
	local w = c:cell_css()
	eq(w, 9)
	eq(c.raw.future[1], 1, "raw has the fields the SDK does not know")
	eq(hotty.caps(""), nil)
	eq(hotty.caps(nil), nil)
	eq(hotty.caps("\1"), nil, "not a map")
	eq(hotty.caps(mp.pack({ v = "0.2", scale = 2 })), nil, "an int for a float")
	ok(hotty.caps(mp.pack({ v = "0.2", scroll = true })).scroll)
	eq(hotty.caps(mp.pack({ v = "0.2", scroll = "yes" })), nil)
	eq(hotty.caps(mp.pack({ v = "0.2", scroll = 1 })), nil)
	eq(hotty.caps(mp.pack({ v = "0.2" })).scroll, false)
	eq(caps(""), nil, "an ok reply to q with no body")
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

-- What a host's own hotty.inflate must do too (docs/plx.md).
test("inflate: the edges a native hotty.inflate keeps", function()
	local good = stored("hello")
	eq(inflate.zlib(good .. "after"), "hello", "bytes after the checksum")
	-- FDICT set, and the header check made good again.
	ok(inflate.zlib("\120\187" .. good:sub(3)) == nil, "a preset dictionary")
	ok(inflate.zlib("\136\28" .. good:sub(3)) == nil, "a window past 32 KiB")
	local max = inflate.MAX
	inflate.MAX = 4
	local out, err = inflate.zlib(good)
	inflate.MAX = max
	eq(out, nil, "more than MAX bytes")
	eq(type(err), "string")
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

-- seams -----------------------------------------------------------------------

-- A host may preload its own hotty.base64, hotty.inflate and hotty.msgpack
-- (docs/plx.md): init.lua reaches them only through require.
test("seams: init.lua uses the hotty.base64, hotty.inflate and hotty.msgpack it is given", function()
	local calls = { encode = 0, decode = 0, zlib = 0, msgpack = 0 }
	local names = { "hotty", "hotty.base64", "hotty.inflate", "hotty.msgpack" }
	local saved = {}
	for i, name in ipairs(names) do
		saved[i] = package.loaded[name]
	end
	package.loaded["hotty.base64"] = {
		encode = function(s)
			calls.encode = calls.encode + 1
			return base64.encode(s)
		end,
		decode = function(s)
			calls.decode = calls.decode + 1
			return base64.decode(s)
		end,
	}
	package.loaded["hotty.inflate"] = {
		zlib = function(s)
			calls.zlib = calls.zlib + 1
			return inflate.zlib(s)
		end,
	}
	-- Its answer whatever the bytes after the first, which says a map (the
	-- whole value is not marked): a body that is no msgpack reads.
	local given = {
		decode = function()
			calls.msgpack = calls.msgpack + 1
			return { v = "given", cell = { w = 7, h = 7 } }, {}
		end,
	}
	package.loaded["hotty.msgpack"] = given
	package.loaded["hotty"] = nil
	local loaded, fresh = pcall(require, "hotty")
	for i, name in ipairs(names) do
		package.loaded[name] = saved[i]
	end
	ok(loaded, tostring(fresh))
	eq(fresh.doc("x", "<p>hi</p>"), hotty.doc("x", "<p>hi</p>"))
	eq(calls.encode, 1, "encode")
	local r, m = fresh.decoder():feed("\27]7279;a=ev:s=x:e=click;" .. base64.encode("\128") .. "\27\\")
	eq(r, hotty.COMPLETE)
	eq(m.payload, "\128")
	eq(calls.decode, 1, "decode")
	r, m = fresh.decoder():feed("\27]7279;a=doc:s=x:o=z;" .. base64.encode(stored("<p>hi</p>")) .. "\27\\")
	eq(m.payload, "<p>hi</p>")
	eq(calls.zlib, 1, "zlib")
	r, m = fresh.decoder():feed(fresh.encode({ { "a", "ok" }, { "n", "1" }, { "re", "q" } }, "\128not msgpack"))
	eq(m:reply():caps().v, "given")
	eq(calls.msgpack, 1, "msgpack")
	eq(fresh.caps("\128not msgpack").cell.w, 7)
	eq(calls.msgpack, 2)
	eq(fresh.msgpack, given)
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

test("query: the SDK's version, and late after it", function()
	eq(hotty.query(), "\27]7279;a=q:n=1:v=0.2\27\\\27[c")
	eq(hotty.query(3, { late = true }), "\27]7279;a=q:n=3:v=0.2:late=1\27\\\27[c")
	eq(hotty.withdraw_late(), "\27]7279;a=q:q=2\27\\", "no version")
	local last = hotty.CODES[#hotty.CODES]
	eq(last, hotty.EVERSION)
	eq(last, "EVERSION")
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
	local _, m = hotty.decoder():feed(
		hotty.encode(
			{ { "a", "err" }, { "s", "x" }, { "re", "delta" } },
			mp.pack({ code = "ENOTARGET", detail = "go" })
		)
	)
	local e = m:reply():err()
	eq(e.code, "ENOTARGET")
	eq(e.detail, "go")
	eq(tostring(e), "hotty: ENOTARGET: go (re=delta, s=x)")
	local _, okm = hotty.decoder():feed("\27]7279;a=ok:re=del")
	eq(okm:reply():err(), nil)
end)

test("messages: an err with a body that does not decode has no code", function()
	for _, body in ipairs({
		"oops",
		mp.pack({ code = 22 }),
		mp.pack({ code = "EINVAL", detail = mp.NIL }),
		mp.pack({ code = "EINVAL", [1] = "x" }),
		mp.pack({ code = "EINVAL", detail = "x" }) .. "\0",
	}) do
		local _, m = hotty.decoder():feed(hotty.encode({ { "a", "err" }, { "re", "doc" } }, body))
		local r = m:reply()
		eq(r.ok, false)
		eq(r.code, nil)
		eq(r.detail, nil)
		eq(r:err().code, "")
		eq(m:event(), nil)
	end
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
	eq(sc:in_sequence(), false, "a prefix")
	sc:feed("79;a=ok")
	eq(sc:in_sequence(), true, "a sequence in progress")
	eq(sc:holding(), "\27]7279;a=ok")
	sc:flush()
	eq(sc:in_sequence(), false, "flushed")
	sc:feed("\27]7279;" .. string.rep("A", hotty.SCAN_MAX))
	eq(sc:in_sequence(), true, "one too long, being dropped")
	eq(sc:holding(), "")
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

test("detector: a reply to the query is a host only in the SDK's version", function()
	local function reply(ctl, body)
		local _, m = hotty.decoder():feed(hotty.encode(ctl, body))
		return m:reply()
	end
	for _, r in ipairs({
		reply({ { "a", "ok" }, { "n", "1" }, { "re", "q" } }, mp.pack({ v = "0.3" })),
		reply({ { "a", "ok" }, { "n", "1" }, { "re", "q" } }, mp.pack({ v = "0.2,0.3" })),
		reply({ { "a", "ok" }, { "n", "1" }, { "re", "q" } }, mp.pack({ v = "" })),
		reply({ { "a", "ok" }, { "n", "1" }, { "re", "q" } }),
		reply({ { "a", "err" }, { "n", "1" }, { "re", "q" } }),
		reply({ { "a", "err" }, { "n", "1" }, { "re", "q" } }, "not msgpack"),
	}) do
		local d = hotty.detector()
		d:start(0)
		eq(d:reply(r, 10), true, "detection's")
		eq(d.state, hotty.TEXT)
		eq(d.decided, true)
		eq(d.done, false, "until the DA1 behind it")
		eq(d.caps, nil)
		eq(d.deadline, 310)
	end
	local d = hotty.detector({ late = true })
	d:start(0)
	d:reply(reply({ { "a", "err" }, { "n", "1" }, { "re", "q" } }), 10)
	eq(d:reply(reply({ { "a", "ok" }, { "n", "1" }, { "re", "q" } }, mp.pack({ v = "0.2" })), 20), true)
	eq(d.state, hotty.NATIVE, "with late, a host after the error")
	eq(d.caps.v, "0.2")
end)

-- keys, field -------------------------------------------------------------------

test("decode_keys: input that is no key is false, so the list goes on", function()
	local keys = hotty.decode_keys("\27[200~a\27[97;1:3u")
	eq(#keys, 3)
	eq(keys[1], false)
	eq(keys[2], "a")
	eq(keys[3], false)
end)

test("decode_keys: a byte that is not UTF-8 is no key", function()
	local keys = hotty.decode_keys("\255b")
	eq(#keys, 2)
	eq(keys[1], false)
	eq(keys[2], "b")
end)

test("parse_key: Shift makes a capital beyond ASCII", function()
	eq(hotty.parse_key("Shift+\195\169"), "\195\137") -- é, É
	eq(hotty.parse_key("Control+Shift+\208\182"), "Control+\208\150") -- ж, Ж
end)

test("keymap: VT does not separate bindings", function()
	eq(
		hotty.parse_keymap("Control+a=line-start\vAlt+b=word-backward Alt+f=word-forward"):format(),
		"Alt+f=word-forward"
	)
end)

test("decode_keys: a modifier field below 2 is no modifier", function()
	local keys = hotty.decode_keys("\27[3;0~\27[97;0u")
	eq(keys[1], "Delete")
	eq(keys[2], "a")
end)

test("keymap: TERMINAL_KEYS reads back as itself", function()
	eq(hotty.parse_keymap(hotty.TERMINAL_KEYS):format(), hotty.TERMINAL_KEYS)
end)

test("keymap: program in a field's keymap, and with a key that does not parse", function()
	local f = hotty.resolve(false, "ArrowLeft=program")
	eq(f:program("ArrowLeft"), true)
	eq(f:lookup("ArrowLeft"), nil, "lookup says as much")
	eq(f:program("ArrowRight"), false)
	eq(f:program(""), false)
	eq(f:program("Hyper+a"), false)
end)

test("field: do is do_action", function()
	local f = hotty.field({ value = "foo bar" })
	eq(f.caret, 7, "the caret starts at the end")
	eq(f["do"](f, "delete-word-backward"), true)
	eq(f.value, "foo ")
	eq(f:do_action("line-start"), false)
	eq(f.caret, 0)
end)

test("keymap: selects with a key that does not parse, or a character", function()
	local m = hotty.resolve(true)
	eq(m:selects(""), false)
	eq(m:selects("Hyper+ArrowLeft"), false)
	eq(m:selects("Shift+a"), false, "A types")
	eq(m:selects("Shift+ArrowLeft"), true)
end)

test("field: selection, from opts and from select", function()
	local f = hotty.field({ value = "foo bar", caret = 2, anchor = 5 })
	local lo, hi = f:selection()
	eq(lo, 2)
	eq(hi, 5)
	f:select(9, 1)
	lo, hi = f:selection()
	eq(lo, 1, "clamped to the value")
	eq(hi, 7)
	f:select(3, 3)
	eq(f.anchor, nil, "select(p, p) selects nothing")
	lo, hi = f:selection()
	eq(lo, 3)
	eq(hi, 3)
end)

test("field: select ends a run of row moves", function()
	local f = hotty.field({ value = "abcd\nab\nabcd", caret = 3, multiline = true })
	f:do_action("line-next")
	f:select(5, 5)
	f:do_action("line-next")
	eq(f.caret, 8, "from the place select put the caret, not the run's")
end)

test("field: a long value", function()
	local f = hotty.field({ value = string.rep("ab ", 3000) })
	eq(f:do_action("delete-word-backward"), true)
	eq(#f.value, 3 * 3000 - 3)
	eq(f:type("x"), true)
	eq(f.caret, 3 * 3000 - 2)
end)

for _, f in ipairs(failures) do
	print("FAIL " .. f)
end
print(string.format("unit    %d passed%s", stats.passed, #failures > 0 and (", " .. #failures .. " failed") or ""))
if #failures > 0 then
	os.exit(1)
end
