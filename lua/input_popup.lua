-- A completion popup for the chat input, driven by a trigger character.
--
-- Factored out of the `#` PR completer so anything else wanting "type a
-- character, pick from a list, insert a string" gets the fiddly parts for
-- free: a float that sits on the input caret and takes only the keys it
-- claims, a list that narrows in Lua rather than re-asking its source on
-- every keystroke, and teardown that hands every key back on every exit path.
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
-- Built the way maki's bundled `@` completion is: the popup is an unfocused
-- float anchored at `input_caret`, so the host places it beside the caret
-- every frame and the user keeps typing into the input beneath it. The keys
-- it takes are declared on the window and die with it, which is what makes
-- the teardown safe: closing the float is what hands `<CR>` back.
--
-- Requires maki.ui.input_edit; callers feature-detect before requiring this.

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
-- Two spellings per key: the notation the window claims it in, and the name
-- `win:recv` reports the press under. `<S-Tab>` cannot join: it parses to Tab
-- with Shift while terminals deliver BackTab, so a claim on it never fires.
local BINDINGS = {
  { claim = "<Tab>", event = "tab", run = "next" },
  { claim = "<C-n>", event = "ctrl+n", run = "next" },
  { claim = "<C-p>", event = "ctrl+p", run = "prev" },
  { claim = "<CR>", event = "enter", run = "accept" },
  { claim = "<Esc>", event = "esc", run = "close" },
}
local KEYS, HANDLERS = {}, {}
for i, b in ipairs(BINDINGS) do
  KEYS[i] = b.claim
  HANDLERS[b.event] = b.run
end

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

-- The only teardown. Closing the window is what releases its key claims, so
-- nothing here can fail with `<CR>` still taken.
function Popup:close()
  local win = self.win
  self.win, self.buf, self.items, self.placeholder, self.st, self.start =
    nil, nil, {}, nil, nil, nil
  -- Bumped so a round trip that comes back after the popup it was for has
  -- gone cannot repaint the one that replaced it.
  self.generation = self.generation + 1
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
    return
  end
  local n = #self.items
  if n > 0 then
    self.sel = (self.sel - 1 + delta) % n + 1
    self.buf:set_lines(self:lines())
  end
end

-- Insert the highlighted row over the mention it was ranked for. The range,
-- version and session all came with the snapshot the refresh drew from;
-- `maki.ui.input_edit` weighs that snapshot itself and refuses an edit the
-- input has moved past. The popup closes first, which hands the keys back
-- before the edit fires the `InputChanged` this plugin listens to.
function Popup:accept()
  local choice = self.win and self.items[self.sel]
  local st, start = self.st, self.start
  -- Nothing to insert, which is the placeholder popup. The press is already
  -- claimed and cannot be handed back, so the most it can do is get the popup
  -- out of the way for the next one.
  if not choice or not st or not start then
    return self:close()
  end
  self:close()
  local ok, text = pcall(self.insert, choice)
  if not ok or type(text) ~= "string" then
    return
  end
  local done, err = maki.ui.input_edit({
    start = start,
    stop = st.cursor,
    text = text,
    version = st.version,
    session_id = st.session_id,
  })
  if not done then
    maki.ui.flash(self.name .. ": not inserted: " .. tostring(err))
  end
end

-- The popup's key loop, one per window. It ends with the window: `close`
-- takes the float down and the host answers with a `close` event. A key
-- queued before a close can land after a newer popup has opened, so {win}
-- has to still be the one on screen.
function Popup:read_keys(win)
  maki.async.run(function()
    while true do
      local ev = win:recv()
      if not ev or ev.type == "close" then
        return
      end
      if ev.type == "key" and self.win == win then
        local run = HANDLERS[ev.key]
        if run then
          self[run](self)
        end
      end
    end
  end)
end

-- Opened hidden, so the first frame never paints an empty popup before the
-- rows it is for have been read.
function Popup:ensure()
  if self.win then
    return
  end
  local buf = maki.ui.buf()
  self.win = maki.ui.open_win(buf, {
    width = MIN_WIDTH,
    height = BORDER + 1,
    anchor = "input_caret",
    border = "rounded",
    footer = FOOTER,
    zindex = ZINDEX,
    focus = false,
    visible = false,
    keys = KEYS,
  })
  self.buf, self.sel, self.items = buf, 1, {}
  self:read_keys(self.win)
end

-- Only the size. The caret anchor decides where the popup goes and the host
-- redoes that every frame, so it follows the caret through wraps and resizes.
function Popup:render()
  local shown = self:rows()
  local width = MIN_WIDTH
  for _, item in ipairs(shown) do
    width = math.max(width, row_width(item) + PAD + BORDER)
  end
  local size = maki.ui.terminal_size()
  self.buf:set_lines(self:lines())
  self.win:set_config({ width = math.min(width, size.cols), height = #shown + BORDER })
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
-- is in it. {st} is the chat input as the host last reported it: the
-- `InputChanged` payload carries text, cursor, version and session, every
-- field `maki.ui.input` would answer with and one round trip less.
function Popup:refresh(st)
  local token = self.generation
  self.latest = self.latest + 1
  local mine = self.latest
  -- True once this refresh has been overtaken, by a newer keystroke or by a
  -- close. Two refreshes in flight would otherwise race to paint and the loser
  -- would leave the previous query's items on screen.
  local function stale()
    return self.generation ~= token or self.latest ~= mine
  end

  local start, query = find(st.text, st.cursor, self.pattern)
  -- A slash command owns the input while the command palette is up, and its
  -- own Tab and Enter with it.
  if not start or st.text:sub(1, 1) == "/" then
    return self:close()
  end

  -- A cold source can be a network round trip, so the popup goes up saying so
  -- rather than leaving the input box looking dead until the answer lands. A
  -- warm one keeps the list that is already up instead of flashing this.
  if not self.win and self.pending then
    self:ensure()
    self.st, self.start = st, start
    self.placeholder = self.pending
    self:render()
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
  local items = self:narrow(supplied, query, self.max_items)

  self:ensure()
  -- The snapshot the rows answer, and the range an accept writes over.
  self.st, self.start = st, start
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
  self:render()
end

-- Registers the trigger and returns the popup, whose only useful method from
-- the outside is `close`.
--
-- opts:
--   trigger    (string)   the character that opens it.
--   name       (string)   used in messages.
--   items      (function) -> list of { label, insert?, detail? } or nil.
--   insert     (function) item -> the text to write over the mention.
--   match      (function) item, query -> boolean. Default: substring of label.
--   max_items  (integer)  rows at once.
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
    st = nil,
    start = nil,
    generation = 0,
    latest = 0,
  }, Popup)

  -- Triggering on the text rather than on a key is what lets the list narrow
  -- while the user keeps typing, which no keybinding could do without claiming
  -- every printable character.
  maki.api.create_autocmd("InputChanged", {
    callback = function(ev)
      local data = ev.data
      -- An accept is itself an input_edit, and so an InputChanged naming the
      -- plugin that wrote it. Acting on it would reopen the popup on the text
      -- just inserted.
      if data.source then
        return
      end
      -- A caret the user moved can take the popup away but never put one up:
      -- arrowing back over a trigger dismissed with Esc would otherwise reopen
      -- it.
      if data.cursor_only and not popup.win then
        return
      end
      -- Focusing another tab fires this for the input that tab holds, which
      -- is another line of text entirely.
      if popup.win and popup.st and popup.st.session_id ~= data.session_id then
        popup:close()
      end
      if not popup.win and not find(data.text, data.cursor, popup.pattern) then
        return
      end
      -- Autocmd dispatch waits on its handlers, so the round trips run off to
      -- the side rather than holding every other plugin's events behind them.
      maki.async.run(function()
        popup:refresh(data)
      end)
    end,
  })

  maki.api.create_autocmd({ "SessionFocusChanged", "SessionReset", "TaskFocusChanged" }, {
    callback = function()
      popup:close()
    end,
  })

  -- A permission prompt, the plan form or a pack review takes the chat input
  -- off screen, and the host then refuses to edit it. Leaving the popup up
  -- would leave it holding keys for an accept that cannot land.
  maki.api.create_autocmd("SessionStatusChanged", {
    callback = function(ev)
      if ev.data.focused and ev.data.status == "needs_input" then
        popup:close()
      end
    end,
  })

  return popup
end

return M
