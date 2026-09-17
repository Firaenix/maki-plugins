-- A completion popup for the chat input, driven by a trigger character.
--
-- Factored out of the `#` PR completer so anything else wanting "type a
-- character, pick from a list, insert a string" gets the fiddly parts for
-- free: placement against a caret that may not exist, keys that come back off
-- on every exit path, and a list that narrows in Lua rather than re-asking its
-- source on every keystroke.
--
--   local popup = require("input_popup").attach({
--     trigger = "#",
--     name = "forge-prs",
--     items = function()
--       return { { label = "#1 a title", insert = "https://...", detail = "author" } }
--     end,
--     insert = function(item)
--       return item.insert .. " "
--     end,
--   })
--
-- `items` is deliberately called with no query. Filtering happens in here, so
-- a source that costs a network round trip caches its own answer once and the
-- popup can never turn a keystroke into a request. Returning nil closes.
--
-- Requires maki.ui.input; callers feature-detect before requiring this.

local M = {}

-- Cells the border costs, at both ends and on both sides.
local BORDER = 2
-- One blank cell either side of a row, so text never touches the border.
local PAD = 2
local MIN_WIDTH = 24
-- Above the input box and the transcript, below anything modal.
local ZINDEX = 120
local DEFAULT_MAX_ITEMS = 10
local GAP = "  "
local FOOTER = { { "Tab", "next" }, { "Enter", "insert" }, { "Esc", "close" } }
-- Only unshifted keys. A shifted character arrives with SHIFT set and the
-- override table compares modifiers exactly, which is not something a plugin
-- should have to know per terminal.
local KEYS = {
  { "<Tab>", "next" },
  { "<C-n>", "next" },
  { "<C-p>", "prev" },
  { "<CR>", "accept" },
  { "<Esc>", "close" },
}

local Popup = {}
Popup.__index = Popup

-- Byte offset of the trigger the cursor is typing into, plus the query typed
-- after it, or nil. Bytes throughout: that is the unit maki.ui.input and
-- maki.ui.input_edit speak, and the one string.sub speaks, so the offsets a
-- match reports are the offsets an edit writes over.
local function find(text, cursor, pattern)
  local before = text:sub(1, cursor)
  local at = before:match("^.*()" .. pattern)
  -- A trigger only opens a mention at a word boundary, so `sha1#2` never
  -- does. One byte of lookbehind is enough for text of any encoding: every
  -- whitespace byte is ASCII and no byte of a multi-byte character is.
  if not at or not (at == 1 or before:sub(at - 1, at - 1):match("^%s")) then
    return nil
  end
  local query = before:sub(at + 1)
  -- A space ends the mention. Without this, every later keystroke on the line
  -- would still count as typing into a trigger the user moved past long ago.
  if query:match("%s") then
    return nil
  end
  return at - 1, query
end

local function default_match(item, query)
  return item.label:lower():find(query:lower(), 1, true) ~= nil
end

local function row_width(item)
  local w = maki.ui.display_width(item.label)
  if item.detail then
    w = w + maki.ui.display_width(item.detail) + #GAP
  end
  return w
end

-- Rows of content that fit on the roomier side of {caret}. Whichever side has
-- more space wins rather than trying above first: a caret near the top of the
-- screen has the whole transcript below it and two rows above. Getting this
-- wrong is silent, because the host clamps a float that runs off the screen
-- down to whatever is left instead of refusing it.
local function room(caret, size)
  local above = caret.row
  local below = size.rows - caret.row - 1
  return math.max(above, below) - BORDER
end

-- Row, col and total height for a popup showing {rows} rows, or nil when
-- neither side of the caret has room for even one.
local function fit(caret, rows, width, size)
  local avail = room(caret, size)
  if rows < 1 or avail < 1 then
    return nil
  end
  local height = math.min(rows, avail) + BORDER
  local above = caret.row
  local below = size.rows - caret.row - 1
  local row = above >= below and caret.row - height or caret.row + 1
  local col = math.max(0, math.min(caret.col, size.cols - width))
  return row, col, height
end

-- Unbinding is the one thing that must never be skipped: an error with `<CR>`
-- still claimed leaves the user unable to send a message at all. Each key
-- comes off on its own so a failure on one cannot strand the rest.
function Popup:unbind()
  local keys = self.bound
  self.bound = {}
  for _, key in ipairs(keys) do
    pcall(maki.keymap.del, "n", key)
  end
end

-- The only teardown. Keys come off before anything that could fail.
function Popup:close()
  local win = self.win
  self.win, self.buf, self.items, self.placeholder = nil, nil, {}, nil
  -- Bumped so a round trip that comes back after the popup it was for has
  -- gone cannot repaint the one that replaced it.
  self.generation = self.generation + 1
  self:unbind()
  if win then
    pcall(function()
      win:close()
    end)
  end
end

-- What the popup shows: the filtered items, or the one placeholder row that
-- stands in for them. A placeholder beats closing, so a query matching nothing
-- says so instead of making the popup blink out and back.
function Popup:rows()
  if #self.items == 0 then
    return { { label = self.placeholder or self.empty } }, true
  end
  return self.items, false
end

function Popup:lines()
  local shown, empty = self:rows()
  local out = {}
  for i, item in ipairs(shown) do
    local style = empty and "dim" or (i == self.sel and "selected" or "item")
    local spans = { { " " .. item.label, style } }
    if item.detail then
      spans[#spans + 1] = { GAP .. item.detail, "dim" }
    end
    out[i] = spans
  end
  return out
end

function Popup:move(delta)
  if not self.win then
    -- A binding outlived its popup. Take the keys off so the next press
    -- reaches the input box and swallow this one: the host counts a key as
    -- claimed the moment the callback is dispatched.
    return self:unbind()
  end
  local n = #self.items
  if n > 0 then
    self.sel = (self.sel - 1 + delta) % n + 1
    self.buf:set_lines(self:lines())
  end
end

-- Re-reads the input instead of trusting what was on screen when the popup was
-- drawn: the handler runs a frame or more after the key, and the edit has to
-- land on the mention that is there now.
function Popup:accept()
  local choice = self.win and self.items[self.sel]
  -- Nothing to insert, which is the placeholder popup. The press is already
  -- claimed and cannot be handed back, so the most it can do is get the popup
  -- out of the way for the next one.
  if not choice then
    return self:close()
  end
  local st = maki.ui.input()
  local start = st and find(st.text, st.cursor, self.pattern)
  if not start then
    return self:close()
  end
  local ok, text = pcall(self.insert, choice)
  if not ok or type(text) ~= "string" then
    return self:close()
  end
  -- The version refuses the edit outright if the user typed while this handler
  -- was running, rather than writing over a range that has since moved.
  local _, err = maki.ui.input_edit({
    start = start,
    stop = st.cursor,
    text = text,
    version = st.version,
  })
  if err then
    maki.ui.flash(err)
  end
  self:close()
end

-- These replace whatever the user already had on the same key, and putting one
-- back is not something the keymap API can do, so the keys are only ever
-- claimed for as long as the popup is on screen.
function Popup:bind()
  local handlers = {
    next = function()
      self:move(1)
    end,
    prev = function()
      self:move(-1)
    end,
    accept = function()
      self:accept()
    end,
    close = function()
      self:close()
    end,
  }
  for _, entry in ipairs(KEYS) do
    local opts = { desc = self.name .. ": " .. entry[2] }
    local ok = pcall(maki.keymap.set, "n", entry[1], handlers[entry[2]], opts)
    -- Only a key we actually claimed goes on the list: maki.keymap.del is
    -- given a key rather than a binding, so deleting one we never took could
    -- take another plugin's with it.
    if ok then
      self.bound[#self.bound + 1] = entry[1]
    end
  end
end

-- Opened hidden, so the first frame never paints it at the placeholder
-- position it was created with.
function Popup:ensure()
  if self.win then
    return
  end
  local buf = maki.ui.buf()
  self.win = maki.ui.open_win(buf, {
    width = MIN_WIDTH,
    height = BORDER + 1,
    row = 0,
    col = 0,
    anchor = "NW",
    border = "rounded",
    footer = FOOTER,
    zindex = ZINDEX,
    focus = false,
    visible = false,
  })
  self.buf, self.sel, self.items = buf, 1, {}
  self:bind()
end

function Popup:render(caret, size)
  local shown = self:rows()
  local width = MIN_WIDTH
  for _, item in ipairs(shown) do
    width = math.max(width, row_width(item) + PAD + BORDER)
  end
  width = math.min(width, size.cols)
  local row, col, height = fit(caret, #shown, width, size)
  -- Nowhere on screen to put it. Closing beats handing the host a rect it has
  -- to clamp into a sliver.
  if not row then
    return self:close()
  end
  self.buf:set_lines(self:lines())
  self.win:set_config({ width = width, height = height, row = row, col = col })
  self.win:show()
end

function Popup:narrow(supplied, query, limit)
  local out = {}
  for _, item in ipairs(supplied) do
    if query == "" or self.match(item, query) then
      out[#out + 1] = item
      if #out >= limit then
        break
      end
    end
  end
  return out
end

-- The one place that decides whether there should be a popup at all and what
-- is in it. Everything it needs it reads for itself, because between the
-- keystroke that woke it and here the user may have typed on.
function Popup:refresh()
  local token = self.generation
  self.latest = self.latest + 1
  local mine = self.latest
  -- True once this refresh has been overtaken, by a newer keystroke or by a
  -- close. Two refreshes in flight would otherwise race to paint and the loser
  -- would leave the previous query's items on screen.
  local function stale()
    return self.generation ~= token or self.latest ~= mine
  end

  local st = maki.ui.input()
  if stale() then
    return
  end
  -- `caret` is absent whenever the input box is not the thing the terminal
  -- cursor sits in — before the first frame, under a modal, during a form
  -- takeover — and there is nothing to anchor a popup to then.
  if not st or not st.caret then
    return self:close()
  end
  local start, query = find(st.text, st.cursor, self.pattern)
  -- A slash command owns the input while the command palette is up, and its
  -- own Tab and Enter with it.
  if not start or st.text:sub(1, 1) == "/" then
    return self:close()
  end
  local size = maki.ui.terminal_size()
  -- Asking for more rows than the screen has is what leaves the host clamping
  -- the float, so the limit is what fits rather than what was configured.
  local limit = math.min(self.max_items, room(st.caret, size))
  if limit < 1 then
    return self:close()
  end

  -- A cold source can be a network round trip, so the popup goes up saying so
  -- rather than leaving the input box looking dead until the answer lands. A
  -- warm one keeps the list that is already up instead of flashing this.
  if not self.win and self.pending then
    self:ensure()
    self.placeholder = self.pending
    self:render(st.caret, size)
    if stale() then
      return
    end
  end

  -- Called with no query: the source hands over everything it has, cached at
  -- whatever granularity suits it, and the narrowing below runs in Lua on
  -- every keystroke after that.
  local ok, supplied = pcall(self.supply)
  if stale() then
    return
  end
  if not ok or type(supplied) ~= "table" then
    return self:close()
  end
  local items = self:narrow(supplied, query, limit)

  self:ensure()
  self.placeholder = nil
  -- The highlight follows the item it was on while that item is still listed,
  -- so a keystroke that only drops candidates does not move the selection out
  -- from under the user.
  local was = self.items[self.sel]
  self.items, self.sel = items, 1
  for i, item in ipairs(items) do
    if item == was then
      self.sel = i
    end
  end
  self:render(st.caret, size)
end

-- Registers the trigger and returns the popup, whose only useful method from
-- the outside is `close`.
--
-- opts:
--   trigger    (string)   the character that opens it.
--   name       (string)   used in keymap descriptions.
--   items      (function) -> list of { label, insert?, detail? } or nil.
--   insert     (function) item -> the text to write over the mention.
--   match      (function) item, query -> boolean. Default: substring of label.
--   max_items  (integer)  rows at once, further clamped to what fits.
--   empty      (string)   row shown when nothing matched.
--   pending    (string)   row shown while a cold `items` is in flight.
function M.attach(opts)
  local popup = setmetatable({
    -- Escaped once here: `#` is literal in a Lua pattern but `.` or `%` is not.
    pattern = opts.trigger:gsub("%W", "%%%0"),
    name = opts.name or "input_popup",
    supply = opts.items,
    -- The filtered list on screen, which is a different thing from `supply`.
    items = {},
    insert = opts.insert or function(item)
      return item.insert
    end,
    match = opts.match or default_match,
    max_items = opts.max_items or DEFAULT_MAX_ITEMS,
    empty = opts.empty or "no matches",
    pending = opts.pending,
    win = nil,
    buf = nil,
    sel = 1,
    placeholder = nil,
    -- The keys claimed right now, so teardown removes exactly those.
    bound = {},
    generation = 0,
    latest = 0,
  }, Popup)

  -- Triggering on the text rather than on a key is what lets the list narrow
  -- while the user keeps typing, which no keybinding could do without claiming
  -- every printable character.
  maki.api.create_autocmd("InputChanged", {
    callback = function(ev)
      -- An accept is itself an input_edit, and so an InputChanged. Acting on
      -- it would reopen the popup on the text just inserted.
      if ev.data.source == "plugin" then
        return
      end
      if not popup.win and not find(ev.data.text, ev.data.cursor, popup.pattern) then
        return
      end
      -- Autocmd dispatch waits on its handlers, so the round trips run off to
      -- the side rather than holding every other plugin's events behind them.
      maki.async.run(function()
        popup:refresh()
      end)
    end,
  })

  -- The input of another session is another line of text entirely, and the
  -- popup was placed against this one.
  maki.api.create_autocmd({ "SessionFocusChanged", "SessionReset" }, {
    callback = function()
      popup:close()
    end,
  })

  -- A turn starting takes the input box away, and `<Esc>` goes to cancelling
  -- the turn rather than to this plugin, so without this the popup would sit
  -- there with `<CR>` still claimed and no key left that closes it. Closing
  -- twice is harmless: the keys are already off and the window already gone.
  maki.api.create_autocmd("SessionStatusChanged", {
    callback = function()
      popup:close()
    end,
  })

  return popup
end

return M
