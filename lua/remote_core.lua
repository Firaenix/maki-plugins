-- remote: builds the hub heartbeat. Pure parts only — identity, git HEAD
-- parsing, and the request body shape — so a spec can run it under plain luau.

local M = {}

-- The hub refuses a heartbeat with more than 128 sessions (400), so the extras
-- are cut here rather than losing the whole beat.
M.MAX_SESSIONS = 128

-- Random per maki process; the hub keys instances by (host token, id), so only
-- uniqueness within one process matters.
function M.instance_id(now, rand)
  return ("%d-%x"):format(now, rand())
end

-- "ref: refs/heads/main" -> "main"; detached HEAD -> short sha; anything else nil.
function M.parse_head(text)
  if type(text) ~= "string" then
    return nil
  end
  local trimmed = text:match("^%s*(.-)%s*$")
  local ref = trimmed:match("^ref:%s*(%S+)$")
  if ref then
    local branch = (ref:gsub("^refs/heads/", ""))
    return branch ~= "" and branch or nil
  end
  if #trimmed == 40 and trimmed:match("^[0-9a-fA-F]+$") then
    return trimmed:sub(1, 7)
  end
  return nil
end

-- One live session merged with its full read, which may be nil when the session
-- closed between live() and read().
function M.snapshot(live, read)
  return {
    id = live.id,
    title = live.title,
    cwd = read and read.cwd or nil,
    model = read and read.model or nil,
    mode = read and read.mode or nil,
    status = live.status,
    cost = read and read.cost or nil,
    context_size = read and read.context_size or nil,
    context_window = read and read.context_window or nil,
    focused = live.focused == true,
  }
end

-- Body of POST /api/relay/heartbeat. Focused sessions first so the cap never
-- cuts the session the user is looking at. An empty list must encode as a JSON
-- array, which a fresh Lua {} cannot do; the caller hands in a tagged one
-- (maki.json.decode("[]") carries the array metatable through to encode).
function M.heartbeat_body(instance, snapshots, empty_array)
  local list = {}
  for i, s in ipairs(snapshots) do
    list[i] = s
  end
  table.sort(list, function(a, b)
    return a.focused and not b.focused
  end)
  if #list > M.MAX_SESSIONS then
    for i = M.MAX_SESSIONS + 1, #list do
      list[i] = nil
    end
  end
  if #list == 0 then
    list = empty_array
  end
  return { instance = instance, sessions = list }
end

-- Control: the hub speaks a subset of ACP (JSON-RPC 2.0) to each live session
-- through the relay. Effects are injected so the routing stays testable:
--   effects.prompt(session_id, text) -> "started"|"queued" | nil, err
--   effects.messages(session_id)     -> recent transcript, oldest first | nil
M.PROTOCOL_VERSION = 1

local STOP_REASONS = {
  finished = "end_turn",
  max_tokens = "max_tokens",
  max_turns = "max_turn_requests",
  cancelled = "cancelled",
  dropped = "cancelled",
}

local function result(id, value)
  return { jsonrpc = "2.0", id = id, result = value }
end

local function failure(id, code, message)
  return { jsonrpc = "2.0", id = id, error = { code = code, message = message } }
end

-- ACP prompt content blocks -> one string; only text blocks are relayed.
function M.prompt_text(params)
  local blocks = type(params) == "table" and params.prompt
  if type(blocks) == "string" then
    return blocks
  end
  if type(blocks) ~= "table" then
    return nil
  end
  local parts = {}
  for _, b in ipairs(blocks) do
    if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
      parts[#parts + 1] = b.text
    end
  end
  local text = table.concat(parts, "\n")
  return text ~= "" and text or nil
end

-- Text of the newest visible assistant turn, or nil.
function M.assistant_text(messages)
  if type(messages) ~= "table" then
    return nil
  end
  for i = #messages, 1, -1 do
    local m = messages[i]
    if m.role == "user" and m.kind == "turn" and not m.hidden then
      return nil
    end
    if m.role == "assistant" and not m.hidden then
      local parts = {}
      for _, b in ipairs(m.content or {}) do
        if b.type == "text" and type(b.text) == "string" then
          parts[#parts + 1] = b.text
        end
      end
      if #parts > 0 then
        return table.concat(parts, "")
      end
    end
  end
  return nil
end

function M.controller(effects)
  -- session id -> FIFO of request ids waiting for a TurnEnd.
  local waiting = {}
  local ctl = {}

  function ctl.pending(session_id)
    return waiting[session_id] and #waiting[session_id] or 0
  end

  -- Immediate response frames for one incoming frame (possibly none).
  function ctl.handle(session_id, frame)
    if type(frame) ~= "table" or type(frame.method) ~= "string" then
      return {}
    end
    local id = frame.id
    local method = frame.method
    if id == nil then
      -- Notifications (session/cancel, ...) have no remote-escape API yet.
      return {}
    end
    if method == "initialize" then
      return {
        result(id, {
          protocolVersion = M.PROTOCOL_VERSION,
          agentCapabilities = { loadSession = true },
        }),
      }
    end
    if method == "session/load" or method == "session/new" then
      -- A relayed session already exists; loading adopts it as-is.
      return { result(id, { sessionId = session_id }) }
    end
    if method == "session/prompt" then
      local text = M.prompt_text(frame.params)
      if not text then
        return { failure(id, -32602, "prompt has no text content") }
      end
      local ok, status, err = pcall(effects.prompt, session_id, text)
      if not ok then
        status, err = nil, status
      end
      if not status then
        return { failure(id, -32000, "prompt refused: " .. tostring(err)) }
      end
      local queue = waiting[session_id] or {}
      queue[#queue + 1] = id
      waiting[session_id] = queue
      return {}
    end
    return { failure(id, -32601, "method not found: " .. method) }
  end

  -- Frames closing the oldest open prompt of a session, or nil when none waits.
  function ctl.turn_end(session_id, reason)
    local queue = waiting[session_id]
    if not queue or #queue == 0 then
      return nil
    end
    local id = table.remove(queue, 1)
    local frames = {}
    local ok, messages = pcall(effects.messages, session_id)
    local text = ok and M.assistant_text(messages) or nil
    if text then
      frames[#frames + 1] = {
        jsonrpc = "2.0",
        method = "session/update",
        params = {
          sessionId = session_id,
          update = {
            sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = text },
          },
        },
      }
    end
    frames[#frames + 1] = result(id, { stopReason = STOP_REASONS[reason] or "end_turn" })
    return frames
  end

  -- A session vanished: fail whatever it still owed so callers stop waiting.
  function ctl.drop(session_id)
    local queue = waiting[session_id]
    waiting[session_id] = nil
    local frames = {}
    for _, id in ipairs(queue or {}) do
      frames[#frames + 1] = failure(id, -32000, "session closed")
    end
    return frames
  end

  return ctl
end

return M
