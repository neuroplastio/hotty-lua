--- A text field's value, caret and selection, edited by SPEC §10.2's
--- actions, for a program that draws its fields in cells (SDK.md §4.6).
--- hotty.field makes one:
---
---   local f = hotty.field({ value = "foo bar", multiline = false })
---   f:do_action("delete-word-backward") --> true; f.value == "foo "
---   f:extend("word-backward") --> false; f:selection() == 0, 4
---
--- SDK.md's Do is a keyword in Lua: the method is do_action, and f["do"] is
--- the same. The caret counts characters, which here are code points, CR LF
--- one (hotty.keys): Lua has no grapheme segmentation. The selection runs
--- from f.anchor, the end where it began, to the caret; nothing is selected
--- when the anchor is nil or at the caret.
local keys = require("hotty.keys")

local join = require("hotty.join")
local chars = keys.chars

local M = {}

local Field = {}
Field.__index = Field

--- A field. opts: value (""), caret (the end), anchor (nil: nothing
--- selected), multiline, password, rows (the rows it shows, for page-up and
--- page-down; 1).
function M.new(opts)
	opts = opts or {}
	local value = opts.value or ""
	return setmetatable({
		value = value,
		caret = opts.caret or #chars(value),
		anchor = opts.anchor,
		multiline = opts.multiline and true or false,
		password = opts.password and true or false,
		rows = opts.rows or 1,
		goal = nil, -- the place along the row a run of row moves keeps
	}, Field)
end

-- U+0009 to U+000D, and the other code points with White_Space.
local WHITE_SPACE = {
	[" "] = true,
	["\t"] = true,
	["\n"] = true,
	["\v"] = true,
	["\f"] = true,
	["\r"] = true,
	["\r\n"] = true,
	["\194\133"] = true, -- U+0085
	["\194\160"] = true, -- U+00A0
	["\225\154\128"] = true, -- U+1680
	["\226\128\168"] = true, -- U+2028
	["\226\128\169"] = true, -- U+2029
	["\226\128\175"] = true, -- U+202F
	["\226\129\159"] = true, -- U+205F
	["\227\128\128"] = true, -- U+3000
}
for cp = 0x2000, 0x200A do
	WHITE_SPACE["\226\128" .. string.char(0x80 + cp - 0x2000)] = true
end

local function space(c)
	return WHITE_SPACE[c] == true
end

local function line_break(c)
	return c == "\n" or c == "\r" or c == "\r\n"
end

-- The start and end of each line, as caret positions.
local function lines_of(self, c)
	local out, start = {}, 0
	for i, ch in ipairs(c) do
		if self.multiline and line_break(ch) then
			out[#out + 1] = { start, i - 1 }
			start = i
		end
	end
	out[#out + 1] = { start, #c }
	return out
end

-- The line the caret p is on: its index, start and end.
local function line_of(lines, p)
	for i, l in ipairs(lines) do
		if l[1] <= p and p <= l[2] then
			return i, l[1], l[2]
		end
	end
	local l = lines[#lines]
	return #lines, l[1], l[2]
end

-- Where word-backward and word-forward take the caret p. The character
-- before caret p is c[p], the one after it c[p + 1].
local function word_back(self, c, p)
	if self.password then
		return 0
	end
	while p > 0 and space(c[p]) do
		p = p - 1
	end
	while p > 0 and not space(c[p]) do
		p = p - 1
	end
	return p
end

local function word_forward(self, c, p)
	if self.password then
		return #c
	end
	while p < #c and space(c[p + 1]) do
		p = p + 1
	end
	while p < #c and not space(c[p + 1]) do
		p = p + 1
	end
	return p
end

-- Where a run of row moves by `by` rows takes the caret.
local function row_move(self, c, p, by)
	local lines = lines_of(self, c)
	local r, s = line_of(lines, p)
	if self.goal == nil then
		self.goal = p - s
	end
	local t = r + by
	if t < 1 then
		return 0
	elseif t > #lines then
		return #c
	end
	local ts, te = lines[t][1], lines[t][2]
	return ts + math.min(self.goal, te - ts)
end

-- The text of the characters c[from] to c[to].
local function text(c, from, to)
	local t, k = {}, 0
	for i = from, to do
		k = k + 1
		t[k] = c[i]
	end
	return join(t, k)
end

-- Deletes the characters between carets a and b; returns whether any were.
local function delete(self, c, a, b)
	if a >= b then
		return false
	end
	self.value = text(c, 1, a) .. text(c, b + 1, #c)
	self.caret = a
	return true
end

-- The selection's start and end in a value of n characters, equal when
-- nothing is selected.
local function selection(self, n)
	local p = math.min(math.max(self.caret, 0), n)
	local a = self.anchor == nil and p or math.min(math.max(self.anchor, 0), n)
	return math.min(a, p), math.max(a, p)
end

--- The selection's start and end, equal when nothing is selected, for the
--- rendition to draw.
function Field:selection()
	return selection(self, #chars(self.value))
end

--- Selects from anchor to caret, for a selection the user makes with the
--- pointer; select(p, p) puts the caret at p with nothing selected. A run
--- of row moves ends.
function Field:select(anchor, caret)
	self.caret = caret
	self.anchor = anchor ~= caret and anchor or nil
	self.goal = nil
end

local ROWS = { ["line-previous"] = true, ["line-next"] = true, ["page-up"] = true, ["page-down"] = true }
-- The moves that go back or up, which start from a selection's start.
local BACK = {
	["char-backward"] = true,
	["word-backward"] = true,
	["line-start"] = true,
	["line-previous"] = true,
	["page-up"] = true,
	["input-start"] = true,
}
local DELETES = {
	["delete-char-backward"] = true,
	["delete-char-forward"] = true,
	["delete-word-backward"] = true,
	["delete-word-forward"] = true,
	["delete-to-line-start"] = true,
	["delete-to-line-end"] = true,
}

-- Does an action, extending the selection when extend; returns whether the
-- value changed.
local function act(self, action, extend)
	local c = chars(self.value)
	local p = math.min(math.max(self.caret, 0), #c)
	if not ROWS[action] then
		self.goal = nil
	end
	if keys.MULTILINE_ACTIONS[action] and not self.multiline then
		return false
	end
	local lo, hi = selection(self, #c)
	if action == "select-all" then
		self.anchor, self.caret = 0, #c
		return false
	elseif action == "newline" then
		return self:type("\n")
	end
	if extend then
		if self.anchor == nil then
			self.anchor = p
		end
	elseif lo < hi and keys.MOVES[action] then
		self.anchor = nil
		p = BACK[action] and lo or hi
		if action == "char-backward" or action == "char-forward" then
			self.caret = p
			return false
		end
	elseif lo < hi and DELETES[action] then
		self.anchor = nil
		return delete(self, c, lo, hi)
	elseif lo == hi then
		self.anchor = nil
	end
	local _, s, e = line_of(lines_of(self, c), p)
	local page = math.max(self.rows or 1, 1)
	local to
	if action == "char-backward" then
		to = math.max(p - 1, 0)
	elseif action == "char-forward" then
		to = math.min(p + 1, #c)
	elseif action == "word-backward" then
		to = word_back(self, c, p)
	elseif action == "word-forward" then
		to = word_forward(self, c, p)
	elseif action == "line-start" then
		to = s
	elseif action == "line-end" then
		to = e
	elseif action == "line-previous" then
		to = row_move(self, c, p, -1)
	elseif action == "line-next" then
		to = row_move(self, c, p, 1)
	elseif action == "page-up" then
		to = row_move(self, c, p, -page)
	elseif action == "page-down" then
		to = row_move(self, c, p, page)
	elseif action == "input-start" then
		to = 0
	elseif action == "input-end" then
		to = #c
	end
	if to then
		self.caret = to
		if self.anchor == to then
			self.anchor = nil
		end
		return false
	end
	self.caret = p
	if action == "delete-char-backward" then
		return delete(self, c, math.max(p - 1, 0), p)
	elseif action == "delete-char-forward" then
		return delete(self, c, p, math.min(p + 1, #c))
	elseif action == "delete-word-backward" then
		return delete(self, c, word_back(self, c, p), p)
	elseif action == "delete-word-forward" then
		return delete(self, c, p, word_forward(self, c, p))
	elseif action == "delete-to-line-start" then
		return delete(self, c, s, p)
	elseif action == "delete-to-line-end" then
		return delete(self, c, p, e)
	end
	return false
end

--- Does an action (SPEC §10.2); returns whether the value changed. A
--- selection comes first: a delete deletes it and nothing else, a move
--- starts from its start going back or up and from its end otherwise, and
--- ends it (char-backward and char-forward stop there), and select-all
--- selects the whole value. submit and program are the program's, and
--- change nothing.
function Field:do_action(action)
	return act(self, action, false)
end
Field["do"] = Field.do_action

--- Does a move as Shift does it (SPEC §10.2, Shift selects): the anchor
--- stays, or is set where the caret is, and the caret moves from where it
--- is. An action that is not a move is do_action's.
function Field:extend(action)
	return act(self, action, keys.MOVES[action] == true)
end

--- Types text in place of the selection, or at the caret; returns whether
--- the value changed.
function Field:type(s)
	self.goal = nil
	if not s or s == "" then
		return false
	end
	local c = chars(self.value)
	local lo, hi = selection(self, #c)
	self.anchor = nil
	local before = text(c, 1, lo) .. s
	self.value = before .. text(c, hi + 1, #c)
	self.caret = #chars(before)
	return true
end

return M
