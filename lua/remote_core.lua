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

-- Mirror: POST /api/relay/mirror carries a session's recent transcript plus the
-- prompts waiting on the user, so the hub can render and answer them. Empty
-- arrays come from the caller's tagged `empty`, as in heartbeat_body.
M.MIRROR_LAST = 300
-- Per string, so one huge tool output cannot crowd the rest out of the body.
M.CLIP_BYTES = 16 * 1024
-- The hub may have restarted and lost what it was sent, so an unchanged body
-- still goes out this often.
M.MIRROR_RESEND_SEC = 60
M.MIRROR_FAST_MS = 700
M.MIRROR_IDLE_MS = 3000
M.PERMISSION_DECISIONS = { "allow", "deny" }

-- Cuts on a UTF-8 boundary: a split codepoint would make the body invalid JSON.
function M.clip(s, limit)
  limit = limit or M.CLIP_BYTES
  if type(s) ~= "string" or #s <= limit then
    return s
  end
  local cut = limit
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return s:sub(1, cut) .. ("\n…[clipped %d bytes]"):format(#s - cut)
end

-- Deep copy with every string clipped. An empty table is returned as-is so a
-- tagged empty array from maki still encodes as []; maki protects that tag's
-- metatable, so getmetatable can hand back a non-table that cannot be reused.
function M.clip_value(v, limit)
  if type(v) == "string" then
    return M.clip(v, limit)
  end
  if type(v) ~= "table" or next(v) == nil then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = M.clip_value(x, limit)
  end
  local mt = getmetatable(v)
  return type(mt) == "table" and setmetatable(out, mt) or out
end

local function clip_block(b, limit)
  if type(b) ~= "table" then
    return b
  end
  if b.type == "text" or b.type == "thinking" then
    return { type = b.type, text = M.clip(b.text, limit) }
  end
  if b.type == "tool_use" then
    return { type = b.type, id = b.id, name = b.name, input = M.clip_value(b.input, limit) }
  end
  if b.type == "tool_result" then
    return {
      type = b.type,
      tool_use_id = b.tool_use_id,
      content = M.clip_value(b.content, limit),
      is_error = b.is_error,
    }
  end
  if b.type == "image" then
    return { type = b.type, media_type = b.media_type }
  end
  -- An unknown block still gets clipped, but never its type tag.
  local out = M.clip_value(b, limit)
  out.type = b.type
  return out
end

function M.clip_message(m, empty, limit)
  local content = {}
  for i, b in ipairs(type(m.content) == "table" and m.content or {}) do
    content[i] = clip_block(b, limit)
  end
  return {
    role = m.role,
    kind = m.kind,
    hidden = m.hidden == true,
    content = #content > 0 and content or empty,
  }
end

local function list_or(list, empty)
  return #list > 0 and list or empty
end

-- Normalised question tool input; `multiple` is the schema's alias.
local function question_entries(input, empty)
  local out = {}
  local qs = type(input) == "table" and input.questions
  for _, q in ipairs(type(qs) == "table" and qs or {}) do
    if type(q) == "table" then
      local options = {}
      for _, o in ipairs(type(q.options) == "table" and q.options or {}) do
        if type(o) == "table" then
          options[#options + 1] = { label = o.label, description = o.description }
        end
      end
      out[#out + 1] = {
        question = q.question,
        header = q.header or "",
        options = list_or(options, empty),
        multiSelect = (q.multiSelect or q.multiple) == true,
      }
    end
  end
  return list_or(out, empty)
end

-- Question tool calls with no result yet, oldest first. Derived from the
-- transcript so it works on a maki without the QuestionAsked event.
function M.open_questions(messages, empty, limit)
  local calls, answered = {}, {}
  for _, m in ipairs(type(messages) == "table" and messages or {}) do
    for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
      if b.type == "tool_use" and b.name == "question" and b.id then
        calls[#calls + 1] = b
      elseif b.type == "tool_result" and b.tool_use_id then
        answered[b.tool_use_id] = true
      end
    end
  end
  local out = {}
  for _, b in ipairs(calls) do
    if not answered[b.id] then
      out[#out + 1] = {
        tool_id = b.id,
        questions = question_entries(M.clip_value(b.input, limit), empty),
      }
    end
  end
  return list_or(out, empty)
end

-- tool_use id -> input, for joining a permission prompt to the call it gates.
function M.tool_inputs(messages)
  local out = {}
  for _, m in ipairs(type(messages) == "table" and messages or {}) do
    for _, b in ipairs(type(m.content) == "table" and m.content or {}) do
      if b.type == "tool_use" and b.id then
        out[b.id] = b.input
      end
    end
  end
  return out
end

-- Open permission prompts per session, fed by PermissionRequested and
-- PermissionResolved; maki has no call that lists them.
function M.permission_book()
  local open, seq = {}, 0
  local book = {}

  function book.add(data)
    if type(data) ~= "table" or data.request_id == nil or not data.session_id then
      return
    end
    seq = seq + 1
    open[data.request_id] = { seq = seq, data = data }
  end

  function book.resolve(request_id)
    open[request_id] = nil
  end

  function book.has(session_id, request_id)
    local e = open[request_id]
    return e ~= nil and e.data.session_id == session_id
  end

  -- Oldest first, so the hub shows prompts in the order they opened.
  function book.open(session_id)
    local list = {}
    for _, e in pairs(open) do
      if e.data.session_id == session_id then
        list[#list + 1] = e
      end
    end
    table.sort(list, function(a, b)
      return a.seq < b.seq
    end)
    for i, e in ipairs(list) do
      list[i] = e.data
    end
    return list
  end

  -- Prompts of a closed session never resolve through an event.
  function book.retain(live)
    for id, e in pairs(open) do
      if not live[e.data.session_id] then
        open[id] = nil
      end
    end
  end

  return book
end

-- Permission prompts in wire shape, input joined from the transcript (absent
-- when the call is nested in batch/code_execution or older than the window).
function M.permission_entries(open, messages, empty, limit)
  local inputs = M.tool_inputs(messages)
  local out = {}
  for _, p in ipairs(open or {}) do
    local input = p.tool_id and p.tool_id ~= "" and inputs[p.tool_id] or nil
    out[#out + 1] = {
      request_id = p.request_id,
      tool = p.tool,
      scopes = type(p.scopes) == "table" and #p.scopes > 0 and p.scopes or empty,
      tool_id = p.tool_id,
      subagent_id = p.subagent_id,
      reason = p.reason,
      input = input ~= nil and M.clip_value(input, limit) or nil,
    }
  end
  return list_or(out, empty)
end

function M.capabilities(session_api)
  local api = type(session_api) == "table" and session_api or {}
  return {
    cancel = api.cancel ~= nil,
    answer_question = api.answer_question ~= nil,
    permission_decisions = M.PERMISSION_DECISIONS,
  }
end

-- Body of POST /api/relay/mirror. messages() reports no transcript length, so
-- offset stays 0 and the hub keys on the window it is sent.
function M.mirror_body(session_id, messages, open_permissions, capabilities, empty)
  local list = type(messages) == "table" and messages or {}
  local first = math.max(#list - M.MIRROR_LAST + 1, 1)
  local out = {}
  for i = first, #list do
    out[#out + 1] = M.clip_message(list[i], empty)
  end
  return {
    session = session_id,
    offset = 0,
    messages = list_or(out, empty),
    permissions = M.permission_entries(open_permissions, list, empty),
    questions = M.open_questions(list, empty),
    capabilities = capabilities,
  }
end

-- Fast while the session works or waits on the user, so the hub sees prompts
-- and progress promptly; slow when idle.
function M.mirror_interval(status, body)
  local waiting = type(body) == "table"
    and (
      (type(body.permissions) == "table" and #body.permissions > 0)
      or (type(body.questions) == "table" and #body.questions > 0)
    )
  if status == "working" or waiting then
    return M.MIRROR_FAST_MS
  end
  return M.MIRROR_IDLE_MS
end

-- Sends only on change, plus the periodic resend. A failed send forgets the
-- last body so the next tick retries it.
function M.mirror_gate(resend_sec)
  resend_sec = resend_sec or M.MIRROR_RESEND_SEC
  local last = {}
  local gate = {}

  function gate.due(session_id, encoded, now)
    local l = last[session_id]
    return not l or l.encoded ~= encoded or now - l.at >= resend_sec
  end

  function gate.sent(session_id, encoded, now)
    last[session_id] = { encoded = encoded, at = now }
  end

  function gate.invalidate(session_id)
    last[session_id] = nil
  end

  return gate
end

-- Control: the hub speaks a subset of ACP (JSON-RPC 2.0) to each live session
-- through the relay. Effects are injected so the routing stays testable:
--   effects.prompt(session_id, text) -> "started"|"queued" | nil, err
--   effects.messages(session_id)     -> recent transcript, oldest first | nil
-- and, for the maki/* extensions that drive the UI directly:
--   effects.answer_permission(request_id, decision, guidance) -> bool | nil, err
--   effects.permission_open(session_id, request_id) -> bool        (optional)
--   effects.answer_question(session_id, tool_id, answer) -> bool | nil, err
--   effects.cancel(session_id)       -> bool | nil, err
--   effects.capabilities()           -> as M.capabilities
--   effects.touched(session_id)      after an action, so the mirror resends
-- answer_question and cancel are nil on a maki without those APIs.
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

-- Effect results as (value, err): a raise and a nil-pair read the same.
local function attempt(fn, ...)
  local ok, value, err = pcall(fn, ...)
  if not ok then
    return nil, value
  end
  if value == nil then
    return nil, err or "no answer"
  end
  return value
end

local function is_string_list(t)
  if type(t) ~= "table" then
    return false
  end
  for k, v in pairs(t) do
    if type(k) ~= "number" or type(v) ~= "string" then
      return false
    end
  end
  return true
end

local function contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
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

  local function touched(session_id)
    if effects.touched then
      pcall(effects.touched, session_id)
    end
  end

  -- Answered immediately; unlike session/prompt nothing waits for TurnEnd,
  -- the hub follows the result through the mirror.
  local maki_methods = {}

  maki_methods["maki/prompt"] = function(session_id, id, params)
    if type(params.text) ~= "string" or params.text:match("^%s*$") then
      return failure(id, -32602, "text must be a non-empty string")
    end
    local status, err = attempt(effects.prompt, session_id, params.text)
    if not status then
      return failure(id, -32000, "prompt refused: " .. tostring(err))
    end
    touched(session_id)
    return result(id, { status = status })
  end

  maki_methods["maki/answer_permission"] = function(session_id, id, params)
    local request_id = tonumber(params.request_id)
    if not request_id then
      return failure(id, -32602, "request_id must be a number")
    end
    local caps = effects.capabilities and effects.capabilities() or M.capabilities(nil)
    if
      type(params.decision) ~= "string" or not contains(caps.permission_decisions, params.decision)
    then
      return failure(
        id,
        -32602,
        "decision must be one of: " .. table.concat(caps.permission_decisions, ", ")
      )
    end
    if params.guidance ~= nil and type(params.guidance) ~= "string" then
      return failure(id, -32602, "guidance must be a string")
    end
    -- A request id from another session's mirror would answer the wrong prompt.
    if effects.permission_open and not effects.permission_open(session_id, request_id) then
      return failure(id, -32602, "no open permission request " .. request_id .. " in this session")
    end
    local landed, err =
      attempt(effects.answer_permission, request_id, params.decision, params.guidance)
    if landed == nil then
      return failure(id, -32000, "answer refused: " .. tostring(err))
    end
    touched(session_id)
    return result(id, { landed = landed == true })
  end

  maki_methods["maki/answer_question"] = function(session_id, id, params)
    if not effects.answer_question then
      return failure(id, -32601, "not supported by this maki")
    end
    if type(params.tool_id) ~= "string" or params.tool_id == "" then
      return failure(id, -32602, "tool_id must be a non-empty string")
    end
    local answer
    if params.dismiss == true then
      answer = { dismiss = true }
    else
      local answers = params.answers
      local valid = type(answers) == "table" and #answers > 0
      for k, a in pairs(valid and answers or {}) do
        if type(k) ~= "number" or not is_string_list(a) then
          valid = false
        end
      end
      if not valid then
        return failure(
          id,
          -32602,
          "answers must be a non-empty array of label arrays, or dismiss=true"
        )
      end
      answer = { answers = answers }
    end
    local landed, err = attempt(effects.answer_question, session_id, params.tool_id, answer)
    if landed == nil then
      return failure(id, -32000, "answer refused: " .. tostring(err))
    end
    touched(session_id)
    return result(id, { landed = landed == true })
  end

  maki_methods["maki/cancel"] = function(session_id, id)
    if not effects.cancel then
      return failure(id, -32601, "not supported by this maki")
    end
    local cancelled, err = attempt(effects.cancel, session_id)
    if cancelled == nil then
      return failure(id, -32000, "cancel refused: " .. tostring(err))
    end
    touched(session_id)
    return result(id, { cancelled = cancelled == true })
  end

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
    local maki_method = maki_methods[method]
    if maki_method then
      local params = type(frame.params) == "table" and frame.params or {}
      return { maki_method(session_id, id, params) }
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
