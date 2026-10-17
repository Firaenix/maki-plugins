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

local Core = require("remote_core")

local url = (maki.uv.os_getenv("MAKI_HUB_URL") or ""):gsub("/+$", "")
local token = maki.uv.os_getenv("MAKI_HUB_TOKEN")
if url == "" or not token or token == "" then
  return
end
local intervalSec = math.max(tonumber(maki.uv.os_getenv("MAKI_HUB_INTERVAL")) or 5, 1)
local controlEnabled = maki.uv.os_getenv("MAKI_HUB_CONTROL") ~= "0"
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

-- One beat's worth of sessions, or nil when this process has no interactive UI.
local function snapshots()
  local live, err = maki.session.live()
  if not live then
    if err ~= "no interactive UI attached" then
      maki.log.warn("remote: session list failed: " .. tostring(err))
    end
    return nil
  end
  local out = {}
  for _, s in ipairs(live) do
    out[#out + 1] = Core.snapshot(s, maki.session.read({ session = s.id }))
  end
  return out
end

local healthy = true

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
    maki.log.warn("remote: posting frames failed: " .. tostring(err or res.status))
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
-- cancel and answer_question come from a newer maki; detected, never required.
local capabilities = Core.capabilities(maki.session)
local answerQuestion = maki.session.answer_question
local cancelSession = maki.session.cancel

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
  prompt = function(sessionId, text)
    return maki.session.prompt(text, { session = sessionId })
  end,
  messages = function(sessionId)
    return maki.session.messages({ session = sessionId, last = 8 })
  end,
  answer_permission = function(requestId, decision, guidance)
    return maki.session.answer_permission(requestId, { decision = decision, guidance = guidance })
  end,
  permission_open = permissions.has,
  answer_question = answerQuestion and function(sessionId, toolId, answer)
    return answerQuestion(toolId, answer, { session = sessionId })
  end or nil,
  cancel = cancelSession and function(sessionId)
    return cancelSession({ session = sessionId })
  end or nil,
  capabilities = function()
    return capabilities
  end,
  touched = wake,
})

local function pollLoop(sessionId)
  local path = "/api/relay/poll?session=" .. sessionId .. "&timeout=" .. (POLL_HOLD_SEC * 1000)
  while liveIds[sessionId] do
    local res, err = hubRequest(path, "GET", nil, POLL_HOLD_SEC + 15)
    if not res then
      maki.log.debug("remote: poll failed: " .. tostring(err))
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
    maki.log.debug("remote: mirror read failed: " .. tostring(err))
    return Core.MIRROR_IDLE_MS
  end
  local body =
    Core.mirror_body(sessionId, messages, permissions.open(sessionId), capabilities, EMPTY_SESSIONS)
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
    maki.log.debug("remote: mirror failed: " .. tostring(reqErr or res.status))
    return Core.MIRROR_IDLE_MS
  end
  mirrorGate.sent(sessionId, encoded, now)
  return wait
end

-- maki.async has no wakeup primitive, so the wait is short sleeps that end
-- early once an event or a hub action marks the session dirty.
local function mirrorLoop(sessionId)
  while liveIds[sessionId] do
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
      maki.log.warn("remote: " .. what .. " loop raised: " .. tostring(err))
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
    maki.log.debug("remote: no " .. name .. " event: " .. tostring(err))
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

-- Returns true when retrying is pointless (bad token, host disabled).
local function beat()
  local cwd = maki.uv.cwd()
  local list = snapshots() or {}
  local body = Core.heartbeat_body({
    id = instanceId,
    host = maki.uv.os_getenv("HOSTNAME"),
    cwd = cwd,
    branch = gitBranch(cwd),
  }, list, EMPTY_SESSIONS)

  local res, err = hubRequest("/api/relay/heartbeat", "POST", body, 10)
  if res and res.status < 400 then
    -- Polls start only after the hub knows the session, or they would 404.
    trackSessions(list)
  end

  if not res then
    if healthy then
      maki.log.warn("remote: heartbeat to " .. url .. " failed: " .. tostring(err))
      healthy = false
    end
    return false
  end
  if res.status == 401 or res.status == 403 then
    maki.log.error("remote: hub refused the token (HTTP " .. res.status .. "); not retrying")
    return true
  end
  if res.status >= 400 then
    if healthy then
      maki.log.warn("remote: hub answered HTTP " .. res.status .. ": " .. res.body:sub(1, 200))
      healthy = false
    end
    return false
  end
  if not healthy then
    maki.log.info("remote: heartbeat recovered")
    healthy = true
  end
  return false
end

maki.async.spawn(function()
  while true do
    local ok, stop = pcall(beat)
    if not ok then
      maki.log.warn("remote: heartbeat raised: " .. tostring(stop))
    elseif stop then
      return
    end
    maki.async.sleep(intervalSec * 1000)
  end
end)
