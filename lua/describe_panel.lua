-- The describe panel: one focused window over the permission prompt, for the
-- bash call the native prompt is showing. Layout and keys live in
-- describe_view; this owns the window, the shfmt job and the answers.
--
-- Focus is the point. While a permission prompt is open it takes every key
-- except those for a focused plugin window, so the panel has to hold focus to
-- hear `v`. Handing off closes it, which gives the keys back to the prompt.

local View = require("describe_view")

local M = {}
M.__index = M

-- Above plugin floats at the default zindex of 50.
local ZINDEX = 60
local SHFMT_TIMEOUT_MS = 1000
local SHFMT_TAIL = 1024
-- The command travels in the environment: jobstart has no stdin, and this way
-- nothing is written to disk or quoted for a shell.
local SHFMT = { "sh", "-c", 'printf %s "$DESCRIBE_CMD" | shfmt -i 2 -ci -bn' }

local function display_width(s)
  return maki.ui.display_width(s)
end

function M.new(prompts, can_answer)
  return setmetatable({
    prompts = prompts,
    can_answer = can_answer,
    win = nil,
    buf = nil,
    item = nil,
    state = nil,
    content = nil,
    -- Bumped on every build, so a build that finishes after a newer one
    -- started is thrown away.
    gen = 0,
  }, M)
end

-- Highlighting yields, so this runs in a task.
local function build(item)
  local inner = math.max(20, maki.ui.terminal_size().cols - View.CHROME)
  local code = View.sanitize(item.formatted or item.call.command)
  local content = View.content(item.call, code, inner, display_width)
  content.formatted = item.formatted ~= nil
  local texts = {}
  for i, row in ipairs(content.rows) do
    texts[i] = row.text
  end
  local ok, styled = pcall(maki.ui.highlight, table.concat(texts, "\n"), "bash")
  if ok and type(styled) == "table" and #styled == #content.rows then
    content.styled = styled
  end
  return content
end

function M:draw()
  local rows = maki.ui.terminal_size().rows
  local lines, config
  if self.state.mode == "full" then
    self.state.top = View.clamp_top(self.state.top, self.content, rows)
    lines = View.full(self.content, rows, self.state.top)
    config = { title = View.full_title(self.content, self.state.top, rows), height = "100%" }
  else
    local meta = self.item.meta or {}
    local reserve = View.native_rows(meta.scopes, meta.reason)
    lines = View.compact(self.content, math.max(View.MIN_HEIGHT, rows - reserve))
    config = {
      title = View.compact_title(self.content),
      height = View.compact_height(#lines, rows, reserve),
    }
  end
  config.footer = View.footer(self.state)
  self.buf:set_lines(lines)
  self.win:set_config(config)
end

-- A win is followed by PermissionResolved, which moves the panel on. A loss
-- means someone else answered first, and their PermissionResolved is already
-- on its way. Neither needs anything here.
function M:answer(item, decision)
  local ok, won, err =
    pcall(maki.session.answer_permission, item.request_id, { decision = decision })
  if ok and won ~= nil then
    return
  end
  maki.log.warn("describe: could not answer the prompt: " .. tostring(ok and err or won))
  self.can_answer = false
  if self.item == item then
    self.state.can_answer = false
    self:draw()
  end
end

function M:key(key)
  local rows = maki.ui.terminal_size().rows
  local action = View.handle_key(self.state, key, self.content, rows)
  if action == "redraw" then
    self:draw()
  elseif action == "hand_off" then
    self.prompts:hand_off(self.item.request_id)
    self:sync()
  elseif action == "allow" or action == "deny" then
    self:answer(self.item, action)
  end
end

-- A broken panel must give the keys back: a focused window takes every key
-- whether or not anything reads them. So the call is handed off and the window
-- closed, and the native prompt carries on alone.
function M:fail(err)
  maki.log.warn("describe: panel: " .. tostring(err))
  if self.item then
    self.prompts:hand_off(self.item.request_id)
  end
  self:close()
end

function M:loop(win)
  while true do
    local ev = win:recv()
    if not ev or ev.type == "close" then
      if win == self.win then
        self.win, self.buf, self.item, self.content = nil, nil, nil, nil
      end
      return
    end
    -- Only the live window acts; one closed under a newer one just drains.
    if win == self.win and self.item then
      local ok, err = pcall(function()
        if ev.type == "key" then
          self:key(ev.key)
        elseif ev.type == "resize" then
          self:show(self.item)
        end
      end)
      if not ok then
        self:fail(err)
        return
      end
    end
  end
end

function M:open()
  self.buf = maki.ui.buf({ scratch = true })
  self.win = maki.ui.open_win(self.buf, {
    anchor = "NW",
    row = 0,
    col = 0,
    width = "100%",
    height = View.MIN_HEIGHT,
    border = "rounded",
    focus = true,
    zindex = ZINDEX,
  })
  local win = self.win
  maki.async.spawn(function()
    self:loop(win)
  end)
end

function M:close()
  local win = self.win
  self.win, self.buf, self.item, self.content = nil, nil, nil, nil
  if win then
    win:close()
  end
end

-- Builds and draws {item}. A build for a request the panel has since moved off
-- is thrown away.
function M:show(item)
  self.gen = self.gen + 1
  local gen = self.gen
  maki.async.spawn(function()
    local ok, err = pcall(function()
      local content = build(item)
      if gen ~= self.gen or self.item ~= item then
        return
      end
      self.content = content
      if not self.win then
        self:open()
      end
      self:draw()
    end)
    if ok then
      return
    end
    if gen == self.gen and self.item == item then
      self:fail(err)
    else
      maki.log.warn("describe: stale build: " .. tostring(err))
    end
  end)
end

-- Matches the panel to what the native prompt is showing. Called after every
-- change to the prompts.
function M:sync()
  local item = self.prompts:current()
  if item == self.item then
    return
  end
  if not item then
    self:close()
    return
  end
  self.item = item
  self.content = nil
  self.state = { mode = "compact", top = 1, can_answer = self.can_answer }
  self:show(item)
end

-- Redraws with the formatted script once shfmt is done, keeping the view and
-- scroll position the user is on.
function M:refresh(request_id)
  if self.item and self.item.request_id == request_id then
    self:show(self.item)
  end
end

function M:format(request_id, command)
  maki.async.spawn(function()
    local ok, err = pcall(self.run_shfmt, self, request_id, command)
    if not ok then
      maki.log.warn("describe: shfmt: " .. tostring(err))
    end
  end)
end

function M:run_shfmt(request_id, command)
  local id = maki.fn.jobstart(SHFMT, { env = { DESCRIBE_CMD = command }, tail = SHFMT_TAIL })
  if not id then
    return
  end
  -- Straight after jobstart: a job waited on while it runs hands back every
  -- line, while one that already exited answers only from its tail.
  local res = maki.fn.jobwait(id, SHFMT_TIMEOUT_MS)
  if not res then
    pcall(maki.fn.jobstop, id)
    return
  end
  if res.exit_code ~= 0 or res.truncated or (res.stdout or "") == "" then
    return
  end
  if self.prompts:set_formatted(request_id, res.stdout) then
    self:refresh(request_id)
  end
end

return M
