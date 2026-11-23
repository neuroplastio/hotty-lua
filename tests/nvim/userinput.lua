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
	if node and node.dirty then
		node.dirty = nil
		return event(host, "change", node, { value = node.field.value, rev = node.rev })
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
	end
	detail.value = node.attrs.value
	return detail
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
			return true, host:event(host.keyboard, "contextmenu", doc.id(target))
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
		local anchor, caret = field.anchor, field.caret
		local changed = field:key(map, key)
		local detail = {}
		if changed then
			current.rev, current.dirty = current.rev + 1, true
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
		local input = current.attrs.type
		if input == "checkbox" or input == "radio" then
			local value = input == "radio" or not checked(current)
			if value == checked(current) then
				return true, ""
			end
			check_control(current, tree, value)
			current.rev = revision(current, tree) + 1
			return true,
				event(
					host,
					"change",
					current,
					{ checked = value, value = current.attrs.value or "on", rev = current.rev }
				)
		end
		return true, event(host, "click", current, link_detail(current, {}))
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
		return doc.on(n, "rightbutton") or doc.on(n, "contextmenu")
	end)
end

-- Tests name the element and supply pointer cells (and area if needed).
-- A nil target means the pointer is outside the surface.
function M.pointer(host, surface, phase, target, button, at)
	local state = host.docs[surface]
	local node = state and doc.find(state.tree, target)
	local mods = at.mods or 0
	if
		phase == "down"
		and (
			not node
			or state.detached
			or not host.placements[surface]
			or (button ~= hotty.BUTTON_PRIMARY and bit.band(mods, hotty.MOD_SHIFT) ~= 0 and host.session ~= "0.8")
			or button == 5
			or host.pointer_button
		)
	then
		return ""
	end
	if phase == "down" and bit.band(mods, hotty.MOD_ALT) ~= 0 then
		return M.blur(host)
	end
	local function send(kind, element, detail)
		local id = kind == "press" and button == hotty.BUTTON_PRIMARY and doc.target(element) or doc.id(element)
		if not id and detail and not detail.href then
			detail.area = nil
		end
		return host:event(surface, kind, id, detail)
	end
	local function cell()
		return { c = at.c, r = at.r, mods = mods ~= 0 and mods or nil, x = at.x, y = at.y, tx = at.tx, ty = at.ty }
	end
	if phase == "down" then
		local legacy = host.session == "0.8"
		if button == hotty.BUTTON_SECONDARY then
			local owner = legacy and opted(node, "secondary") or not legacy and right_target(node)
			if not owner then
				return ""
			end
			if legacy or not doc.on(owner, "rightbutton") then
				host.pointer_button = { surface = surface, button = button, menu = true }
				local detail = cell()
				detail.area = at.area
				if legacy then
					detail.button = button
				end
				return send(legacy and "press" or "contextmenu", owner, detail)
			end
			node = owner
		elseif button ~= hotty.BUTTON_PRIMARY then
			if legacy then
				return ""
			end
			node = opted(node, "aux")
			if not node then
				return ""
			end
		end
		local drag = button == hotty.BUTTON_PRIMARY and opted(node, "drag") or nil
		if button ~= hotty.BUTTON_PRIMARY and doc.on(node, "drag") then
			drag = node
		end
		drag = drag and drag.attrs.id ~= "" and drag.attrs.id and drag or nil
		host.pointer_button = {
			surface = surface,
			button = button,
			owner = node,
			drag = drag,
			start = cell(),
		}
		if button == hotty.BUTTON_PRIMARY then
			host.prefix = nil
			local out = ""
			if host.placements[surface].press then
				out = send("press", node, { mods = cell().mods, area = at.area })
			end
			if drag then
				host.pointer_button.moving = true
				out = out .. send("dragstart", drag, cell())
			end
			return out
		end
		return ""
	end
	local down = host.pointer_button
	if not down or down.surface ~= surface or (phase == "up" and down.button ~= button) then
		return ""
	end
	if phase == "up" then
		host.pointer_button = nil
	end
	if down.menu then
		return ""
	end
	local drag_target = doc.ancestor(node, function(n)
		return n.attrs.id and n.attrs.id ~= "" and (doc.on(n, "drag") or doc.on(n, "drop"))
	end)
	if phase == "move" and down.drag then
		local out = ""
		local far = at.past_slop
		if far == nil then
			far = at.c ~= down.start.c or at.r ~= down.start.r
		end
		if not down.moving and not far then
			return ""
		end
		if not down.moving then
			down.moving = true
			down.start.button = down.button
			out = send("dragstart", down.drag, down.start)
		end
		local detail = cell()
		local last = down.last
		down.last = { node = drag_target, detail = detail }
		if
			last
			and last.node == drag_target
			and last.detail.x == detail.x
			and last.detail.y == detail.y
			and last.detail.tx == detail.tx
			and last.detail.ty == detail.ty
			and (drag_target or (last.detail.c == detail.c and last.detail.r == detail.r))
		then
			return out
		end
		return out .. send("drag", drag_target, detail)
	elseif phase == "up" then
		local out = down.moving and send("dragend", drag_target, cell()) or ""
		if down.button == hotty.BUTTON_PRIMARY then
			return out
		end
		local release = down.button == hotty.BUTTON_SECONDARY and right_target(node) or nil
		if down.button ~= hotty.BUTTON_SECONDARY then
			release = opted(node, "aux")
		end
		if release == down.owner and not down.moving then
			local detail = link_detail(down.owner, cell())
			detail.button, detail.area = down.button, at.area
			return out .. send("auxclick", down.owner, detail)
		end
		return out
	end
	return ""
end

return M
