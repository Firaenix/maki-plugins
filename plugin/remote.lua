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
-- frames (a small ACP subset, see remote_core) and posts answers back, so the
-- hub can prompt this maki. MAKI_HUB_CONTROL=0 keeps the plugin report-only.

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
    body = body and maki.json.encode(body) or nil,
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

local controller = Core.controller({
  prompt = function(sessionId, text)
    return maki.session.prompt(text, { session = sessionId })
  end,
  messages = function(sessionId)
    return maki.session.messages({ session = sessionId, last = 8 })
  end,
})

-- Sessions in the latest beat; a poll loop ends once its session leaves.
local liveIds = {}
local polling = {}

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

local function trackSessions(list)
  local now = {}
  for _, s in ipairs(list) do
    now[s.id] = true
  end
  liveIds = now
  if not controlEnabled then
    return
  end
  for id in pairs(now) do
    if not polling[id] then
      polling[id] = true
      maki.async.spawn(function()
        local ok, err = pcall(pollLoop, id)
        if not ok then
          polling[id] = nil
          maki.log.warn("remote: poll loop raised: " .. tostring(err))
        end
      end)
    end
  end
end

if controlEnabled then
  maki.api.create_autocmd("TurnEnd", {
    callback = function(ev)
      local data = ev.data or {}
      local sessionId = data.session_id
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
