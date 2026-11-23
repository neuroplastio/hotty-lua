-- Cell boxes transcribed from the signed fixture markup, in hit order.
-- Each row is { id or @tag selector, column, row, width, height }.
local document = require("document")

local pair = { { "a", 0, 0, 3, 1 }, { "b", 3, 0, 3, 1 } }
local other_buttons = {
	{ "i", 3, 1, 3, 1 },
	{ "o", 0, 0, 9, 3 },
	{ "k", 0, 4, 3, 1 },
	{ "n", 10, 0, 3, 1 },
	{ "s", 4, 4, 3, 1 },
	{ "f", 10, 2, 6, 1 },
}
local chords = { { "d", 0, 0, 3, 1 }, { "i", 4, 0, 3, 1 } }
local click = { { "b", 2, 1, 3, 2 } }
local fixtures = {
	["p=1 asks for presses"] = { { "p", 0, 0, 4, 1 } },
	["a drag reports dragstart"] = {
		{ "s", 1, 0, 1, 1 },
		{ "a", 0, 0, 3, 1 },
		{ "b", 3, 0, 3, 1 },
		{ "g", 6, 0, 3, 1 },
	},
	["a drag that ends on the element"] = pair,
	["an id outside printable ASCII"] = { { "café", 0, 0, 3, 1 }, { "a😀b", 4, 0, 3, 1 } },
	["only an element with an id and drag"] = { { "@i", 0, 0, 3, 1 }, { "n", 3, 0, 3, 1 } },
	["hide and a new document end a drag"] = pair,
	["a press with Alt is the program's"] = pair,
	["click and press report area"] = { click[1], { "h", 7, 0, 3, 1 } },
	["a primary press is as it was on an element with contextmenu"] = { { "m", 2, 0, 3, 1 }, { "k", 6, 1, 3, 1 } },
	["a secondary press on an element with contextmenu"] = other_buttons,
	["a secondary press over an element without contextmenu"] = other_buttons,
	["a contextmenu makes no click on its release"] = other_buttons,
	["on a host that reports the menu key"] = { { "m", 0, 0, 4, 1 }, { "q", 6, 0, 4, 1 } },
	["the menu key with nothing focused"] = { { "c", 1, 0, 3, 1 }, { "w", 0, 0, 6, 1 }, { "p", 8, 0, 4, 1 } },
	["another button's press on an element with aux"] = other_buttons,
	["back and forward come under the same aux"] = other_buttons,
	["another button released anywhere but on the element"] = other_buttons,
	["another button with Shift held is the terminal's"] = other_buttons,
	["another button's press does nothing else"] = other_buttons,
	["what ends a drag early ends another button's hold"] = other_buttons,
	["contextmenu and aux do not cross"] = { { "s", 0, 0, 3, 1 }, { "a", 4, 0, 3, 1 }, { "b", 8, 0, 3, 1 } },
	["one button at a time: another button pressed"] = chords,
	["one button at a time: a secondary press"] = { { "g", 0, 0, 5, 1 } },
	["one button at a time until every button is released"] = chords,
	["an element with drag and aux is dragged"] = { { "n", 2, 1, 3, 1 }, { "c", 0, 0, 10, 3 } },
	["another button's drag of an element with data-steps"] = {
		{ "track", 4, 0, 8, 1 },
		{ "card", 0, 0, 6, 1 },
		{ "ada", 0, 1, 6, 1 },
		{ "col", 0, 2, 6, 3 },
	},
	["the secondary button on an element with drag and rightbutton"] = { { "v", 0, 0, 10, 3 }, { "m", 12, 0, 4, 1 } },
	["for the secondary button the nearer of rightbutton and contextmenu decides"] = {
		{ "i", 2, 1, 3, 1 },
		{ "j", 14, 1, 3, 1 },
		{ "o", 0, 0, 10, 3 },
		{ "q", 11, 0, 9, 3 },
	},
	["an auxclick's detail is a click's"] = {
		{ "@a.l", 0, 0, 4, 1 },
		{ "v", 5, 0, 3, 1 },
		{ "@a.h", 10, 0, 3, 1 },
		{ "@i.q", 14, 0, 3, 1 },
		{ "@w/a", 0, 2, 3, 1 },
		{ "w", 0, 2, 9, 1 },
	},
	["area counts from the surface's top left cell"] = { { "e", 4, 2, 2, 1 } },
	["a click from the keyboard carries area too"] = { { "k", -1, 3, 4, 2 }, { "@a", 10, 0, 3, 1 } },
	["focus fixup: a field in a fieldset made disabled"] = { { "l", 0, 0, 4, 1 } },
	["the user moving focus sends focus naming"] = {
		{ "a", 0, 0, 8, 1 },
		{ "list", 0, 1, 8, 1 },
		{ "@w/button", 0, 2, 8, 1 },
	},
	["p belongs to the surface"] = { { "p", 0, 0, 30, 1 } },
	["a prefix ends when the surface loses the keyboard"] = { { "b", 0, 0, 4, 1 }, { "c", 0, 1, 4, 1 } },
	["a click carries the modifier keys"] = click,
}

local M = {}
function M.for_vector(name)
	for prefix, boxes in pairs(fixtures) do
		if name:sub(1, #prefix) == prefix then
			return boxes
		end
	end
end

local function find(tree, selector)
	if selector:sub(1, 1) ~= "@" then
		return document.find(tree, selector)
	end
	local ancestor, tag = selector:match("^@([^/]+)/(%w+)$")
	if ancestor then
		tree = document.find(tree, ancestor)
	else
		tag = selector:match("^@(%w+)")
	end
	if tree then
		local class = selector:match("%.(%w+)$")
		return document.walk(tree, function(node)
			return node.tag == tag and (not class or vim.tbl_contains(vim.split(node.attrs.class or "", "%s+"), class))
		end)
	end
end

local function contains(box, c, r)
	return c >= box.c and c < box.c + box.w and r >= box.r and r < box.r + box.h
end

function M.new(host, boxes)
	local function nodes(surface)
		local state = host.docs[surface]
		local out = {}
		if state and boxes then
			for _, row in ipairs(boxes) do
				local node = find(state.tree, row[1])
				if node then
					out[#out + 1] = { node = node, box = { c = row[2], r = row[3], w = row[4], h = row[5] } }
				end
			end
		end
		return out
	end
	host.area_of = function(surface, node)
		for _, item in ipairs(nodes(surface)) do
			if item.node == node then
				return item.box
			end
		end
	end
	local point = {}
	return function(step)
		if step.pointer == "move" then
			point.surface, point.at = step.s, step.at
		end
		local surface, at = step.s or point.surface, point.at
		assert(surface and at, "pointer has no position")
		local entries = nodes(surface)
		local c, r, target
		if type(at) == "string" then
			for _, item in ipairs(entries) do
				if item.node.attrs.id == at then
					local box = item.box
					target = item.node
					c, r = box.c + math.floor((box.w - 1) / 2), box.r + math.floor((box.h - 1) / 2)
					break
				end
			end
			assert(target, "missing fixture box for " .. at)
		else
			c, r = at[1], at[2]
			for _, item in ipairs(entries) do
				if contains(item.box, c, r) then
					target = item.node
					break
				end
			end
		end
		local placement = host.placements[surface]
		local outside = not placement
			or not contains(placement.window and {
				c = placement.window.x,
				r = placement.window.y,
				w = placement.window.w,
				h = placement.window.h,
			} or { c = 0, r = 0, w = placement.c, h = placement.r }, c, r)
		local mods = 0
		local bits = { shift = 1, alt = 2, ctrl = 4, super = 8 }
		for _, name in ipairs(step.keys or {}) do
			mods = bit.bor(mods, bits[name])
		end
		return host:pointer(
			surface,
			step.pointer,
			target,
			step.button,
			{ c = c, r = r, mods = mods, outside = outside }
		)
	end
end

return M
