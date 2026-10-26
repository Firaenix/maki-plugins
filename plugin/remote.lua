-- remote: announces this maki to a maki-hub, over HTTPS, every few seconds.
--
-- Opt-in through the environment, since this pack installs on every machine:
-- without MAKI_HUB_URL and MAKI_HUB_TOKEN the plugin never sends a request.
-- The token is the hub's host token from its Nix-declared registry, one per
-- machine; see maki-hub's PROTOCOL.md. MAKI_HUB_INTERVAL overrides the beat
-- spacing in seconds (default 5, the hub calls an instance offline at 90).
--
-- The hub is expected to be a public https origin: maki.net.request upgrades
-- plain http and blocks private addresses, so a LAN or loopback hub needs
-- net.allowed_private_hosts in the maki config.
--
-- Control: every heartbeated session also long-polls the hub for JSON-RPC
-- frames (a small ACP subset plus maki/* actions: prompt, answer a permission
-- or question, cancel; see remote_core) and posts answers back, and mirrors
-- its recent transcript with the open permission prompts and questions to
-- /api/relay/mirror, so the hub can follow and drive this maki.
-- MAKI_HUB_CONTROL=0 keeps the plugin report-only.
--
-- Catalog methods (maki/commands, command, models, model_set, skills,
-- plugins) feature-detect the fork APIs. maki.api.list_commands is the marker
-- for the fork build that also takes {session} in maki.api.run_command and
-- maki.model.get/set: without it commands run only in the focused session,
-- the current model is reported only for the focused session and
-- maki/model_set answers -32601. Remote slash commands are limited to the
-- comma-separated option remote_commands_allow.
--
-- /remote-control shows status, pauses or resumes every loop in memory
-- (toggle; a resume also retries a refused token) and shows the last 200 log
-- lines (logs [clear]). It is registered even when the plugin is off.

local Core = require("remote_core")
local PluginsCore = require("plugins_core")
local SkillsCore = require("skills_core")

-- Every line also lands in a ring that /remote-control logs shows.
local logRing = Core.log_ring(Core.LOG_CAP)
local function log(level, msg)
  logRing.push(os.time(), level, msg)
  maki.log[level]("remote: " .. msg)
end

-- Declared before the opt-in check so the option is accepted even when the
-- hub is off.
local okOpts, opts = pcall(maki.api.register_options, {
  remote_commands_allow = {
    default = Core.DEFAULT_COMMANDS_ALLOW,
    desc = "Comma-separated slash commands (no /) a maki-hub may list and run here.",
  },
})
if not okOpts then
  log("warn", "register_options failed: " .. tostring(opts))
  opts = {}
end

local url = (maki.uv.os_getenv("MAKI_HUB_URL") or ""):gsub("/+$", "")
local token = maki.uv.os_getenv("MAKI_HUB_TOKEN")
local controlEnabled = maki.uv.os_getenv("MAKI_HUB_CONTROL") ~= "0"
local perSession = type(maki.api.list_commands) == "function"
local allowSet = Core.parse_allowlist(opts.remote_commands_allow)

-- Set once the plugin is opted in: {state = fn -> table, toggle = fn -> text}.
local runtime = nil

local TICK_MS = 200

local function baseState()
  local missing = {}
  if url == "" then
    missing[#missing + 1] = "MAKI_HUB_URL"
  end
  if not token or token == "" then
    missing[#missing + 1] = "MAKI_HUB_TOKEN"
  end
  return {
    opted_in = false,
    missing = missing,
    url = url,
    token = token,
    control = controlEnabled,
    fork = perSession,
    allow = allowSet,
    now = os.time(),
  }
end

-- {lines} as a float; {bottom} opens it scrolled to the last line. j/k and
-- g/G move it; the window itself only scrolls with the mouse wheel.
local function showLines(title, lines, bottom)
  if #lines == 0 then
    lines = { "(empty)" }
  end
  local tsize = maki.ui.terminal_size()
  local width = 40
  local rows = {}
  for i, l in ipairs(lines) do
    rows[i] = { { l, "item" } }
    width = math.max(width, maki.ui.display_width(l) + 4)
  end
  local height = math.min(#rows + 2, tsize.rows - 4)
  local view = math.max(1, height - 2)
  local buf = maki.ui.buf()
  buf:set_lines(rows)
  local win = maki.ui.open_win(buf, {
    title = " " .. title .. " ",
    border = "rounded",
    width = math.min(width, tsize.cols - 4),
    height = height,
    footer = { { "j/k", "scroll" }, { "g/G", "top/bottom" }, { "q", "close" } },
  })
  -- First visible row, tracked here because set_cursor only scrolls as far
  -- as it takes to show the row it is given.
  local top = 1
  local lastTop = math.max(1, #rows - view + 1)
  local function scrollTo(newTop)
    newTop = math.max(1, math.min(lastTop, newTop))
    if newTop < top then
      win:set_cursor(newTop)
    elseif newTop > top then
      win:set_cursor(newTop + view - 1)
    end
    top = newTop
  end
  if bottom then
    scrollTo(lastTop)
  end
  while true do
    -- Timeout ticks are ignored: redrawing on them would yank the scroll.
    local ev = win:recv(TICK_MS)
    if not ev or ev.type == "close" then
      break
    end
    if ev.type == "key" then
      local k = ev.key
      if k == "q" or k == "<Esc>" then
        break
      elseif k == "j" or k == "<Down>" then
        scrollTo(top + 1)
      elseif k == "k" or k == "<Up>" then
        scrollTo(top - 1)
      elseif k == "g" then
        scrollTo(1)
      elseif k == "G" then
        scrollTo(lastTop)
      end
    end
  end
  win:close()
end

local function controlCommand(args)
  local parsed, usage = Core.parse_control_args(args and args.fargs)
  if not parsed then
    maki.ui.flash(usage)
    return
  end
  if parsed.cmd == "status" then
    local state = runtime and runtime.state() or baseState()
    showLines("remote-control status", Core.status_lines(state), false)
  elseif parsed.cmd == "toggle" then
    if not runtime then
      local missing = baseState().missing
      maki.ui.flash("remote is off: set " .. table.concat(missing, " and ") .. " and restart maki")
      return
    end
    maki.ui.flash(runtime.toggle())
  elseif parsed.clear then
    local n = logRing.count()
    logRing.clear()
    maki.ui.flash("remote logs cleared (" .. n .. " lines)")
  else
    showLines("remote logs (" .. logRing.count() .. ")", logRing.lines(), true)
  end
end

-- Registered before the opt-in check, so status can say why remote is off.
local okCmd, cmdErr = pcall(maki.api.register_command, {
  name = "/remote-control",
  description = "Hub remote: status (default), toggle (pause/resume), logs [clear]",
  nargs = "*",
  handler = controlCommand,
})
if not okCmd then
  log("warn", "register_command failed: " .. tostring(cmdErr))
end

if url == "" or not token or token == "" then
  return
end
local intervalSec = math.max(tonumber(maki.uv.os_getenv("MAKI_HUB_INTERVAL")) or 5, 1)
-- Seconds the hub may hold a poll open; the request timeout leaves headroom.
local POLL_HOLD_SEC = 25
-- Granularity of the mirror's wait: a woken loop pushes within this.
local MIRROR_STEP_MS = 100

local instanceId = Core.instance_id(os.time(), function()
  return math.random(0, 0x7fffffff)
end)

-- Tagged empty array: a fresh {} encodes as an object, and the hub wants []
-- when this maki has no live sessions.
local EMPTY_SESSIONS = maki.json.decode("[]")

local function gitBranch(cwd)
  local root = maki.fs.root(cwd, ".git")
  if not root then
    return nil
  end
  -- A linked worktree has a gitdir: file here, not a directory; its HEAD is
  -- then unreadable and the branch is simply omitted.
  local head = maki.fs.read(maki.fs.joinpath(root, ".git", "HEAD"))
  return head and Core.parse_head(head) or nil
end

-- perSession (above) is the header's marker for the session-aware
-- run_command and model API.
local runCommand = type(maki.api.run_command) == "function" and maki.api.run_command or nil
local modelApi = type(maki.model) == "table" and maki.model or {}

local function isFocused(sessionId)
  local ok, current = pcall(maki.session.current)
  return ok and current == sessionId
end

-- maki.model.get() for one session; nil when this maki can only read the
-- focused one and that is another session.
local function modelGet(sessionId)
  if type(modelApi.get) ~= "function" then
    return nil
  end
  if perSession then
    return modelApi.get({ session = sessionId })
  end
  return isFocused(sessionId) and modelApi.get() or nil
end

local function thinkingOf(sessionId)
  local ok, m = pcall(modelGet, sessionId)
  if ok and type(m) == "table" and m.thinking ~= nil then
    return tostring(m.thinking)
  end
  return nil
end

-- One beat's worth of sessions, or nil when this process has no interactive UI.
local function snapshots()
  local live, err = maki.session.live()
  if not live then
    if err ~= "no interactive UI attached" then
      log("warn", "session list failed: " .. tostring(err))
    end
    return nil
  end
  local out = {}
  for _, s in ipairs(live) do
    out[#out + 1] = Core.snapshot(s, maki.session.read({ session = s.id }), thinkingOf(s.id))
  end
  return out
end

local healthy = true
-- /remote-control toggle; the loops idle in PAUSE_STEP_MS sleeps meanwhile.
local paused = false
-- Set on a 401/403 heartbeat; heartbeats stop until a toggle retries once.
local tokenRefused = false
local failures = 0
local lastBeat = {}
local PAUSE_STEP_MS = 500

local function idle()
  return paused or tokenRefused
end

local function hubRequest(path, method, body, timeout)
  return maki.net.request(url .. path, {
    method = method,
    headers = {
      ["content-type"] = "application/json",
      ["authorization"] = "Bearer " .. token,
    },
    -- A string body is already encoded (the mirror encodes to compare first).
    body = type(body) == "string" and body or body and maki.json.encode(body) or nil,
    timeout = timeout,
    retry = 0,
  })
end

local function postFrames(sessionId, frames)
  if not frames or #frames == 0 then
    return
  end
  local res, err =
    hubRequest("/api/relay/frames", "POST", { session = sessionId, frames = frames }, 10)
  if not res or res.status >= 400 then
    log("warn", "posting frames failed: " .. tostring(err or res.status))
  end
end

-- Sessions in the latest beat; poll and mirror loops end once theirs leaves.
local liveIds = {}
local liveStatus = {}
local polling = {}
local mirroring = {}
-- Session id -> true when its mirror should push now, not at the next tick.
local mirrorDirty = {}
local permissions = Core.permission_book()
local mirrorGate = Core.mirror_gate()
local todoTracker = Core.todo_tracker()
local questions = Core.question_book()
-- A maki whose question plugin declares `question.form` lets the hub answer
-- by layering the form; an older fork answered through answer_question.
local answerQuestion = maki.session.answer_question
local questionSlot = answerQuestion == nil and type(maki.api.set_slot) == "function"
local function collectPlugins()
  return PluginsCore.collect(PluginsCore.maki_api())
end

-- cancel and answer_question come from a newer maki; detected, never required.
local capabilities = Core.capabilities(maki.session, {
  commands = true,
  command = runCommand ~= nil,
  models = type(modelApi.available) == "function",
  model_set = perSession and type(modelApi.set) == "function",
  skills = true,
  plugins = true,
  -- Ships with the maki whose prompt takes images; nothing to probe.
  images = true,
  question_slot = questionSlot,
})
local cancelSession = maki.session.cancel
local detachSession = type(maki.session.detach) == "function" and maki.session.detach or nil

-- No session id wakes every mirror rather than guessing which one changed.
local function wake(sessionId)
  if sessionId then
    mirrorDirty[sessionId] = true
    return
  end
  for id in pairs(liveIds) do
    mirrorDirty[id] = true
  end
end

local controller = Core.controller({
  -- Raises (bad image, non-vision model) surface through the controller's pcall.
  prompt = function(sessionId, text, force, images)
    local status, err = maki.session.prompt(text, {
      session = sessionId,
      force = force or nil,
      images = images and #images > 0 and images or nil,
    })
    -- A maki whose prompt ignores force still queued it; detach forces it.
    if
      force
      and status == "queued"
      and detachSession
      and detachSession({ session = sessionId })
    then
      return "forced"
    end
    return status, err
  end,
  messages = function(sessionId)
    return maki.session.messages({ session = sessionId, last = 8 })
  end,
  answer_permission = function(requestId, decision, guidance)
    return maki.session.answer_permission(requestId, { decision = decision, guidance = guidance })
  end,
  permission_open = permissions.has,
  answer_question = (answerQuestion and function(sessionId, toolId, answer)
    return answerQuestion(toolId, answer, { session = sessionId })
  end) or (questionSlot and function(sessionId, _toolId, answer)
    return questions.answer(sessionId, answer)
  end) or nil,
  cancel = cancelSession and function(sessionId)
    return cancelSession({ session = sessionId })
  end or nil,
  detach = detachSession and function(sessionId)
    return detachSession({ session = sessionId })
  end or nil,
  capabilities = function()
    return capabilities
  end,
  touched = wake,
  empty = EMPTY_SESSIONS,
  allow = allowSet,
  commands = perSession and maki.api.list_commands or nil,
  run_command = runCommand and function(sessionId, cmdline)
    if perSession then
      return runCommand(cmdline, { session = sessionId })
    end
    if not isFocused(sessionId) then
      return nil, "this maki runs commands in the focused session only"
    end
    return runCommand(cmdline)
  end or nil,
  model_get = modelGet,
  models_available = capabilities.models and modelApi.available or nil,
  model_info = type(modelApi.info) == "function" and modelApi.info or nil,
  model_set = capabilities.model_set and function(sessionId, change)
    local spec = change.spec
    if not spec then
      local current = modelApi.get({ session = sessionId })
      spec = current and current.spec
    end
    return modelApi.set(
      { spec = spec, thinking = change.thinking, fast = change.fast },
      { session = sessionId, persist = false }
    )
  end or nil,
  skills = function(sessionId)
    local read = maki.session.read({ session = sessionId })
    return SkillsCore.list(read and read.cwd or nil)
  end,
  plugins = collectPlugins,
})

local function pollLoop(sessionId)
  local path = "/api/relay/poll?session=" .. sessionId .. "&timeout=" .. (POLL_HOLD_SEC * 1000)
  while liveIds[sessionId] do
    while idle() and liveIds[sessionId] do
      maki.async.sleep(PAUSE_STEP_MS)
    end
    if not liveIds[sessionId] then
      break
    end
    -- A poll already open when pausing still delivers its frames.
    local res, err = hubRequest(path, "GET", nil, POLL_HOLD_SEC + 15)
    if not res then
      log("debug", "poll failed: " .. tostring(err))
      maki.async.sleep(2000)
    elseif res.status == 401 or res.status == 403 then
      break
    elseif res.status >= 400 then
      -- 404: the hub has not seen this session's heartbeat yet, or restarted.
      maki.async.sleep(2000)
    else
      local ok, decoded = pcall(maki.json.decode, res.body)
      local frames = ok and type(decoded) == "table" and decoded.frames or {}
      local replies = {}
      for _, frame in ipairs(frames) do
        for _, out in ipairs(controller.handle(sessionId, frame)) do
          replies[#replies + 1] = out
        end
      end
      postFrames(sessionId, replies)
    end
  end
  polling[sessionId] = nil
  postFrames(sessionId, controller.drop(sessionId))
end

-- One mirror push if the body changed (or the resend is due). Returns the
-- wait before the next one, or nil when the hub refused the token.
local function mirrorOnce(sessionId)
  local messages, err = maki.session.messages({ session = sessionId, last = Core.MIRROR_LAST })
  if not messages then
    log("debug", "mirror read failed: " .. tostring(err))
    return Core.MIRROR_IDLE_MS
  end
  local todos = todoTracker.observe(sessionId, messages, function()
    return maki.session.messages({ session = sessionId })
  end, EMPTY_SESSIONS)
  local body = Core.mirror_body(
    sessionId,
    messages,
    permissions.open(sessionId),
    capabilities,
    EMPTY_SESSIONS,
    todos
  )
  local wait = Core.mirror_interval(liveStatus[sessionId], body)
  local encoded = maki.json.encode(body)
  local now = os.time()
  if not mirrorGate.due(sessionId, encoded, now) then
    return wait
  end
  local res, reqErr = hubRequest("/api/relay/mirror", "POST", encoded, 10)
  if res and (res.status == 401 or res.status == 403) then
    return nil
  end
  if not res or res.status >= 400 then
    -- 404: the hub restarted or has not seen the heartbeat yet. Resend the
    -- same body, at the idle pace so a down hub is not hit every 700ms.
    mirrorGate.invalidate(sessionId)
    log("debug", "mirror failed: " .. tostring(reqErr or res.status))
    return Core.MIRROR_IDLE_MS
  end
  mirrorGate.sent(sessionId, encoded, now)
  return wait
end

-- maki.async has no wakeup primitive, so the wait is short sleeps that end
-- early once an event or a hub action marks the session dirty.
local function mirrorLoop(sessionId)
  while liveIds[sessionId] do
    while idle() and liveIds[sessionId] do
      maki.async.sleep(PAUSE_STEP_MS)
    end
    if not liveIds[sessionId] then
      break
    end
    -- Cleared before reading, so an event landing mid-push triggers another.
    mirrorDirty[sessionId] = nil
    local wait = mirrorOnce(sessionId)
    if not wait then
      break
    end
    local waited = 0
    while waited < wait and liveIds[sessionId] and not mirrorDirty[sessionId] do
      maki.async.sleep(MIRROR_STEP_MS)
      waited = waited + MIRROR_STEP_MS
    end
  end
  mirroring[sessionId] = nil
  mirrorDirty[sessionId] = nil
  mirrorGate.invalidate(sessionId)
  todoTracker.forget(sessionId)
end

local function spawnLoop(running, id, loop, what)
  if running[id] then
    return
  end
  running[id] = true
  maki.async.spawn(function()
    local ok, err = pcall(loop, id)
    if not ok then
      running[id] = nil
      log("warn", what .. " loop raised: " .. tostring(err))
    end
  end)
end

local function trackSessions(list)
  local now, status = {}, {}
  for _, s in ipairs(list) do
    now[s.id] = true
    status[s.id] = s.status
  end
  liveIds = now
  liveStatus = status
  permissions.retain(now)
  if not controlEnabled then
    return
  end
  for id in pairs(now) do
    spawnLoop(polling, id, pollLoop, "poll")
    spawnLoop(mirroring, id, mirrorLoop, "mirror")
  end
end

-- Every event below makes the mirror push now. They all carry session_id at
-- the pinned maki; one without it wakes every session.
local function onEvent(name, handler)
  local ok, err = pcall(maki.api.create_autocmd, name, {
    callback = function(ev)
      local data = ev.data or {}
      if handler then
        handler(data)
      end
      wake(data.session_id)
    end,
  })
  if not ok then
    log("debug", "no " .. name .. " event: " .. tostring(err))
  end
end

if controlEnabled then
  onEvent("PermissionRequested", permissions.add)
  onEvent("PermissionResolved", function(data)
    permissions.resolve(data.request_id)
  end)
  onEvent("SessionStatusChanged", function(data)
    if data.session_id then
      liveStatus[data.session_id] = data.status
    end
  end)
  for _, name in ipairs({ "ToolStart", "ToolDone", "QuestionAsked", "QuestionResolved" }) do
    onEvent(name)
  end

  -- Races the user: whichever of the form and the hub answers first wins.
  -- The hub's answer closes the window, which the form reads as a dismiss.
  if questionSlot then
    maki.api.set_slot("question.form", function(prev, qs, ev, onOpen)
      local sessionId = type(ev) == "table" and ev.session or nil
      local win, reply
      local token = questions.open(sessionId, function(answer)
        reply = answer
        if win then
          win:close()
        end
      end)
      maki.async.on_cancel(function()
        questions.close(token)
      end)
      wake(sessionId)
      local ok, result = pcall(prev, qs, ev, function(w)
        win = w
        if reply then
          w:close()
        end
        if onOpen then
          onOpen(w)
        end
      end)
      questions.close(token)
      wake(sessionId)
      if not ok then
        error(result, 0)
      end
      return reply or result
    end)
  end

  maki.api.create_autocmd("TurnEnd", {
    callback = function(ev)
      local data = ev.data or {}
      local sessionId = data.session_id
      wake(sessionId)
      if not sessionId or controller.pending(sessionId) == 0 then
        return
      end
      maki.async.spawn(function()
        postFrames(sessionId, controller.turn_end(sessionId, data.reason))
      end)
    end,
  })
end

-- The fallback tails maki.log, so the summary is refreshed only this often.
local PLUGINS_SUMMARY_SEC = 60
local pluginsSummary, pluginsSummaryAt = nil, nil

local function currentPluginsSummary()
  local now = os.time()
  if not pluginsSummaryAt or now - pluginsSummaryAt >= PLUGINS_SUMMARY_SEC then
    pluginsSummaryAt = now
    local ok, res = pcall(collectPlugins)
    pluginsSummary = ok and PluginsCore.summary(res.plugins) or nil
  end
  return pluginsSummary
end

-- Returns true when retrying is pointless (bad token, host disabled).
local function beat()
  local cwd = maki.uv.cwd()
  local list = snapshots() or {}
  local body = Core.heartbeat_body({
    id = instanceId,
    host = maki.uv.os_getenv("HOSTNAME"),
    cwd = cwd,
    branch = gitBranch(cwd),
  }, list, EMPTY_SESSIONS, currentPluginsSummary())

  local res, err = hubRequest("/api/relay/heartbeat", "POST", body, 10)
  lastBeat =
    { at = os.time(), status = res and res.status or nil, err = not res and tostring(err) or nil }
  if res and res.status < 400 then
    -- Polls start only after the hub knows the session, or they would 404.
    trackSessions(list)
    failures = 0
  else
    failures = failures + 1
  end

  if not res then
    if healthy then
      log("warn", "heartbeat to " .. url .. " failed: " .. tostring(err))
      healthy = false
    end
    return false
  end
  if res.status == 401 or res.status == 403 then
    log(
      "error",
      "hub refused the token (HTTP " .. res.status .. "); not retrying until /remote-control toggle"
    )
    return true
  end
  if res.status >= 400 then
    if healthy then
      log("warn", "hub answered HTTP " .. res.status .. ": " .. res.body:sub(1, 200))
      healthy = false
    end
    return false
  end
  if not healthy then
    log("info", "heartbeat recovered")
    healthy = true
  end
  return false
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

runtime = {
  state = function()
    local s = baseState()
    s.opted_in = true
    s.paused = paused
    s.token_refused = tokenRefused
    s.interval = intervalSec
    s.last_beat = lastBeat
    s.failures = failures
    s.live = countKeys(liveIds)
    s.polling = countKeys(polling)
    s.mirroring = countKeys(mirroring)
    return s
  end,
  -- Pauses a running remote; otherwise resumes it, retrying a refused token.
  toggle = function()
    if not idle() then
      paused = true
      log("info", "paused by /remote-control")
      return "remote paused: the hub marks this maki offline after 90s"
    end
    local retry = tokenRefused
    paused, tokenRefused = false, false
    log(
      "info",
      retry and "resumed by /remote-control, retrying the token" or "resumed by /remote-control"
    )
    return retry and "remote resumed: retrying the token" or "remote resumed"
  end,
}

maki.async.spawn(function()
  while true do
    if idle() then
      maki.async.sleep(PAUSE_STEP_MS)
    else
      local ok, stop = pcall(beat)
      if not ok then
        failures = failures + 1
        log("warn", "heartbeat raised: " .. tostring(stop))
      elseif stop then
        tokenRefused = true
      end
      -- Short steps, so a resume beats within PAUSE_STEP_MS.
      local waited = 0
      while waited < intervalSec * 1000 and not idle() do
        maki.async.sleep(PAUSE_STEP_MS)
        waited = waited + PAUSE_STEP_MS
      end
    end
  end
end)
