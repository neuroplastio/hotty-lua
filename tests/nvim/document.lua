-- The fake host's document tree. It reads HTML fragments without doing CSS
-- or layout. Element identity survives attribute and child edits.
local hotty = require("hotty")

local M = {}
local VOID = {
	area = true,
	base = true,
	br = true,
	col = true,
	embed = true,
	hr = true,
	img = true,
	input = true,
	link = true,
	meta = true,
	param = true,
	source = true,
	track = true,
	wbr = true,
}
local TEXT = { style = true, script = true, textarea = true, title = true }
local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function entities(text)
	return (text:gsub("&([%w#]+);", ENTITIES))
end

local function attributes(source)
	local attrs = {}
	while true do
		local key, pos = source:match("^%s*([^%s=/]+)()", 1)
		if not key then
			break
		end
		source = source:sub(pos)
		local value = ""
		local rest = source:match("^%s*=%s*(.*)$")
		if rest then
			local quote = rest:sub(1, 1)
			if quote == '"' or quote == "'" then
				local stop = rest:find(quote, 2, true) or (#rest + 1)
				value, source = rest:sub(2, stop - 1), rest:sub(stop + 1)
			else
				value, source = rest:match("^([^%s]*)(.*)$")
			end
		end
		key = key:lower()
		attrs[key] = attrs[key] or entities(value)
	end
	return attrs
end

local function append(parent, child)
	parent.children[#parent.children + 1] = child
	child.parent = parent
end

local function read_markup(html, start)
	local quote
	for pos = start, #html do
		local ch = html:sub(pos, pos)
		if ch == quote then
			quote = nil
		elseif not quote then
			if ch == ">" then
				return html:sub(start, pos - 1), pos + 1
			elseif ch == "'" or ch == '"' then
				quote = ch
			end
		end
	end
end

function M.parse(html)
	local root = { tag = "", attrs = {}, children = {} }
	local parent, pos = root, 1
	local lower = html:lower()
	while pos <= #html do
		local start = html:find("<", pos, true) or #html + 1
		if start > pos then
			append(parent, { text = entities(html:sub(pos, start - 1)) })
		end
		local markup, next_pos = read_markup(html, start + 1)
		local closing, tag, attrs
		if markup then
			closing, tag, attrs = markup:match("^(/?)([%a][%w%-]*)(.*)$")
		end
		if html:sub(start, start + 3) == "<!--" then
			pos = (html:find("-->", start + 4, true) or #html) + 3
		elseif tag and closing == "/" then
			tag = tag:lower()
			local node = parent
			while node.parent and node.tag ~= tag do
				node = node.parent
			end
			parent, pos = node.parent or parent, next_pos
		elseif tag then
			tag = tag:lower()
			if parent.tag == "option" and (tag == "option" or tag == "optgroup") then
				parent = parent.parent
			end
			local node = { tag = tag, attrs = attributes(attrs), children = {}, rev = 0 }
			append(parent, node)
			pos = next_pos
			if TEXT[tag] then
				local stop, last = lower:find("</" .. tag .. "%s*>", pos)
				local value = html:sub(pos, (stop or #html + 1) - 1)
				append(node, { text = tag == "textarea" and entities(value) or value })
				pos = (last or #html) + 1
			elseif not VOID[tag] then
				parent = node
			end
		elseif markup and markup:match("^!") then
			pos = next_pos
		else
			if start <= #html then
				append(parent, { text = "<" })
			end
			pos = start + 1
		end
	end
	return root
end

function M.text(node)
	if node.text then
		return node.text
	end
	local out = {}
	for i, child in ipairs(node.children) do
		out[i] = M.text(child)
	end
	return table.concat(out)
end

function M.walk(node, visit)
	if not node.tag then
		return nil
	end
	if visit(node) then
		return node
	end
	for _, child in ipairs(node.children) do
		local found = M.walk(child, visit)
		if found then
			return found
		end
	end
end

function M.find(root, id)
	if id and id ~= "" then
		return M.walk(root, function(node)
			return node.attrs.id == id
		end)
	end
end

function M.ancestor(node, predicate)
	while node do
		if predicate(node) then
			return node
		end
		node = node.parent
	end
end

function M.id(node)
	local id = node and node.attrs.id
	if id and id ~= "" then
		return (id:gsub("[^ -~]", function(c)
			return c:byte() >= 128 and c:byte() < 192 and "" or "_"
		end))
	end
end

function M.target(node)
	return M.id(M.ancestor(node, function(n)
		return n.attrs.id and n.attrs.id ~= ""
	end))
end

function M.on(node, name)
	return (" " .. (node.attrs["data-on"] or "") .. " "):match("%s" .. name .. "%s") ~= nil
end

function M.reader(node)
	if not node then
		return "element"
	end
	local tag, attrs = node.tag, node.attrs
	local input = (attrs.type or ""):lower()
	local editable = attrs.contenteditable and attrs.contenteditable:lower()
	if tag == "textarea" or editable == "" or editable == "true" or editable == "plaintext-only" then
		return "multiline"
	elseif tag == "select" then
		return "select"
	elseif tag == "button" or tag == "summary" or (tag == "a" and attrs.href) then
		return "button"
	elseif tag == "input" then
		if input == "date" or input == "time" or input == "datetime-local" or input == "month" or input == "week" then
			return "date"
		elseif
			input == "button"
			or input == "submit"
			or input == "reset"
			or input == "checkbox"
			or input == "radio"
		then
			return "button"
		elseif input ~= "hidden" and input ~= "range" and input ~= "color" and input ~= "file" and input ~= "image" then
			return "input"
		end
	end
	return "element"
end

function M.focusable(node)
	if not node then
		return false
	end
	local tag, attrs = node.tag, node.attrs
	if tag == "input" and (attrs.type or ""):lower() == "hidden" then
		return false
	end
	local control = tag == "input" or tag == "button" or tag == "select" or tag == "textarea"
	if control and attrs.disabled then
		return false
	end
	local child = node
	while child do
		if child.attrs.hidden or child.attrs.inert then
			return false
		end
		local parent = child.parent
		if control and parent and parent.tag == "fieldset" and parent.attrs.disabled then
			local legend
			for _, sibling in ipairs(parent.children) do
				if sibling.tag == "legend" then
					legend = sibling
					break
				end
			end
			if child ~= legend then
				return false
			end
		end
		child = parent
	end
	return control or M.reader(node) ~= "element" or tonumber(attrs.tabindex) ~= nil
end

function M.field(node)
	local reader = M.reader(node)
	if reader ~= "input" and reader ~= "multiline" then
		return nil
	end
	if not node.field then
		local value = node.tag == "input" and (node.attrs.value or "") or M.text(node)
		node.field = hotty.field({
			value = reader == "multiline" and value:gsub("\r\n", "\n"):gsub("\r", "\n") or value:gsub("[\r\n]", ""),
			multiline = reader == "multiline",
			password = node.attrs.type == "password",
			rows = tonumber(node.attrs.rows),
		})
	end
	return node.field
end

local function splice(parent, at, remove, children)
	if remove then
		table.remove(parent.children, at).parent = nil
	end
	for i, child in ipairs(children) do
		child.parent = parent
		table.insert(parent.children, at + i - 1, child)
	end
end

local function replace_children(node, children)
	for _, child in ipairs(node.children) do
		child.parent = nil
	end
	node.children = {}
	splice(node, 1, false, children)
end

local function update_attrs(node, attrs)
	local value = node.attrs.value
	node.attrs = attrs
	if node.field and node.tag == "input" and attrs.value ~= value then
		node.field = nil
	end
end

local morph
local function morph_children(node, children, focused)
	local old = node.children
	local used, keyed = {}, {}
	for _, child in ipairs(old) do
		local id = child.attrs and child.attrs.id
		if id then
			keyed[id] = child
		end
	end
	local result = {}
	for i, child in ipairs(children) do
		local id = child.attrs and child.attrs.id
		local prior = id and keyed[id] or old[i]
		if prior and not used[prior] and child.tag and child.tag == prior.tag and id == prior.attrs.id then
			used[prior] = true
			morph(prior, child, focused)
			result[i] = prior
		else
			result[i] = child
		end
	end
	replace_children(node, result)
end

morph = function(node, other, focused)
	if node == focused then
		node.attrs = other.attrs
	else
		update_attrs(node, other.attrs)
		if node.tag == "textarea" and M.text(node) ~= M.text(other) then
			node.field = nil
		end
	end
	morph_children(node, other.children, focused)
end

function M.apply(root, node, op, focused)
	local kind = op.op
	if kind == "attr" or kind == "unattr" then
		local attrs = vim.tbl_extend("force", {}, node.attrs)
		attrs[op.key] = op.value
		if node == focused then
			node.attrs = attrs
		else
			update_attrs(node, attrs)
		end
	elseif kind == "text" then
		replace_children(node, { { text = op.value } })
		if node.tag == "textarea" and node ~= focused then
			node.field = nil
		end
	elseif kind == "var" then
		node.vars = node.vars or {}
		node.vars[op.key] = op.value
	elseif kind == "morph" and node == root then
		local missing = {}
		for _, child in ipairs(M.parse(op.value or "").children) do
			local id = child.attrs and child.attrs.id
			if id then
				local prior = M.find(root, id)
				if prior and prior.tag == child.tag then
					morph(prior, child, focused)
				elseif not prior then
					missing[#missing + 1] = id
				end
			end
		end
		if #missing > 0 then
			return table.concat(missing, ",")
		end
	elseif kind ~= "scroll" and kind ~= "reveal" then
		local children = kind ~= "remove" and op.value and M.parse(op.value).children or {}
		if kind == "morph" then
			local other = children[1]
			if #children == 1 and other.tag == node.tag then
				morph(node, other, focused)
			elseif node.parent then
				for i, sibling in ipairs(node.parent.children) do
					if sibling == node then
						splice(node.parent, i, true, children)
						break
					end
				end
			end
		elseif kind == "inner" then
			morph_children(node, children, focused)
		elseif kind == "append" or kind == "prepend" then
			local fresh, keyed = {}, {}
			for _, child in ipairs(node.children) do
				local id = child.attrs and child.attrs.id
				if id then
					keyed[id] = child
				end
			end
			for _, child in ipairs(children) do
				local prior = child.attrs and keyed[child.attrs.id]
				if prior and prior.tag == child.tag then
					morph(prior, child, focused)
				else
					fresh[#fresh + 1] = child
				end
			end
			splice(node, kind == "prepend" and 1 or #node.children + 1, false, fresh)
		elseif node ~= root then
			local parent = node.parent
			for i, child in ipairs(parent.children) do
				if child == node then
					splice(parent, kind == "after" and i + 1 or i, kind == "replace" or kind == "remove", children)
					break
				end
			end
		end
	end
end

return M
