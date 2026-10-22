-- The rockspec (gov P-5 rule 6): its MAJOR.MINOR is the hotty version the SDK
-- speaks (M.VERSION), its source is the tag of its version, and it builds
-- every module in lua/hotty/. Takes the rockspecs, and checks the newest:
--
--   luajit tests/rockspec.lua hotty-*.rockspec

local root = ((arg and arg[0]) or ""):match("^(.-)/?tests/[^/]*$") or "."
if root == "" then
	root = "."
end
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local hotty = require("hotty")

local failures = {}
local function check(ok, what)
	if not ok then
		failures[#failures + 1] = what
	end
end

-- A rockspec is Lua: its globals are its fields.
local function load(path)
	local chunk = assert(loadfile(path))
	local spec = {}
	setfenv(chunk, spec)
	chunk()
	return spec
end

-- "0.5.0-1" as { 0, 5, 0, 1 }, or nil.
local function numbers(version)
	local a, b, c, r = (version or ""):match("^(%d+)%.(%d+)%.(%d+)%-(%d+)$")
	return a and { tonumber(a), tonumber(b), tonumber(c), tonumber(r) }
end

local function newer(x, y)
	for i = 1, 4 do
		if x[i] ~= y[i] then
			return x[i] > y[i]
		end
	end
	return false
end

local path, spec, n
for i = 1, #arg do
	local s = load(arg[i])
	local v = numbers(s.version)
	check(v, arg[i] .. ": version " .. tostring(s.version) .. " is not X.Y.Z-R")
	if v and (not n or newer(v, n)) then
		path, spec, n = arg[i], s, v
	end
end
assert(spec, "no rockspec: luajit tests/rockspec.lua hotty-*.rockspec")

local version = spec.version
check(spec.package == "hotty", path .. ": package is " .. tostring(spec.package))
check(path:match("[^/]*$") == "hotty-" .. version .. ".rockspec", path .. ": not named for version " .. version)
check(n[1] .. "." .. n[2] == hotty.VERSION, path .. ": " .. version .. " is not a version of hotty " .. hotty.VERSION)
local tag = "v" .. version:gsub("%-%d+$", "")
check(spec.source and spec.source.tag == tag, path .. ": source.tag is not " .. tag)
check(spec.build and spec.build.type == "builtin", path .. ": build.type is not builtin")

-- Every module in lua/hotty/, and nothing else.
local modules = (spec.build and spec.build.modules) or {}
local files = {}
local ls = assert(io.popen("ls " .. root .. "/lua/hotty"))
for f in ls:lines() do
	local name = f:match("^(.-)%.lua$")
	if name then
		local module = name == "init" and "hotty" or "hotty." .. name
		files[module] = true
		check(modules[module] == "lua/hotty/" .. f, path .. ": module " .. module .. " is not lua/hotty/" .. f)
	end
end
ls:close()
for module in pairs(modules) do
	check(files[module], path .. ": module " .. module .. " is not in lua/hotty/")
end

if #failures > 0 then
	io.stderr:write(table.concat(failures, "\n") .. "\n")
	os.exit(1)
end
print("rockspec: " .. path .. ", hotty " .. hotty.VERSION)
