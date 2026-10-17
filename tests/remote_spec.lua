local th = require("./th")
local Core = require("../lua/remote_core")

local case, eq, same = th.case, th.eq, th.same

local function session(id, focused)
  return { id = id, focused = focused == true }
end

-- Instance identity

case("instance ids differ between draws and carry the timestamp", function()
  local a = Core.instance_id(1700000000, function()
    return 255
  end)
  local b = Core.instance_id(1700000000, function()
    return 256
  end)
  eq(a, "1700000000-ff")
  th.eq(a == b, false, "two draws must not collide")
end)

-- git HEAD

case("parse_head unwraps a branch ref", function()
  eq(Core.parse_head("ref: refs/heads/main\n"), "main")
end)

case("parse_head keeps slashes in branch names", function()
  eq(Core.parse_head("ref: refs/heads/feature/hub-v2"), "feature/hub-v2")
end)

case("parse_head shortens a detached head", function()
  eq(Core.parse_head("  0123456789abcdef0123456789abcdef01234567  \n"), "0123456")
end)

case("parse_head rejects junk", function()
  eq(Core.parse_head(""), nil)
  eq(Core.parse_head(nil), nil)
  eq(Core.parse_head("deadbeef"), nil) -- too short to be a sha
  eq(Core.parse_head("ref: refs/heads/"), nil)
  eq(Core.parse_head("ref: refs/heads/main extra"), nil)
end)

-- Snapshots

case("a snapshot merges live state with the full read", function()
  local snap = Core.snapshot(
    { id = "s1", title = "fix auth", status = "working", focused = true },
    {
      cwd = "/repo",
      model = "opus",
      mode = "build",
      cost = 0.4,
      context_size = 51000,
      context_window = 200000,
    }
  )
  same(snap, {
    id = "s1",
    title = "fix auth",
    cwd = "/repo",
    model = "opus",
    mode = "build",
    status = "working",
    cost = 0.4,
    context_size = 51000,
    context_window = 200000,
    focused = true,
  })
end)

case("a session closed mid-beat still reports its live fields", function()
  local snap = Core.snapshot({ id = "s1", title = "t", status = "idle" }, nil)
  eq(snap.id, "s1")
  eq(snap.model, nil)
  eq(snap.focused, false)
end)

-- Heartbeat body

case("an empty session list becomes the injected empty array", function()
  local body = Core.heartbeat_body({ id = "i1" }, {}, "EMPTY")
  eq(body.sessions, "EMPTY")
end)

case("the body carries the instance through untouched", function()
  local instance = { id = "i1", host = "roark", cwd = "/x", branch = "main" }
  local body = Core.heartbeat_body(instance, { session("s1", true) }, "EMPTY")
  same(body.instance, instance)
  eq(#body.sessions, 1)
end)

case("focused sessions sort ahead of background ones", function()
  local list = { session("a", false), session("b", true), session("c", false), session("d", true) }
  local body = Core.heartbeat_body({ id = "i1" }, list, "EMPTY")
  local ids = {}
  for i, s in ipairs(body.sessions) do
    ids[i] = s.id
  end
  eq(ids[1] .. ids[2] == "bd" or ids[1] .. ids[2] == "db", true)
  eq(ids[3] .. ids[4] == "ac" or ids[3] .. ids[4] == "ca", true)
end)

case("the cap keeps the focused session and drops the rest", function()
  local list = {}
  for i = 1, Core.MAX_SESSIONS + 5 do
    list[i] = session("s" .. i, false)
  end
  list[Core.MAX_SESSIONS + 5].focused = true
  local body = Core.heartbeat_body({ id = "i1" }, list, "EMPTY")
  eq(#body.sessions, Core.MAX_SESSIONS)
  eq(body.sessions[1].focused, true)
end)

case("the cap does not mutate the caller's list", function()
  local list = {}
  for i = 1, Core.MAX_SESSIONS + 2 do
    list[i] = session("s" .. i, false)
  end
  Core.heartbeat_body({ id = "i1" }, list, "EMPTY")
  eq(#list, Core.MAX_SESSIONS + 2)
end)

-- Control

local function fake_effects()
  local fx = { prompts = {}, transcript = {}, refuse = nil }
  fx.prompt = function(sid, text)
    if fx.refuse then
      return nil, fx.refuse
    end
    fx.prompts[#fx.prompts + 1] = { sid, text }
    return "started"
  end
  fx.messages = function()
    return fx.transcript
  end
  return fx
end

local function prompt_frame(id, text)
  return {
    jsonrpc = "2.0",
    id = id,
    method = "session/prompt",
    params = { sessionId = "s1", prompt = { { type = "text", text = text } } },
  }
end

case("initialize answers capabilities immediately", function()
  local ctl = Core.controller(fake_effects())
  local out = ctl.handle("s1", { jsonrpc = "2.0", id = 1, method = "initialize" })
  eq(#out, 1)
  eq(out[1].id, 1)
  eq(out[1].result.protocolVersion, Core.PROTOCOL_VERSION)
  eq(out[1].result.agentCapabilities.loadSession, true)
end)

case("session/load adopts the relayed session", function()
  local ctl = Core.controller(fake_effects())
  local out = ctl.handle("s1", { jsonrpc = "2.0", id = "a", method = "session/load", params = {} })
  same(out[1].result, { sessionId = "s1" })
end)

case("unknown methods error, notifications are silent", function()
  local ctl = Core.controller(fake_effects())
  eq(ctl.handle("s1", { jsonrpc = "2.0", id = 2, method = "nope" })[1].error.code, -32601)
  eq(#ctl.handle("s1", { jsonrpc = "2.0", method = "session/cancel" }), 0)
  eq(#ctl.handle("s1", "garbage"), 0)
end)

case("a prompt is forwarded and answered on turn end with the reply text", function()
  local fx = fake_effects()
  local ctl = Core.controller(fx)
  eq(#ctl.handle("s1", prompt_frame(7, "hello")), 0)
  same(fx.prompts, { { "s1", "hello" } })
  eq(ctl.pending("s1"), 1)
  fx.transcript = {
    { role = "user", kind = "turn", content = { { type = "text", text = "hello" } } },
    { role = "assistant", kind = "turn", content = { { type = "text", text = "ECHO: hello" } } },
  }
  local out = ctl.turn_end("s1", "finished")
  eq(#out, 2)
  eq(out[1].method, "session/update")
  eq(out[1].params.update.content.text, "ECHO: hello")
  eq(out[2].id, 7)
  eq(out[2].result.stopReason, "end_turn")
  eq(ctl.pending("s1"), 0)
end)

case("turn end without a waiting prompt sends nothing", function()
  local ctl = Core.controller(fake_effects())
  eq(ctl.turn_end("s1", "finished"), nil)
end)

case("prompts resolve in arrival order and map stop reasons", function()
  local ctl = Core.controller(fake_effects())
  ctl.handle("s1", prompt_frame(1, "a"))
  ctl.handle("s1", prompt_frame(2, "b"))
  eq(ctl.turn_end("s1", "cancelled")[1].id, 1)
  local second = ctl.turn_end("s1", "max_turns")
  eq(second[1].id, 2)
  eq(second[1].result.stopReason, "max_turn_requests")
end)

case("a refused or empty prompt errors right away", function()
  local fx = fake_effects()
  local ctl = Core.controller(fx)
  eq(
    ctl.handle("s1", { jsonrpc = "2.0", id = 3, method = "session/prompt", params = {} })[1].error.code,
    -32602
  )
  fx.refuse = "no such session"
  eq(ctl.handle("s1", prompt_frame(4, "x"))[1].error.code, -32000)
  eq(ctl.pending("s1"), 0)
end)

case("dropping a session fails its open prompts", function()
  local ctl = Core.controller(fake_effects())
  ctl.handle("s1", prompt_frame(9, "x"))
  local out = ctl.drop("s1")
  eq(#out, 1)
  eq(out[1].id, 9)
  eq(ctl.pending("s1"), 0)
end)

case("assistant text stops at the newest user turn", function()
  eq(
    Core.assistant_text({
      { role = "assistant", kind = "turn", content = { { type = "text", text = "old" } } },
      { role = "user", kind = "turn", content = { { type = "text", text = "new q" } } },
    }),
    nil
  )
  eq(
    Core.assistant_text({
      { role = "assistant", kind = "turn", content = { { type = "tool_use" } } },
      {
        role = "assistant",
        kind = "turn",
        content = {
          { type = "thinking", text = "t" },
          { type = "text", text = "A" },
          { type = "text", text = "B" },
        },
      },
    }),
    "AB"
  )
end)

case("prompt text joins text blocks and accepts a bare string", function()
  eq(
    Core.prompt_text({
      prompt = { { type = "text", text = "a" }, { type = "image" }, { type = "text", text = "b" } },
    }),
    "a\nb"
  )
  eq(Core.prompt_text({ prompt = "plain" }), "plain")
  eq(Core.prompt_text({ prompt = {} }), nil)
end)

th.report()
