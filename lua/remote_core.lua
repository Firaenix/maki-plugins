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
-- closed between live() and read(). {thinking} is the session's thinking level
-- when known (string), else nil.
function M.snapshot(live, read, thinking)
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
    thinking = type(thinking) == "string" and thinking or nil,
  }
end

-- Body of POST /api/relay/heartbeat. Focused sessions first so the cap never
-- cuts the session the user is looking at. An empty list must encode as a JSON
-- array, which a fresh Lua {} cannot do; the caller hands in a tagged one
-- (maki.json.decode("[]") carries the array metatable through to encode).
-- {plugins_summary} is {total, errors}, or nil when unknown.
function M.heartbeat_body(instance, snapshots, empty_array, plugins_summary)
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
  return { instance = instance, sessions = list, plugins_summary = plugins_summary }
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

-- {features} flags the maki/* methods this maki can answer: commands,
-- command, models, model_set, skills, plugins, and images (prompt takes
-- image attachments). A missing flag reads false.
function M.capabilities(session_api, features)
  local api = type(session_api) == "table" and session_api or {}
  local f = type(features) == "table" and features or {}
  return {
    cancel = api.cancel ~= nil,
    answer_question = api.answer_question ~= nil,
    -- maki.session.detach ships with prompt's force flag, so one probe covers both.
    send_now = type(api.detach) == "function",
    permission_decisions = M.PERMISSION_DECISIONS,
    commands = f.commands == true,
    command = f.command == true,
    models = f.models == true,
    model_set = f.model_set == true,
    skills = f.skills == true,
    plugins = f.plugins == true,
    images = f.images == true,
  }
end

-- Remote slash commands: only names on the allowlist reach run_command, and
-- only those (plus the web-native pickers below) are ever listed to the hub.
M.DEFAULT_COMMANDS_ALLOW = "compact,new,btw,fast,workflow,reload,goal,skills"
M.MAX_CMDLINE = 4096
-- Interactive pickers the hub answers with its own UI. Listed, never run.
M.WEB_NATIVE = { model = true, thinking = true, sessions = true }

-- Used when maki has no maki.api.list_commands: descriptions from maki's
-- palette (maki-ui/src/components/command.rs) and the plugins' own.
M.FALLBACK_COMMANDS = {
  {
    name = "/compact",
    description = "Summarize and compact conversation history (optional guidance)",
    source = "builtin",
  },
  { name = "/new", description = "Start a new session", source = "builtin" },
  {
    name = "/btw",
    description = "Ask a quick question (no tools, no history pollution)",
    source = "builtin",
  },
  {
    name = "/fast",
    description = "Toggle fast mode (Anthropic Opus or Codex subscription models)",
    source = "builtin",
  },
  {
    name = "/workflow",
    description = "Toggle workflow mode (task callable inside code_execution)",
    source = "builtin",
  },
  { name = "/reload", description = "Reload plugins and config", source = "builtin" },
  { name = "/model", description = "Switch model", source = "builtin", interactive = true },
  {
    name = "/thinking",
    description = "Extended thinking: pick an effort level, or set one directly",
    source = "lua",
    plugin = "thinking",
    interactive = true,
  },
  {
    name = "/sessions",
    description = "Browse and switch sessions",
    source = "lua",
    plugin = "sessions",
    interactive = true,
  },
  {
    name = "/goal",
    description = "Set a goal the agent pursues across turns; bare /goal manages it, 'config' toggles constraints",
    source = "lua",
    plugin = "maki-plugins",
  },
  {
    name = "/skills",
    description = "List every skill the `skill` tool can load in this session.",
    source = "lua",
    plugin = "maki-plugins",
  },
}

local function command_key(name)
  if type(name) ~= "string" then
    return nil
  end
  local key = name:gsub("^/", ""):lower()
  return key ~= "" and key or nil
end

-- "compact, /New,,goal" -> {compact=true, new=true, goal=true}. nil means
-- the default list; an empty string allows nothing.
function M.parse_allowlist(s)
  if type(s) ~= "string" then
    s = M.DEFAULT_COMMANDS_ALLOW
  end
  local set = {}
  for part in s:gmatch("[^,]+") do
    local key = command_key((part:gsub("^%s+", ""):gsub("%s+$", "")))
    if key and not key:find("[%s!]") then
      set[key] = true
    end
  end
  return set
end

-- maki/commands entries from maki.api.list_commands() output, or from
-- FALLBACK_COMMANDS when {listed} is nil. Allowlisted names missing from the
-- fallback table still get a bare entry so the hub can run them.
function M.command_list(listed, allow)
  local from_api = type(listed) == "table"
  local seen, out = {}, {}
  for _, c in ipairs(from_api and listed or M.FALLBACK_COMMANDS) do
    local key = type(c) == "table" and command_key(c.name)
    if key and not seen[key] and (allow[key] or M.WEB_NATIVE[key]) then
      seen[key] = true
      out[#out + 1] = {
        name = "/" .. key,
        description = type(c.description) == "string" and c.description or "",
        source = c.source or "builtin",
        plugin = c.plugin,
        argument_hint = c.argument_hint,
        interactive = c.interactive == true or (M.WEB_NATIVE[key] == true and not allow[key]),
        allowed = true,
      }
    end
  end
  if not from_api then
    local extra = {}
    for key in pairs(allow) do
      if not seen[key] then
        extra[#extra + 1] = key
      end
    end
    table.sort(extra)
    for _, key in ipairs(extra) do
      out[#out + 1] = {
        name = "/" .. key,
        description = "",
        source = "lua",
        interactive = false,
        allowed = true,
      }
    end
  end
  return out
end

-- The allowlist key of {cmdline}, or nil and why it is refused. A bang (`!`
-- line, or `/name!`) is refused whatever the allowlist says.
function M.check_cmdline(cmdline, allow)
  if type(cmdline) ~= "string" or cmdline:sub(1, 1) ~= "/" then
    return nil, "cmdline must be a string starting with /"
  end
  if #cmdline > M.MAX_CMDLINE then
    return nil, "cmdline exceeds " .. M.MAX_CMDLINE .. " bytes"
  end
  for line in cmdline:gmatch("[^\n]+") do
    if line:match("^%s*!") then
      return nil, "! lines are never run remotely"
    end
  end
  local name = cmdline:match("^/(%S+)")
  if not name or name:find("!", 1, true) then
    return nil, "bang commands are never run remotely"
  end
  local key = name:lower()
  if not allow[key] then
    return nil, "/" .. key .. " is not in remote_commands_allow"
  end
  return key
end

-- maki.model.get() -> the maki/models `current` shape, or nil.
function M.model_current(m, empty)
  if type(m) ~= "table" or type(m.spec) ~= "string" then
    return nil
  end
  local options = {}
  for _, o in ipairs(type(m.thinking_options) == "table" and m.thinking_options or {}) do
    if type(o) == "table" and o.name ~= nil then
      options[#options + 1] = { name = tostring(o.name), tokens = tonumber(o.tokens) }
    end
  end
  return {
    spec = m.spec,
    thinking = m.thinking ~= nil and tostring(m.thinking) or nil,
    fast = m.fast == true,
    thinking_options = list_or(options, empty),
    supports_thinking = m.supports_thinking == true,
    supports_fast = m.supports_fast == true,
  }
end

-- One maki/models entry from an available() spec and its info(), if any.
function M.model_entry(spec, info)
  local i = type(info) == "table" and info or {}
  local provider, id = spec:match("^([^/]+)/(.+)$")
  return {
    spec = spec,
    provider = i.provider or provider or "",
    id = i.id or id or spec,
    name = type(i.name) == "string" and i.name or nil,
    context_window = tonumber(i.context_window),
  }
end

-- Body of POST /api/relay/mirror. messages() reports no transcript length, so
-- offset stays 0 and the hub keys on the window it is sent.
function M.mirror_body(session_id, messages, open_permissions, capabilities, empty, todos)
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
    todos = todos,
  }
end

-- What maki.session.cancel answers when it interrupted a turn.
M.CANCELLED = "cancelled"

local TODO_STATUSES = { pending = true, in_progress = true, completed = true, cancelled = true }

-- A todo_write input as [{content, status, priority?}], or nil when it is not
-- a list: maki rejects such a call, so it never replaced the list.
function M.todo_entries(input, empty)
  local items = type(input) == "table" and input.todos
  if type(items) ~= "table" then
    return nil
  end
  local out = {}
  for _, item in ipairs(items) do
    if type(item) == "table" and type(item.content) == "string" then
      out[#out + 1] = {
        content = M.clip(item.content),
        status = TODO_STATUSES[item.status] and item.status or "pending",
        priority = type(item.priority) == "string" and item.priority or nil,
      }
    end
  end
  return list_or(out, empty)
end

-- Newest well-formed todo_write in `messages`, or nil.
local function latest_todos(messages, empty)
  for i = #messages, 1, -1 do
    local content = type(messages[i]) == "table" and messages[i].content
    if type(content) == "table" then
      for j = #content, 1, -1 do
        local b = content[j]
        if type(b) == "table" and b.type == "tool_use" and b.name == "todo_write" then
          local todos = M.todo_entries(b.input, empty)
          if todos then
            return todos
          end
        end
      end
    end
  end
  return nil
end

-- Latest todo list per session over its whole history. The mirror window holds
-- the newest messages, so a call in it is the latest; only a session whose
-- window has none pays for one full-history read, after which every later
-- call lands in the window before it can scroll out.
function M.todo_tracker()
  local known = {}
  local tracker = {}

  function tracker.observe(session_id, window, read_all, empty)
    local found = latest_todos(type(window) == "table" and window or {}, empty)
    if found then
      known[session_id] = { todos = found }
    elseif not known[session_id] then
      local all = read_all()
      if type(all) ~= "table" then
        return nil
      end
      known[session_id] = { todos = latest_todos(all, empty) }
    end
    return known[session_id].todos
  end

  function tracker.forget(session_id)
    known[session_id] = nil
  end

  return tracker
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
--   effects.prompt(session_id, text, force, images) -> "started"|"queued"|"forced" | nil, err
--     images is nil or a non-empty list of {media_type, data}, as M.check_images
--   effects.messages(session_id)     -> recent transcript, oldest first | nil
-- and, for the maki/* extensions that drive the UI directly:
--   effects.answer_permission(request_id, decision, guidance) -> bool | nil, err
--   effects.permission_open(session_id, request_id) -> bool        (optional)
--   effects.answer_question(session_id, tool_id, answer) -> bool | nil, err
--   effects.cancel(session_id)       -> "cancelled" | "idle" | nil, err
--                                       (older makis answer true | false)
--   effects.detach(session_id)       -> bool | nil, err  (send now; gates force)
--   effects.capabilities()           -> as M.capabilities
--   effects.touched(session_id)      after an action, so the mirror resends
-- answer_question, cancel and detach are nil on a maki without those APIs. The
-- catalog methods take, each optional (nil answers -32601):
--   effects.allow                    allowlist set, as M.parse_allowlist
--   effects.commands()               maki.api.list_commands() | nil (fallback)
--   effects.run_command(session_id, cmdline) -> true | nil, err
--   effects.model_get(session_id)    maki.model.get() shape | nil
--   effects.models_available()       {"provider/id", ...}
--   effects.model_info(spec)         maki.model.info() | nil
--   effects.model_set(session_id, {spec, thinking?, fast?}) -> true | nil, err
--   effects.skills(session_id)       {{name, description, path}}
--   effects.plugins()                {plugins, source}, as plugins_core.collect
--   effects.empty                    tagged empty array (default {})
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

M.MAX_IMAGES = 8
M.IMAGE_TYPES = {
  ["image/png"] = true,
  ["image/jpeg"] = true,
  ["image/gif"] = true,
  ["image/webp"] = true,
}

-- Image attachments -> a copied list, nil when absent or empty, or (nil, err).
-- The base64 check is charset only; maki decodes and raises on the rest.
function M.check_images(images)
  if images == nil then
    return nil
  end
  if type(images) ~= "table" then
    return nil, "images must be an array"
  end
  local n = 0
  for k in pairs(images) do
    if type(k) ~= "number" then
      return nil, "images must be an array"
    end
    n = n + 1
  end
  if n ~= #images then
    return nil, "images must be an array"
  end
  if n > M.MAX_IMAGES then
    return nil, "at most " .. M.MAX_IMAGES .. " images"
  end
  local out = {}
  for i, img in ipairs(images) do
    if type(img) ~= "table" then
      return nil, "image " .. i .. " must be an object"
    end
    if type(img.media_type) ~= "string" or not M.IMAGE_TYPES[img.media_type] then
      return nil,
        "image " .. i .. " media_type must be image/png, image/jpeg, image/gif or image/webp"
    end
    if type(img.data) ~= "string" or img.data == "" or img.data:find("[^%w+/=]") then
      return nil, "image " .. i .. " data must be non-empty base64"
    end
    out[i] = { media_type = img.media_type, data = img.data }
  end
  return n > 0 and out or nil
end

-- ACP image content blocks -> M.check_images, or (nil, err).
function M.prompt_images(params)
  local blocks = type(params) == "table" and params.prompt
  if type(blocks) ~= "table" then
    return nil
  end
  local images = {}
  for _, b in ipairs(blocks) do
    if type(b) == "table" and b.type == "image" then
      images[#images + 1] = { media_type = b.mimeType, data = b.data }
    end
  end
  return M.check_images(images)
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
    local images, bad = M.check_images(params.images)
    if bad then
      return failure(id, -32602, bad)
    end
    if type(params.text) ~= "string" or (not images and params.text:match("^%s*$")) then
      return failure(id, -32602, "text must be a non-empty string")
    end
    if params.force ~= nil and type(params.force) ~= "boolean" then
      return failure(id, -32602, "force must be a boolean")
    end
    local force = params.force == true
    -- An older maki would quietly queue instead, so say so rather than lie.
    if force and not effects.detach then
      return failure(id, -32601, "send now is not supported by this maki")
    end
    local status, err = attempt(effects.prompt, session_id, params.text, force, images)
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

  local empty = effects.empty or {}
  local allow = effects.allow or M.parse_allowlist(nil)

  maki_methods["maki/commands"] = function(_, id)
    local listed = nil
    if effects.commands then
      local ok, v = pcall(effects.commands)
      listed = ok and type(v) == "table" and v or nil
    end
    return result(id, { commands = list_or(M.command_list(listed, allow), empty) })
  end

  maki_methods["maki/command"] = function(session_id, id, params)
    if not effects.run_command then
      return failure(id, -32601, "not supported by this maki")
    end
    local key, why = M.check_cmdline(params.cmdline, allow)
    if not key then
      return failure(id, -32602, why)
    end
    local ok, err = attempt(effects.run_command, session_id, params.cmdline)
    if not ok then
      return failure(id, -32000, "command refused: " .. tostring(err))
    end
    touched(session_id)
    return result(id, { dispatched = true })
  end

  local function current_model(session_id)
    if not effects.model_get then
      return nil
    end
    local ok, m = pcall(effects.model_get, session_id)
    return ok and M.model_current(m, empty) or nil
  end

  maki_methods["maki/models"] = function(session_id, id)
    if not effects.models_available then
      return failure(id, -32601, "not supported by this maki")
    end
    local specs, err = attempt(effects.models_available)
    if not specs then
      return failure(id, -32000, "model list failed: " .. tostring(err))
    end
    local models = {}
    for _, spec in ipairs(specs) do
      if type(spec) == "string" then
        local info = nil
        if effects.model_info then
          local ok, v = pcall(effects.model_info, spec)
          info = ok and v or nil
        end
        models[#models + 1] = M.model_entry(spec, info)
      end
    end
    return result(id, { current = current_model(session_id), models = list_or(models, empty) })
  end

  maki_methods["maki/model_set"] = function(session_id, id, params)
    if not effects.model_set then
      return failure(id, -32601, "per-session model switching needs a newer maki")
    end
    local spec, thinking, fast = params.spec, params.thinking, params.fast
    if spec ~= nil and (type(spec) ~= "string" or not spec:match("^[^/%s]+/%S+$")) then
      return failure(id, -32602, "spec must be a provider/id string")
    end
    if thinking ~= nil and type(thinking) ~= "string" and type(thinking) ~= "number" then
      return failure(id, -32602, "thinking must be a string or number")
    end
    if fast ~= nil and type(fast) ~= "boolean" then
      return failure(id, -32602, "fast must be a boolean")
    end
    if spec == nil and thinking == nil and fast == nil then
      return failure(id, -32602, "nothing to set: pass spec, thinking or fast")
    end
    local ok, err =
      attempt(effects.model_set, session_id, { spec = spec, thinking = thinking, fast = fast })
    if not ok then
      return failure(id, -32000, "model change refused: " .. tostring(err))
    end
    touched(session_id)
    return result(id, { ok = true, current = current_model(session_id) })
  end

  maki_methods["maki/skills"] = function(session_id, id)
    if not effects.skills then
      return failure(id, -32601, "not supported by this maki")
    end
    local skills, err = attempt(effects.skills, session_id)
    if not skills then
      return failure(id, -32000, "skill discovery failed: " .. tostring(err))
    end
    return result(id, { skills = list_or(skills, empty) })
  end

  maki_methods["maki/plugins"] = function(_, id)
    if not effects.plugins then
      return failure(id, -32601, "not supported by this maki")
    end
    local res, err = attempt(effects.plugins)
    if type(res) ~= "table" then
      return failure(id, -32000, "plugin list failed: " .. tostring(err))
    end
    return result(id, {
      plugins = list_or(type(res.plugins) == "table" and res.plugins or {}, empty),
      source = res.source or "fallback",
    })
  end

  maki_methods["maki/cancel"] = function(session_id, id)
    if not effects.cancel then
      return failure(id, -32601, "not supported by this maki")
    end
    local state, err = attempt(effects.cancel, session_id)
    if state == nil then
      return failure(id, -32000, "cancel refused: " .. tostring(err))
    end
    touched(session_id)
    return result(id, { cancelled = state == M.CANCELLED or state == true })
  end

  -- Forces what is already queued; false when there is nothing to force or
  -- the turn waits on a permission prompt or question.
  maki_methods["maki/detach"] = function(session_id, id)
    if not effects.detach then
      return failure(id, -32601, "not supported by this maki")
    end
    local detached, err = attempt(effects.detach, session_id)
    if detached == nil then
      return failure(id, -32000, "detach refused: " .. tostring(err))
    end
    touched(session_id)
    return result(id, { detached = detached == true })
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
      local images, bad = M.prompt_images(frame.params)
      if bad then
        return { failure(id, -32602, bad) }
      end
      local text = M.prompt_text(frame.params)
      if not text and not images then
        return { failure(id, -32602, "prompt has no text content") }
      end
      local ok, status, err = pcall(effects.prompt, session_id, text or "", nil, images)
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

-- /remote-control

M.LOG_CAP = 200
M.CONTROL_USAGE = "usage: /remote-control [status|toggle|logs [clear]]"

-- fargs from register_command -> {cmd = "status"|"toggle"|"logs", clear?},
-- or nil and the usage line.
function M.parse_control_args(fargs)
  local words = {}
  for _, w in ipairs(fargs or {}) do
    if w ~= "" then
      words[#words + 1] = w:lower()
    end
  end
  local cmd, rest = words[1] or "status", #words - 1
  if (cmd == "status" or cmd == "toggle") and rest <= 0 then
    return { cmd = cmd }
  end
  if cmd == "logs" and rest <= 0 then
    return { cmd = "logs", clear = false }
  end
  if cmd == "logs" and rest == 1 and words[2] == "clear" then
    return { cmd = "logs", clear = true }
  end
  return nil, M.CONTROL_USAGE
end

-- Last {cap} log lines, oldest first. {at} is epoch seconds.
function M.log_ring(cap)
  cap = cap or M.LOG_CAP
  local entries, first, count = {}, 1, 0
  local ring = {}

  function ring.push(at, level, msg)
    local slot = (first + count - 1) % cap + 1
    entries[slot] = { at = at, level = level, msg = msg }
    if count < cap then
      count = count + 1
    else
      first = first % cap + 1
    end
  end

  function ring.entries()
    local out = {}
    for i = 0, count - 1 do
      out[#out + 1] = entries[(first + i - 1) % cap + 1]
    end
    return out
  end

  function ring.lines()
    local out = {}
    for _, e in ipairs(ring.entries()) do
      out[#out + 1] = os.date("%H:%M:%S", e.at) .. " " .. e.level:upper() .. " " .. e.msg
    end
    return out
  end

  function ring.count()
    return count
  end

  function ring.clear()
    entries, first, count = {}, 1, 0
  end

  return ring
end

-- Enough of the token to tell two apart, never enough to use one.
function M.mask_token(token)
  if type(token) ~= "string" or token == "" then
    return "(unset)"
  end
  if #token < 12 then
    return string.rep("*", #token)
  end
  return token:sub(1, 4) .. "…" .. token:sub(-2) .. " (" .. #token .. " chars)"
end

-- Strips any user:pass@ from the URL.
function M.mask_url(url)
  if type(url) ~= "string" or url == "" then
    return "(unset)"
  end
  return (url:gsub("^(%a[%w+.-]*://)[^/@]*@", "%1***@"))
end

local function ago(now, at)
  if not at then
    return "never"
  end
  local s = math.max(0, now - at)
  if s < 60 then
    return s .. "s ago"
  elseif s < 3600 then
    return math.floor(s / 60) .. "m ago"
  end
  return math.floor(s / 3600) .. "h ago"
end

local function sorted_keys(set)
  local out = {}
  for k in pairs(set or {}) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

-- Status float lines from a plain snapshot of the plugin's state:
-- {url, token, control, now, fork, allow (set)} always; opted_in = false adds
-- {missing = {env names}}; otherwise {paused, token_refused, interval,
-- last_beat = {at, status?, err?}, failures, live, polling, mirroring}.
function M.status_lines(s)
  local lines = {}
  local function add(label, value)
    lines[#lines + 1] = string.format("%-16s %s", label, tostring(value))
  end
  add("hub", M.mask_url(s.url))
  add("token", M.mask_token(s.token))
  if not s.opted_in then
    add("state", "off: " .. table.concat(s.missing or {}, " and ") .. " not set")
    add("control", s.control and "enabled" or "disabled (MAKI_HUB_CONTROL=0)")
  else
    local state = s.token_refused and "stopped: hub refused the token (toggle to retry)"
      or s.paused and "paused"
      or "running"
    add("state", state)
    add("control", s.control and "enabled" or "disabled (MAKI_HUB_CONTROL=0)")
    local beat = s.last_beat or {}
    local result = beat.status and ("HTTP " .. beat.status)
      or beat.err and ("error: " .. beat.err)
      or "-"
    add("last heartbeat", ago(s.now, beat.at) .. (beat.at and (", " .. result) or ""))
    add("interval", (s.interval or "?") .. "s")
    add("failures", (s.failures or 0) .. " in a row")
    add("live sessions", s.live or 0)
    if s.control then
      local loops = (s.paused or s.token_refused) and " (paused)" or ""
      add("poll loops", (s.polling or 0) .. loops)
      add("mirror loops", (s.mirroring or 0) .. loops)
    else
      add("poll loops", "off")
      add("mirror loops", "off")
    end
  end
  add("fork APIs", s.fork and "yes (maki.api.list_commands)" or "no")
  local allow = sorted_keys(s.allow)
  add("allowlist", #allow > 0 and table.concat(allow, ", ") or "(none)")
  return lines
end

return M
