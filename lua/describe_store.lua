-- describe's memory between a bash call reaching `tool.bash.input` and the
-- permission prompt it may raise. Pure, with no maki calls, so tests/ runs it
-- under plain luau.
--
-- Calls are kept by tool id, which `PermissionRequested` reports as `tool_id`.
-- Prompts are kept per session in the order the native prompt queues them,
-- including the ones describe has nothing to show for. The panel shows only
-- when the native prompt's front request is one of describe's own, so the two
-- never disagree about which call `y` answers.

local M = {}

M.MAX_CALLS = 64
M.MAX_TEXT_BYTES = 400
local ELLIPSIS = "…"

-- Backs off to a character boundary, so a capped sentence never ends in half
-- a character.
local function cap_bytes(s, max)
  if #s <= max then
    return s
  end
  local cut = max
  while cut > 0 do
    local b = s:byte(cut + 1)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return s:sub(1, cut) .. ELLIPSIS
end

local function clean_text(value)
  if type(value) ~= "string" then
    return nil
  end
  local s = value:gsub("%s+", " "):match("^ ?(.-) ?$")
  if s == "" then
    return nil
  end
  return cap_bytes(s, M.MAX_TEXT_BYTES)
end

local Calls = {}
Calls.__index = Calls

function M.calls(cap)
  return setmetatable({ cap = cap or M.MAX_CALLS, by_id = {}, order = {} }, Calls)
end

-- Nested calls arrive with an empty id and a call with no command has nothing
-- to show, so both are skipped.
function Calls:remember(tool_id, input)
  if type(tool_id) ~= "string" or tool_id == "" or type(input) ~= "table" then
    return
  end
  local command = input.command
  if type(command) ~= "string" or command == "" then
    return
  end
  if self.by_id[tool_id] == nil then
    self.order[#self.order + 1] = tool_id
  end
  self.by_id[tool_id] = {
    command = command,
    sentence = clean_text(input.intent) or clean_text(input.description),
    workdir = type(input.workdir) == "string" and input.workdir or nil,
  }
  while #self.order > self.cap do
    self.by_id[table.remove(self.order, 1)] = nil
  end
end

function Calls:get(tool_id)
  if tool_id == nil then
    return nil
  end
  return self.by_id[tool_id]
end

function Calls:forget(tool_id)
  if tool_id == nil or self.by_id[tool_id] == nil then
    return
  end
  self.by_id[tool_id] = nil
  for i, id in ipairs(self.order) do
    if id == tool_id then
      table.remove(self.order, i)
      return
    end
  end
end

local Prompts = {}
Prompts.__index = Prompts

function M.prompts()
  return setmetatable({ by_session = {}, focused = nil }, Prompts)
end

-- {call} is nil for a prompt describe has nothing to show for. It still takes
-- its place in the queue.
function Prompts:open(session_id, request_id, call)
  if session_id == nil or request_id == nil then
    return
  end
  local queue = self.by_session[session_id]
  if not queue then
    queue = {}
    self.by_session[session_id] = queue
  end
  queue[#queue + 1] = {
    request_id = request_id,
    session_id = session_id,
    call = call,
    handed_off = false,
  }
end

local function find(self, request_id)
  for _, queue in pairs(self.by_session) do
    for i, item in ipairs(queue) do
      if item.request_id == request_id then
        return queue, i, item
      end
    end
  end
  return nil
end

function Prompts:resolve(request_id)
  local queue, i = find(self, request_id)
  if queue then
    table.remove(queue, i)
  end
end

function Prompts:hand_off(request_id)
  local _, _, item = find(self, request_id)
  if item then
    item.handed_off = true
  end
end

-- False for a request no longer open: a formatter that finishes after its
-- prompt closed must not bring the panel back.
function Prompts:set_formatted(request_id, text)
  local _, _, item = find(self, request_id)
  if not item then
    return false
  end
  item.formatted = text
  return true
end

function Prompts:focus(session_id)
  self.focused = session_id
end

-- The front of the focused session's queue, when describe captured that call
-- and the user has not handed it off.
function Prompts:current()
  local queue = self.focused and self.by_session[self.focused]
  local front = queue and queue[1]
  if front and front.call and not front.handed_off then
    return front
  end
  return nil
end

return M
