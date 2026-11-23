-- The fake host's keyboard and named-element pointer input.
local hotty = require("hotty")
local doc = require("document")

local M = {}
local unpack = table.unpack or unpack

local function event(host, kind, node, detail)
	return host:event(host.keyboard, kind, doc.target(node), detail)
end

local function bytepos(value, pos)
	local bytes = 0
	for i, ch in ipairs(hotty.keys.chars(value)) do
		if i > pos then
			break
		end
		bytes = bytes + #ch
	end
	return bytes
end

local function charpos(value, bytes)
	return #hotty.keys.chars(value:sub(1, bytes))
end

local function selection(field)
	return { bytepos(field.value, field.anchor or field.caret), bytepos(field.value, field.caret) }
end

function M.commit(host, node)
	if node and node.before_edit ~= nil then
		local before = node.before_edit
		node.before_edit = nil
		if node.field.value ~= before then
			return event(host, "change", node, { value = node.field.value, rev = node.rev })
		end
	end
	return ""
end

function M.fixup(host, surface)
	if host.keyboard ~= surface or not host.focused then
		return ""
	end
	local node = host.focused
	local connected = doc.ancestor(node, function(n)
		return n == host.docs[surface].tree
	end)
	if connected and doc.focusable(node) then
		return ""
	end
	host.focused = nil
	return connected and M.commit(host, node) or ""
end

function M.blur(host)
	if not host.keyboard then
		return ""
	end
	local out = M.commit(host, host.focused) .. event(host, "blur")
	host.keyboard, host.focused, host.prefix = nil, nil, nil
	return out
end

local function order(tree)
	local items = {}
	doc.walk(tree, function(node)
		if doc.focusable(node) then
			items[#items + 1] = { node = node, tab = tonumber(node.attrs.tabindex) or 0, index = #items + 1 }
		end
	end)
	table.sort(items, function(a, b)
		local pa = a.tab > 0 and a.tab or math.huge
		local pb = b.tab > 0 and b.tab or math.huge
		if pa == pb then
			return a.index < b.index
		end
		return pa < pb
	end)
	return items
end

local function tab_target(tree, current, backwards)
	local nodes = order(tree)
	local first, last, step = 1, #nodes, 1
	if backwards then
		first, last, step = last, first, -1
	end
	local past = not current
	for i = first, last, step do
		local row = nodes[i]
		if row.node == current then
			past = true
		elseif past and row.tab >= 0 then
			return row.node
		end
	end
end

function M.focus(host, surface, target)
	local tree = host.docs[surface].tree
	local node = doc.find(tree, target)
	if target and target ~= "" and not node then
		return "", "ENOTARGET"
	end
	local out = ""
	if host.keyboard ~= surface then
		out = M.blur(host)
		host.keyboard = surface
	end
	if not target or target == "" then
		node = host.focused or tab_target(tree)
	end
	if doc.focusable(node) and node ~= host.focused then
		out = out .. M.commit(host, host.focused)
		host.focused = node
	end
	host.prefix = nil
	return out
end

local function keymap(host, tree, node)
	local inner, chain = {}, {}
	local key_attr = host.session == "0.8" and "data-keys" or "data-keys-inner"
	local reader = doc.reader(node)
	local parent = node and node.parent
	if not node then
		node = doc.walk(tree, function(n)
			return n.tag == "body"
		end)
		parent = node or doc.walk(tree, function(n)
			return n.tag == "html"
		end)
	end
	while parent do
		chain[#chain + 1] = parent
		parent = parent.parent
	end
	for i = #chain, 1, -1 do
		inner[#inner + 1] = chain[i].attrs[key_attr] or ""
	end
	return hotty.resolve(host.platform, reader, node and node.attrs["data-keys"], unpack(inner))
end

local function options(node)
	local out = {}
	doc.walk(node, function(n)
		if n.tag == "option" then
			out[#out + 1] = n
		end
	end)
	return out
end

local function option_value(node)
	return node.attrs.value or doc.text(node)
end

local function selected(node, items)
	if node.selected then
		return node.selected
	end
	for i, option in ipairs(items) do
		if option.attrs.selected then
			return i
		end
	end
	return 1
end

local function pick(host, node, key)
	local items = options(node)
	local current = selected(node, items)
	local first, last, step = 1, #items, 1
	local text = hotty.key_text(key)
	if key == "arrow_up" or key == "page_up" then
		first, last, step = current - 1, 1, -1
	elseif key == "arrow_down" or key == "page_down" then
		first = current + 1
	elseif key == "end" then
		first, last, step = last, first, -1
	elseif key == "enter" or key == "space" then
		return ""
	elseif key == "home" then
		-- Keep the whole range.
	elseif not text then
		return nil
	end
	for i = first, last, step do
		local index = text and ((current + i - 1) % #items + 1) or i
		local item = items[index]
		if not item.attrs.disabled and (not text or doc.text(item):lower():sub(1, #text) == text:lower()) then
			if index == current then
				break
			end
			node.selected, node.rev = index, node.rev + 1
			return event(host, "change", node, { value = option_value(item), rev = node.rev })
		end
	end
	return ""
end

local function checked(node)
	if node.checked ~= nil then
		return node.checked
	end
	return node.attrs.checked ~= nil
end

local function form_of(node)
	return doc.ancestor(node, function(n)
		return n.tag == "form"
	end)
end

local function radio_group(node, tree, visit)
	local name = node.attrs.name
	if node.tag ~= "input" or node.attrs.type ~= "radio" or not name or name == "" then
		visit(node)
		return
	end
	local form = form_of(node)
	doc.walk(tree, function(other)
		if
			other.tag == "input"
			and other.attrs.type == "radio"
			and other.attrs.name == name
			and form_of(other) == form
		then
			visit(other)
		end
	end)
end

local function revision(node, tree)
	local rev = 0
	radio_group(node, tree, function(other)
		rev = math.max(rev, other.rev)
	end)
	return rev
end

local function check_control(node, tree, value)
	if value then
		radio_group(node, tree, function(other)
			other.checked = false
		end)
	end
	node.checked = value
end

local function submit(host, node)
	local out = M.commit(host, node)
	local form = form_of(node)
	if not form then
		return out
	end
	local fields = {}
	doc.walk(form, function(n)
		local name = n.attrs.name
		if not name or name == "" or not doc.focusable(n) then
			return
		end
		local value
		local field = doc.field(n)
		if field then
			value = field.value
		elseif n.tag == "input" and (n.attrs.type == "radio" or n.attrs.type == "checkbox") and checked(n) then
			value = n.attrs.value or "on"
		elseif n.tag == "select" then
			local items = options(n)
			local option = items[selected(n, items)]
			value = option and option_value(option)
		end
		if value ~= nil then
			fields[#fields + 1] = { name, value }
		end
	end)
	return out .. event(host, "submit", form, { fields = fields })
end

local function link_detail(node, detail)
	if node.tag == "a" then
		detail.href = node.attrs.href
		detail.url = doc.link_url(node)
	end
	detail.value = node.attrs.value
	return detail
end

local function area_of(host, surface, node, at)
	if node and host.area_of then
		return host.area_of(surface, node)
	end
	return at and at.area
end

local function activate(host, surface, node, detail)
	if (node.tag == "input" or node.tag == "button") and not doc.focusable(node) then
		return ""
	end
	local kind = node.tag == "input" and node.attrs.type
	if kind == "checkbox" or kind == "radio" then
		local value = kind == "radio" or not checked(node)
		if value == checked(node) then
			return ""
		end
		local tree = host.docs[surface].tree
		check_control(node, tree, value)
		node.rev = revision(node, tree) + 1
		return host:event(surface, "change", doc.target(node), {
			checked = value,
			value = node.attrs.value or "on",
			rev = node.rev,
		})
	end
	if doc.id(node) or (node.tag == "a" and node.attrs.href) then
		return host:event(surface, "click", doc.id(node), link_detail(node, detail))
	end
	return ""
end

function M.key(host, name)
	local key = hotty.parse_key(name)
	local current = host.focused
	local tree = host.keyboard and host.docs[host.keyboard].tree
	if not key or not tree or host.prefix then
		return false, ""
	end
	local map = keymap(host, tree, current)
	if map:program(key) then
		host.prefix = map:prefix(key)
		return false, ""
	end
	if key == "tab" or key == "shift+tab" then
		local next_node = tab_target(tree, current, key == "shift+tab")
		if not next_node then
			return true, M.blur(host)
		end
		local out = M.commit(host, current)
		host.focused = next_node
		return true, out .. event(host, "focus", next_node)
	elseif not current then
		return false, ""
	end
	if host.session ~= "0.8" and (key == "shift+f10" or key == "context_menu") then
		local target = doc.ancestor(current, function(n)
			return doc.on(n, "contextmenu")
		end)
		if target then
			local id = doc.id(target)
			local area = id and area_of(host, host.keyboard, target)
			return true, host:event(host.keyboard, "contextmenu", id, area and { area = area } or nil)
		end
	end
	local field = doc.field(current)
	if field then
		local action = map:lookup(key)
		if not action or action == "copy" or action == "cut" or action == "paste" then
			return false, ""
		elseif action == "submit" then
			return true, submit(host, current)
		end
		if current.attrs.readonly and (action == hotty.INSERT or action == "newline" or action:match("^delete%-")) then
			return true, ""
		end
		local anchor, caret, value = field.anchor, field.caret, field.value
		local changed = field:key(map, key)
		local detail = {}
		if changed then
			current.rev = current.rev + 1
			current.before_edit = current.before_edit or value
		end
		if doc.on(current, "caret") then
			detail.sel = selection(field)
		end
		if changed and doc.on(current, "input") then
			detail.value, detail.rev = field.value, current.rev
			return true, event(host, "input", current, detail)
		elseif detail.sel and (changed or anchor ~= field.anchor or caret ~= field.caret) then
			detail.rev = current.rev
			return true, event(host, "caret", current, detail)
		end
		return true, ""
	end
	local reader = doc.reader(current)
	local bare = key:gsub("^shift%+", "")
	if reader == "select" then
		local out = pick(host, current, bare)
		return out ~= nil, out or ""
	elseif reader == "button" and (bare == "space" or bare == "enter") then
		return true, activate(host, host.keyboard, current, { area = area_of(host, host.keyboard, current) })
	end
	return false, ""
end

local function integer(n)
	return type(n) == "number" and n % 1 == 0
end

function M.set_field(host, msg)
	local c = msg.control
	local tree = host.docs[c.s].tree
	local node = doc.find(tree, c.t)
	local body, kinds = msg:body()
	if not c.t or c.t == "" then
		return "EINVAL", "t"
	elseif not node then
		return "ENOTARGET", c.t
	elseif not body then
		return "EINVAL", "body"
	end
	local marks = kinds[body] or {}
	local types = {
		rev = "number",
		value = "string",
		text = "string",
		from = "number",
		to = "number",
		sel = "table",
		checked = "boolean",
	}
	for key, want in pairs(types) do
		if body[key] ~= nil or marks[key] then
			local mark = key == "sel" and "array" or nil
			if type(body[key]) ~= want or marks[key] ~= mark then
				return "EINVAL", key
			end
		end
	end
	if body.sel then
		local sel_marks = kinds[body.sel] or {}
		if #body.sel ~= 2 or not integer(body.sel[1]) or not integer(body.sel[2]) or next(sel_marks) then
			return "EINVAL", "sel"
		end
	end
	if
		not integer(body.rev)
		or (body.value ~= nil and (body.text ~= nil or body.from ~= nil or body.to ~= nil))
		or (body.from == nil) ~= (body.to == nil)
		or (body.from ~= nil and body.text == nil)
	then
		return "EINVAL", "field"
	end
	local rev = revision(node, tree)
	if body.rev ~= rev then
		return "ESTALE", tostring(rev)
	end
	local field = doc.field(node)
	if field then
		local value, caret = field.value, nil
		local function clean(text)
			if field.multiline then
				return (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
			end
			return (text:gsub("[\r\n]", ""))
		end
		local function boundary(text, pos)
			return integer(pos)
				and pos >= 0
				and pos <= #text
				and (pos == #text or bit.band(text:byte(pos + 1), 0xc0) ~= 0x80)
		end
		local from, to = body.from, body.to
		if
			body.checked ~= nil
			or (body.value ~= nil and (body.text ~= nil or from ~= nil or to ~= nil))
			or (body.text == nil and (from ~= nil or to ~= nil))
		then
			return "EINVAL", "field"
		elseif body.value ~= nil then
			if type(body.value) ~= "string" then
				return "EINVAL", "value"
			end
			value = clean(body.value)
		elseif body.text ~= nil then
			if from == nil and to == nil then
				local sel = selection(field)
				from, to = math.min(sel[1], sel[2]), math.max(sel[1], sel[2])
			end
			if type(body.text) ~= "string" or not boundary(value, from) or not boundary(value, to) or to < from then
				return "EINVAL", "text"
			end
			local text = clean(body.text)
			value, caret = value:sub(1, from) .. text .. value:sub(to + 1), from + #text
		elseif body.sel == nil then
			return "EINVAL", "field"
		end
		local sel = body.sel or { caret or #value, caret or #value }
		if type(sel) ~= "table" or #sel ~= 2 or not boundary(value, sel[1]) or not boundary(value, sel[2]) then
			return "EINVAL", "sel"
		end
		field.value = value
		field:select(charpos(value, sel[1]), charpos(value, sel[2]))
	elseif node.tag == "select" and type(body.value) == "string" then
		for i, option in ipairs(options(node)) do
			if option_value(option) == body.value then
				node.selected = i
				return
			end
		end
		return "EINVAL", "value"
	elseif (node.attrs.type == "checkbox" or node.attrs.type == "radio") and type(body.checked) == "boolean" then
		check_control(node, tree, body.checked)
	else
		return "EINVAL", c.t
	end
end

local function opted(node, word)
	return doc.ancestor(node, function(n)
		return doc.on(n, word)
	end)
end

local function right_target(node)
	return doc.ancestor(node, function(n)
		return (doc.on(n, "rightbutton") or doc.on(n, "contextmenu")) and not doc.hyperlink(n)
	end)
end

local function aux_target(node)
	return doc.ancestor(node, function(n)
		return doc.on(n, "aux") and not doc.hyperlink(n)
	end)
end

local function click_target(node)
	return doc.ancestor(node, function(n)
		return doc.on(n, "click") or doc.reader(n) == "button"
	end)
end

local function drag_source(node)
	return doc.ancestor(node, function(n)
		return doc.on(n, "drag")
	end)
end

local function drag_target(node)
	return doc.ancestor(node, function(n)
		return doc.id(n) and (doc.on(n, "drag") or doc.on(n, "drop"))
	end)
end

local function focus_click(host, surface, node)
	local focus = doc.ancestor(node, function(n)
		return (tonumber(n.attrs.tabindex) or 0) >= 0 and doc.focusable(n)
	end)
	if not focus then
		return M.blur(host)
	end
	local out
	if host.keyboard ~= surface then
		out = M.blur(host)
	else
		out = focus ~= host.focused and M.commit(host, host.focused) or ""
	end
	host.keyboard, host.focused, host.prefix = surface, focus, nil
	return out .. host:event(surface, "focus", doc.target(focus))
end

local function step_counts(node)
	local x, y = (node.attrs["data-steps"] or ""):match("^%s*(%d+)%s*(%d*)%s*$")
	if x then
		return tonumber(x), tonumber(y)
	end
end

local function step_at(cell, start, size, count)
	if count and count > 0 and cell then
		return math.max(0, math.min(count, math.floor((cell + 0.5 - start) * count / size + 0.5)))
	end
end

local function drag_cell(host, down, target, at)
	local cell = { c = at.c, r = at.r, mods = at.mods ~= 0 and at.mods or nil, x = at.x, y = at.y }
	local box = area_of(host, down.surface, down.drag)
	if box then
		cell.x = step_at(at.c, box.c, box.w, down.steps_x)
		cell.y = step_at(at.r, box.r, box.h, down.steps_y)
	end
	if target and doc.on(target, "drop") then
		local dest = area_of(host, down.surface, target)
		if dest then
			local x, y = step_counts(target)
			cell.tx = step_at(at.c, dest.c, dest.w, x)
			cell.ty = step_at(at.r, dest.r, dest.h, y)
		else
			cell.tx, cell.ty = at.tx, at.ty
		end
	end
	return cell
end

local function begin_pointer(host, surface, state, node, button, at)
	local mods = at.mods or 0
	if bit.band(mods, hotty.MOD_ALT) ~= 0 then
		return M.blur(host)
	end
	local placement = host.placements[surface]
	if not state or state.detached or not placement or at.outside then
		return button == hotty.BUTTON_PRIMARY and M.blur(host) or ""
	end
	local primary = button == hotty.BUTTON_PRIMARY
	local legacy = host.session == "0.8"
	if button == 5 or (not primary and not legacy and bit.band(mods, hotty.MOD_SHIFT) ~= 0) then
		return ""
	end
	local owner
	if button == hotty.BUTTON_SECONDARY then
		owner = legacy and opted(node, "secondary") or not legacy and right_target(node)
		if owner and (legacy or not doc.on(owner, "rightbutton")) then
			local id = doc.id(owner)
			return host:event(surface, legacy and "press" or "contextmenu", id, {
				c = at.c,
				r = at.r,
				mods = mods ~= 0 and mods or nil,
				button = legacy and button or nil,
				area = id and area_of(host, surface, owner, at) or nil,
			})
		end
	elseif primary then
		if doc.ancestor(node, doc.hyperlink) then
			return M.blur(host)
		end
		owner = click_target(node)
	elseif not legacy then
		owner = aux_target(node)
	end
	if not primary and not owner then
		return ""
	end
	local drag = primary and drag_source(node) or (not primary and owner and doc.on(owner, "drag") and owner)
	if not doc.id(drag or nil) then
		drag = nil
	end
	local down = { surface = surface, button = button, owner = owner, drag = drag }
	host.pointer_button = down
	if drag then
		down.steps_x, down.steps_y = step_counts(drag)
		down.start = drag_cell(host, down, nil, at)
		down.last = { target = drag_target(node), cell = down.start }
		down.last_cell = down.start
	end
	if not primary then
		return ""
	end
	local out = ""
	if placement.press then
		local named = doc.ancestor(node, function(n)
			return doc.id(n) ~= nil
		end)
		local detail = { area = area_of(host, surface, named, at), mods = mods ~= 0 and mods or nil }
		if not named then
			detail.area = nil
		end
		out = host:event(surface, "press", doc.id(named), next(detail) and detail or nil)
	end
	out = out .. focus_click(host, surface, node)
	if drag then
		down.moving = true
		out = out .. host:event(surface, "dragstart", doc.id(drag), down.start)
	end
	return out
end

local function move_drag(host, down, target, at)
	local cell = drag_cell(host, down, target, at)
	down.last_cell = cell
	local out = ""
	if not down.moving then
		local far = at.past_slop
		if far == nil then
			far = at.c ~= down.start.c or at.r ~= down.start.r
		end
		if not far then
			return ""
		end
		down.moving = true
		local detail = vim.tbl_extend("force", down.start, { button = down.button })
		out = host:event(down.surface, "dragstart", doc.id(down.drag), detail)
	end
	local last = down.last
	down.last = { target = target, cell = cell }
	if
		last.target == target
		and last.cell.x == cell.x
		and last.cell.y == cell.y
		and last.cell.tx == cell.tx
		and last.cell.ty == cell.ty
		and (target or (last.cell.c == cell.c and last.cell.r == cell.r))
	then
		return out
	end
	return out .. host:event(down.surface, "drag", doc.id(target), cell)
end

local function release_pointer(host, down, node, at)
	local surface = down.surface
	local target = drag_target(node)
	local out = ""
	if down.moving then
		out = host:event(surface, "dragend", doc.id(target), drag_cell(host, down, target, at))
	end
	local owner = down.owner
	if not owner then
		return out
	end
	local mods = at.mods ~= 0 and at.mods or nil
	local area = area_of(host, surface, owner, at)
	if down.button == hotty.BUTTON_PRIMARY then
		if
			(not down.moving or drag_source(node) == down.drag)
			and not doc.ancestor(node, doc.hyperlink)
			and click_target(node) == owner
		then
			out = out .. activate(host, surface, owner, { area = area, mods = mods })
		end
	elseif not down.moving then
		local release
		if down.button == hotty.BUTTON_SECONDARY then
			release = right_target(node)
		else
			release = aux_target(node)
		end
		if release == owner then
			local id = doc.id(owner)
			local detail = link_detail(owner, { c = at.c, r = at.r, mods = mods, button = down.button })
			detail.area = (id or detail.href) and area or nil
			out = out .. host:event(surface, "auxclick", id, detail)
		end
	end
	return out
end

-- All buttons in a chord stay with the first route until the last up.
-- Only the first press can create a surface gesture.
function M.pointer(host, surface, phase, target, button, at)
	local state = host.docs[surface]
	local node = state and (type(target) == "table" and target or doc.find(state.tree, target))
	if phase == "down" then
		if host.held_buttons then
			host.held_buttons[button] = true
			return ""
		end
		host.held_buttons = { [button] = true }
		return begin_pointer(host, surface, state, node, button, at)
	end
	local down = host.pointer_button
	if down and (surface ~= down.surface or at.outside) then
		node = nil
	end
	if phase == "up" then
		if host.held_buttons then
			host.held_buttons[button] = nil
			if not next(host.held_buttons) then
				host.held_buttons = nil
			end
		end
		if down and down.button == button then
			host.pointer_button = nil
			return release_pointer(host, down, node, at)
		end
	elseif phase == "move" and down and down.drag then
		return move_drag(host, down, drag_target(node), at)
	end
	return ""
end

return M
