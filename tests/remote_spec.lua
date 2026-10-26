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

case("a snapshot carries the thinking level when known", function()
  eq(Core.snapshot({ id = "s1" }, nil, "high").thinking, "high")
  eq(Core.snapshot({ id = "s1" }, nil, nil).thinking, nil)
  eq(Core.snapshot({ id = "s1" }, nil, 5).thinking, nil)
end)

case("the heartbeat body carries plugins_summary next to sessions", function()
  local body = Core.heartbeat_body({ id = "i" }, {}, "EMPTY", { total = 3, errors = 1 })
  same(body.plugins_summary, { total = 3, errors = 1 })
  eq(body.sessions, "EMPTY")
  eq(Core.heartbeat_body({ id = "i" }, {}, "EMPTY").plugins_summary, nil)
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
  fx.prompt = function(sid, text, _, images)
    if fx.refuse then
      return nil, fx.refuse
    end
    fx.prompts[#fx.prompts + 1] = { sid, text, images }
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

local PNG = { media_type = "image/png", data = "iVBORw0KGgo=" }

case("session/prompt relays image blocks, with or without text", function()
  local fx = fake_effects()
  local ctl = Core.controller(fx)
  local function frame(id, blocks)
    return { jsonrpc = "2.0", id = id, method = "session/prompt", params = { prompt = blocks } }
  end
  local img = { type = "image", mimeType = "image/png", data = PNG.data }
  eq(#ctl.handle("s1", frame(1, { { type = "text", text = "look" }, img })), 0)
  eq(#ctl.handle("s1", frame(2, { img })), 0)
  same(fx.prompts, { { "s1", "look", { PNG } }, { "s1", "", { PNG } } })
  local bad = { type = "image", mimeType = "image/bmp", data = PNG.data }
  eq(ctl.handle("s1", frame(3, { { type = "text", text = "x" }, bad }))[1].error.code, -32602)
  eq(ctl.pending("s1"), 2)
end)

-- maki/* actions

local function full_effects()
  local fx = fake_effects()
  fx.calls = {}
  fx.dirty = {}
  fx.landed = true
  fx.open_requests = { [5] = "s1" }
  fx.answer_permission = function(request_id, decision, guidance)
    fx.calls[#fx.calls + 1] = { "permission", request_id, decision, guidance }
    return fx.landed
  end
  fx.permission_open = function(sid, request_id)
    return fx.open_requests[request_id] == sid
  end
  fx.answer_question = function(sid, tool_id, answer)
    fx.calls[#fx.calls + 1] = { "question", sid, tool_id, answer }
    return fx.landed
  end
  fx.cancel = function(sid)
    if fx.refuse then
      return nil, fx.refuse
    end
    fx.calls[#fx.calls + 1] = { "cancel", sid }
    return fx.cancel_reply or "cancelled"
  end
  fx.capabilities = function()
    return Core.capabilities({ cancel = fx.cancel, answer_question = fx.answer_question })
  end
  fx.touched = function(sid)
    fx.dirty[#fx.dirty + 1] = sid
  end
  return fx
end

local function call(ctl, method, params)
  return ctl.handle("s1", { jsonrpc = "2.0", id = 1, method = method, params = params })[1]
end

case("maki/prompt answers with the start status right away", function()
  local fx = full_effects()
  local ctl = Core.controller(fx)
  local out = call(ctl, "maki/prompt", { text = "hi" })
  same(out.result, { status = "started" })
  same(fx.prompts, { { "s1", "hi" } })
  same(fx.dirty, { "s1" })
  eq(ctl.pending("s1"), 0, "no TurnEnd answer is owed")
end)

case("maki/prompt rejects empty text and reports a refusal", function()
  local fx = full_effects()
  local ctl = Core.controller(fx)
  eq(call(ctl, "maki/prompt", { text = "  " }).error.code, -32602)
  eq(call(ctl, "maki/prompt", {}).error.code, -32602)
  eq(call(ctl, "maki/prompt", nil).error.code, -32602)
  fx.refuse = "busy"
  eq(call(ctl, "maki/prompt", { text = "x" }).error.code, -32000)
  eq(#fx.dirty, 0)
end)

case("maki/prompt forwards images and allows blank text with them", function()
  local fx = full_effects()
  local ctl = Core.controller(fx)
  same(call(ctl, "maki/prompt", { text = "see", images = { PNG } }).result, { status = "started" })
  same(call(ctl, "maki/prompt", { text = " ", images = { PNG } }).result, { status = "started" })
  same(call(ctl, "maki/prompt", { text = "plain", images = {} }).result, { status = "started" })
  same(fx.prompts, { { "s1", "see", { PNG } }, { "s1", " ", { PNG } }, { "s1", "plain" } })
end)

case("maki/prompt rejects bad images", function()
  local fx = full_effects()
  local ctl = Core.controller(fx)
  local function code(params)
    return call(ctl, "maki/prompt", params).error.code
  end
  eq(code({ text = " " }), -32602, "blank text needs images")
  eq(code({ text = "", images = {} }), -32602, "an empty list is no images")
  eq(code({ text = "x", images = { { media_type = "image/bmp", data = "AA==" } } }), -32602)
  eq(code({ text = "x", images = { { media_type = "image/png", data = "" } } }), -32602)
  eq(code({ text = "x", images = { { media_type = "image/png", data = "data:x" } } }), -32602)
  eq(code({ text = "x", images = { "AA==" } }), -32602)
  eq(code({ text = "x", images = PNG }), -32602, "an object is not an array")
  local many = {}
  for i = 1, Core.MAX_IMAGES + 1 do
    many[i] = PNG
  end
  eq(code({ text = "x", images = many }), -32602)
  eq(#fx.prompts, 0)
  many[#many] = nil
  same(call(ctl, "maki/prompt", { text = "x", images = many }).result, { status = "started" })
end)

case("maki/prompt reports a raised image refusal", function()
  local fx = full_effects()
  fx.prompt = function()
    error("model does not support images")
  end
  local out = call(Core.controller(fx), "maki/prompt", { text = "x", images = { PNG } })
  eq(out.error.code, -32000)
  eq(out.error.message:find("model does not support images", 1, true) ~= nil, true)
end)

case("maki/answer_permission forwards the decision and reports landing", function()
  local fx = full_effects()
  local ctl = Core.controller(fx)
  same(
    call(ctl, "maki/answer_permission", { request_id = 5, decision = "deny", guidance = "no" }).result,
    {
      landed = true,
    }
  )
  same(fx.calls[1], { "permission", 5, "deny", "no" })
  same(fx.dirty, { "s1" })
  fx.landed = false
  same(call(ctl, "maki/answer_permission", { request_id = 5, decision = "allow" }).result, {
    landed = false,
  })
end)

case("maki/answer_permission validates its params", function()
  local fx = full_effects()
  local ctl = Core.controller(fx)
  eq(
    call(ctl, "maki/answer_permission", { request_id = 5, decision = "always" }).error.code,
    -32602
  )
  eq(call(ctl, "maki/answer_permission", { request_id = 5, decision = 1 }).error.code, -32602)
  eq(call(ctl, "maki/answer_permission", { decision = "allow" }).error.code, -32602)
  eq(
    call(ctl, "maki/answer_permission", { request_id = 5, decision = "deny", guidance = {} }).error.code,
    -32602
  )
  eq(call(ctl, "maki/answer_permission", { request_id = 6, decision = "allow" }).error.code, -32602)
  eq(#fx.calls, 0)
end)

case("maki/answer_permission turns a raised effect into a refusal", function()
  local fx = full_effects()
  fx.answer_permission = function()
    error("permission denied: needs every permission")
  end
  local ctl = Core.controller(fx)
  eq(call(ctl, "maki/answer_permission", { request_id = 5, decision = "allow" }).error.code, -32000)
end)

case("maki/answer_question passes answers or a dismissal through", function()
  local fx = full_effects()
  local ctl = Core.controller(fx)
  local answers = { { "Yes" }, { "A", "B" } }
  same(
    call(ctl, "maki/answer_question", { tool_id = "q1", answers = answers }).result,
    { landed = true }
  )
  same(fx.calls[1], { "question", "s1", "q1", { answers = answers } })
  same(
    call(ctl, "maki/answer_question", { tool_id = "q1", dismiss = true }).result,
    { landed = true }
  )
  same(fx.calls[2], { "question", "s1", "q1", { dismiss = true } })
  same(fx.dirty, { "s1", "s1" })
end)

case("maki/answer_question validates its params", function()
  local ctl = Core.controller(full_effects())
  eq(call(ctl, "maki/answer_question", { answers = { { "a" } } }).error.code, -32602)
  eq(call(ctl, "maki/answer_question", { tool_id = "q1" }).error.code, -32602)
  eq(call(ctl, "maki/answer_question", { tool_id = "q1", answers = {} }).error.code, -32602)
  eq(call(ctl, "maki/answer_question", { tool_id = "q1", answers = { "a" } }).error.code, -32602)
  eq(call(ctl, "maki/answer_question", { tool_id = "q1", answers = { { 1 } } }).error.code, -32602)
end)

case("maki/answer_question and maki/cancel need the newer maki", function()
  local fx = full_effects()
  fx.answer_question, fx.cancel = nil, nil
  local ctl = Core.controller(fx)
  local q = call(ctl, "maki/answer_question", { tool_id = "q1", dismiss = true })
  eq(q.error.code, -32601)
  eq(q.error.message, "not supported by this maki")
  eq(call(ctl, "maki/cancel", {}).error.code, -32601)
end)

case("maki/cancel cancels the relayed session", function()
  local fx = full_effects()
  local ctl = Core.controller(fx)
  same(call(ctl, "maki/cancel", {}).result, { cancelled = true })
  same(fx.calls[1], { "cancel", "s1" })
  same(fx.dirty, { "s1" })
  fx.cancel_reply = "idle"
  same(call(ctl, "maki/cancel", {}).result, { cancelled = false })
  -- Older makis answer a boolean.
  fx.cancel_reply = true
  same(call(ctl, "maki/cancel", {}).result, { cancelled = true })
  fx.refuse = "gone"
  eq(call(ctl, "maki/cancel", {}).error.code, -32000)
end)

local function send_now_effects()
  local fx = full_effects()
  fx.detached = true
  fx.prompt = function(sid, text, force)
    fx.prompts[#fx.prompts + 1] = { sid, text, force }
    return force and "forced" or "queued"
  end
  fx.detach = function(sid)
    if fx.refuse then
      return nil, fx.refuse
    end
    fx.calls[#fx.calls + 1] = { "detach", sid }
    return fx.detached
  end
  return fx
end

case("maki/prompt with force sends now", function()
  local fx = send_now_effects()
  local ctl = Core.controller(fx)
  same(call(ctl, "maki/prompt", { text = "now", force = true }).result, { status = "forced" })
  same(call(ctl, "maki/prompt", { text = "later" }).result, { status = "queued" })
  same(fx.prompts, { { "s1", "now", true }, { "s1", "later", false } })
  same(fx.dirty, { "s1", "s1" })
end)

case("maki/prompt with force needs send now and a boolean", function()
  local fx = send_now_effects()
  local ctl = Core.controller(fx)
  eq(call(ctl, "maki/prompt", { text = "x", force = "yes" }).error.code, -32602)
  fx.detach = nil
  local out = call(ctl, "maki/prompt", { text = "x", force = true })
  eq(out.error.code, -32601)
  eq(#fx.prompts, 0, "an unforceable prompt is not quietly queued")
  same(call(ctl, "maki/prompt", { text = "x", force = false }).result, { status = "queued" })
end)

case("maki/detach forces the queue of the relayed session", function()
  local fx = send_now_effects()
  local ctl = Core.controller(fx)
  same(call(ctl, "maki/detach", {}).result, { detached = true })
  same(fx.calls[1], { "detach", "s1" })
  same(fx.dirty, { "s1" })
  fx.detached = false
  same(call(ctl, "maki/detach", {}).result, { detached = false })
  fx.refuse = "gone"
  eq(call(ctl, "maki/detach", {}).error.code, -32000)
  fx.detach = nil
  eq(call(ctl, "maki/detach", {}).error.code, -32601)
end)

-- Mirror

case("clip leaves short strings and marks what it cut", function()
  eq(Core.clip("abc", 5), "abc")
  eq(Core.clip("abcdefgh", 5), "abcde\n…[clipped 3 bytes]")
  eq(Core.clip(42, 1), 42)
  eq(#Core.clip(string.rep("x", Core.CLIP_BYTES + 10)) > Core.CLIP_BYTES, true)
end)

case("clip never splits a UTF-8 codepoint", function()
  -- "é" is two bytes; a 4-byte cut would land between them.
  eq(Core.clip("abcé fin", 4), "abc\n…[clipped 6 bytes]")
end)

case("clip_value clips nested strings without touching the source", function()
  local input = { command = "abcdefgh", list = { "12345678" }, n = 3 }
  local out = Core.clip_value(input, 4)
  eq(out.command, "abcd\n…[clipped 4 bytes]")
  eq(out.list[1], "1234\n…[clipped 4 bytes]")
  eq(out.n, 3)
  eq(input.command, "abcdefgh")
end)

case("clip_value keeps a table's metatable", function()
  local tag = {}
  local out = Core.clip_value(setmetatable({ "x" }, tag))
  eq(getmetatable(out), tag)
end)

case("clip_value survives a protected metatable and returns empty tables as-is", function()
  local empty = setmetatable({}, { __metatable = false })
  eq(Core.clip_value(empty), empty)
  local out = Core.clip_value(setmetatable({ "abcdef" }, { __metatable = false }), 2)
  eq(out[1], "ab\n…[clipped 4 bytes]")
end)

case("clip_message clips every block kind and tags empty content", function()
  local m = Core.clip_message({
    role = "assistant",
    kind = "turn",
    content = {
      { type = "text", text = "abcdef" },
      { type = "thinking", text = "ghijkl" },
      { type = "tool_use", id = "t1", name = "bash", input = { command = "mnopqr" } },
      { type = "tool_result", tool_use_id = "t1", content = "stuvwx", is_error = false },
      { type = "image", media_type = "image/png" },
    },
  }, "EMPTY", 3)
  eq(m.hidden, false)
  eq(m.content[1].text, "abc\n…[clipped 3 bytes]")
  eq(m.content[2].text, "ghi\n…[clipped 3 bytes]")
  eq(m.content[3].input.command, "mno\n…[clipped 3 bytes]")
  eq(m.content[4].content, "stu\n…[clipped 3 bytes]")
  same(m.content[5], { type = "image", media_type = "image/png" })
  eq(Core.clip_message({ role = "user", kind = "turn", content = {} }, "EMPTY").content, "EMPTY")
end)

local function question_call(id, questions)
  return {
    role = "assistant",
    kind = "turn",
    content = {
      { type = "tool_use", id = id, name = "question", input = { questions = questions } },
    },
  }
end

local function result_for(id)
  return {
    role = "user",
    kind = "turn",
    content = { { type = "tool_result", tool_use_id = id, content = "ok" } },
  }
end

case("open questions are question calls without a result", function()
  local q = {
    question = "Pick",
    header = "H",
    options = { { label = "A", description = "first" }, { label = "B" } },
    multiple = true,
  }
  local open = Core.open_questions({
    question_call("q1", { q }),
    result_for("q1"),
    question_call("q2", { q }),
  }, "EMPTY")
  eq(#open, 1)
  same(open[1], {
    tool_id = "q2",
    questions = {
      {
        question = "Pick",
        header = "H",
        options = { { label = "A", description = "first" }, { label = "B" } },
        multiSelect = true,
      },
    },
  })
end)

case("open questions default their fields and tag empty lists", function()
  eq(
    Core.open_questions({ question_call("q1", { { question = "?" } }), result_for("q1") }, "EMPTY"),
    "EMPTY"
  )
  eq(Core.open_questions(nil, "EMPTY"), "EMPTY")
  local open = Core.open_questions({ question_call("q1", { { question = "?" } }) }, "EMPTY")
  same(
    open[1].questions[1],
    { question = "?", header = "", options = "EMPTY", multiSelect = false }
  )
  eq(Core.open_questions({ question_call("q2", nil) }, "EMPTY")[1].questions, "EMPTY")
end)

case("the permission book tracks open prompts per session in order", function()
  local book = Core.permission_book()
  book.add({ session_id = "s1", request_id = 2, tool = "bash" })
  book.add({ session_id = "s2", request_id = 3, tool = "write" })
  book.add({ session_id = "s1", request_id = 1, tool = "edit" })
  book.add({ request_id = 9 }) -- no session: cannot be attributed
  local open = book.open("s1")
  eq(#open, 2)
  eq(open[1].request_id, 2)
  eq(open[2].request_id, 1)
  eq(book.has("s1", 2), true)
  eq(book.has("s2", 2), false)
  book.resolve(2)
  eq(#book.open("s1"), 1)
  book.retain({ s1 = true })
  eq(#book.open("s2"), 0)
  eq(#book.open("s1"), 1)
end)

case("permission entries join the tool input by tool id", function()
  local messages = {
    {
      role = "assistant",
      kind = "turn",
      content = { { type = "tool_use", id = "t1", name = "bash", input = { command = "abcdef" } } },
    },
  }
  local out = Core.permission_entries({
    {
      request_id = 1,
      tool = "bash",
      scopes = { "rm" },
      tool_id = "t1",
      subagent_id = nil,
      reason = "r",
    },
    { request_id = 2, tool = "bash", scopes = {}, tool_id = "" },
    { request_id = 3, tool = "bash", tool_id = "gone" },
  }, messages, "EMPTY", 3)
  same(out[1], {
    request_id = 1,
    tool = "bash",
    scopes = { "rm" },
    tool_id = "t1",
    reason = "r",
    input = { command = "abc\n…[clipped 3 bytes]" },
  })
  eq(out[2].scopes, "EMPTY")
  eq(out[2].input, nil)
  eq(out[3].input, nil)
  eq(Core.permission_entries({}, messages, "EMPTY"), "EMPTY")
end)

case("question book answers the oldest form open in the session", function()
  local book = Core.question_book()
  local got = {}
  local function deliver(name)
    return function(reply)
      got[#got + 1] = { name, reply }
    end
  end
  local first = book.open("s1", deliver("first"))
  book.open("s2", deliver("other"))
  book.open("s1", deliver("second"))
  eq(book.answer("s1", { answers = { { "Yes" } } }), true)
  same(got[1], { "first", { type = "submit", answers = { { "Yes" } } } })
  eq(book.answer("s1", { dismiss = true }), true)
  same(got[2], { "second", { type = "dismiss" } })
  eq(book.answer("s1", { dismiss = true }), false, "no form left in s1")
  book.close(first)
  eq(#got, 2)
end)

case("question book drops a closed form", function()
  local book = Core.question_book()
  local token = book.open("s1", function()
    error("a closed form must not be answered")
  end)
  book.close(token)
  eq(book.answer("s1", { dismiss = true }), false)
end)

case("capabilities follow the session API that exists", function()
  same(Core.capabilities({}), {
    cancel = false,
    answer_question = false,
    send_now = false,
    permission_decisions = { "allow", "deny" },
    commands = false,
    command = false,
    models = false,
    model_set = false,
    skills = false,
    plugins = false,
    images = false,
  })
  local caps = Core.capabilities({ cancel = print, answer_question = print })
  eq(caps.cancel, true)
  eq(caps.answer_question, true)
  eq(caps.send_now, false)
  eq(Core.capabilities({}, { question_slot = true }).answer_question, true)
  eq(Core.capabilities({ detach = print }).send_now, true)
  eq(Core.capabilities({ detach = true }).send_now, false, "only a function counts")
  eq(Core.capabilities(nil).cancel, false)
end)

case("capabilities advertise the catalog methods that exist", function()
  local caps = Core.capabilities(
    {},
    { commands = true, models = true, model_set = false, plugins = 1 }
  )
  eq(caps.commands, true)
  eq(caps.models, true)
  eq(caps.model_set, false)
  eq(caps.command, false)
  eq(caps.plugins, false, "only a real true counts")
  eq(caps.images, false)
  eq(Core.capabilities({}, { images = true }).images, true)
end)

case("the mirror body keeps the newest window and tags empties", function()
  local messages = {}
  for i = 1, Core.MIRROR_LAST + 2 do
    messages[i] = { role = "user", kind = "turn", content = { { type = "text", text = "m" .. i } } }
  end
  local caps = Core.capabilities({})
  local body = Core.mirror_body("s1", messages, {}, caps, "EMPTY")
  eq(body.session, "s1")
  eq(body.offset, 0)
  eq(#body.messages, Core.MIRROR_LAST)
  eq(body.messages[1].content[1].text, "m3")
  eq(body.permissions, "EMPTY")
  eq(body.questions, "EMPTY")
  eq(body.capabilities, caps)
  local empty = Core.mirror_body("s1", {}, {}, caps, "EMPTY")
  eq(empty.messages, "EMPTY")
end)

case("the mirror body carries open permissions and questions", function()
  local messages = { question_call("q1", { { question = "?" } }) }
  local body = Core.mirror_body(
    "s1",
    messages,
    { { request_id = 4, tool = "bash", tool_id = "x", scopes = {} } },
    Core.capabilities({}),
    "EMPTY"
  )
  eq(#body.permissions, 1)
  eq(body.permissions[1].request_id, 4)
  eq(body.questions[1].tool_id, "q1")
end)

local function todo_call(input)
  return {
    role = "assistant",
    kind = "turn",
    content = { { type = "tool_use", id = "t", name = "todo_write", input = input } },
  }
end

local function filler(n)
  local out = {}
  for i = 1, n do
    out[i] = { role = "user", kind = "turn", content = { { type = "text", text = "m" .. i } } }
  end
  return out
end

local function never_read_all()
  error("read the full history")
end

case("the latest todo_write wins and is normalised", function()
  local window = {
    todo_call({ todos = { { content = "old", status = "pending" } } }),
    todo_call({
      todos = {
        { content = "a", status = "in_progress", priority = "high", extra = 1 },
        { content = "b", status = "bogus" },
        { status = "completed" },
        "junk",
      },
    }),
  }
  local todos = Core.todo_tracker().observe("s1", window, never_read_all, "EMPTY")
  same(todos, {
    { content = "a", status = "in_progress", priority = "high" },
    { content = "b", status = "pending" },
  })
  local cleared = Core.todo_tracker()
    .observe("s1", { todo_call({ todos = {} }) }, never_read_all, "EMPTY")
  eq(cleared, "EMPTY")
end)

case("a todo_write outside the mirror window is still found", function()
  local all = filler(Core.MIRROR_LAST + 5)
  table.insert(all, 1, todo_call({ todos = { { content = "early", status = "completed" } } }))
  local window = { table.unpack(all, #all - Core.MIRROR_LAST + 1) }
  local todos = Core.todo_tracker().observe("s1", window, function()
    return all
  end, "EMPTY")
  same(todos, { { content = "early", status = "completed" } })
end)

case("malformed todo_write inputs are skipped for the previous list", function()
  local window = {
    todo_call({ todos = { { content = "kept", status = "pending" } } }),
    todo_call({ todos = "nope" }),
    todo_call("nope"),
    todo_call(nil),
  }
  same(
    Core.todo_tracker().observe("s1", window, never_read_all, "EMPTY"),
    { { content = "kept", status = "pending" } }
  )
  eq(
    Core.todo_tracker().observe("s1", { todo_call({}) }, function()
      return {}
    end, "EMPTY"),
    nil
  )
end)

case("the full history is read once per session, then the window suffices", function()
  local tracker = Core.todo_tracker()
  local reads = 0
  local function read_all()
    reads = reads + 1
    return { todo_call({ todos = { { content = "early", status = "pending" } } }) }
  end
  local quiet = filler(3)
  eq(tracker.observe("s1", quiet, read_all, "E")[1].content, "early")
  eq(tracker.observe("s1", quiet, read_all, "E")[1].content, "early")
  eq(reads, 1)
  local newer = { todo_call({ todos = { { content = "new", status = "pending" } } }) }
  eq(tracker.observe("s1", newer, read_all, "E")[1].content, "new")
  eq(
    tracker.observe("s1", quiet, read_all, "E")[1].content,
    "new",
    "remembered after scrolling out"
  )
  eq(reads, 1)
  eq(
    tracker.observe("s1", quiet, function()
      return nil
    end, "E")[1].content,
    "new"
  )
  tracker.forget("s1")
  tracker.observe("s1", quiet, read_all, "E")
  eq(reads, 2)
  eq(
    tracker.observe("s2", quiet, function()
      return nil
    end, "E"),
    nil,
    "a failed read is retried"
  )
  eq(tracker.observe("s2", quiet, read_all, "E")[1].content, "early")
end)

case("the mirror body carries todos when given", function()
  local caps = Core.capabilities({})
  local todos = { { content = "a", status = "pending" } }
  eq(Core.mirror_body("s1", {}, {}, caps, "EMPTY", todos).todos, todos)
  eq(Core.mirror_body("s1", {}, {}, caps, "EMPTY").todos, nil)
end)

case("the mirror ticks fast while working or waiting on the user", function()
  eq(Core.mirror_interval("working", { permissions = "E", questions = "E" }), Core.MIRROR_FAST_MS)
  eq(Core.mirror_interval("idle", { permissions = {}, questions = {} }), Core.MIRROR_IDLE_MS)
  eq(Core.mirror_interval("idle", { permissions = { {} }, questions = {} }), Core.MIRROR_FAST_MS)
  eq(
    Core.mirror_interval("needs_input", { permissions = {}, questions = { {} } }),
    Core.MIRROR_FAST_MS
  )
  eq(Core.mirror_interval(nil, nil), Core.MIRROR_IDLE_MS)
end)

case("the mirror gate sends on change, on the resend tick, and after a failure", function()
  local gate = Core.mirror_gate(60)
  eq(gate.due("s1", "a", 100), true)
  gate.sent("s1", "a", 100)
  eq(gate.due("s1", "a", 159), false)
  eq(gate.due("s1", "b", 101), true)
  eq(gate.due("s1", "a", 160), true)
  eq(gate.due("s2", "a", 101), true, "sessions are tracked apart")
  gate.invalidate("s1")
  eq(gate.due("s1", "a", 101), true)
end)

-- Catalog methods: commands, models, skills, plugins

case("the allowlist parses a comma list, defaulting when unset", function()
  local def = Core.parse_allowlist(nil)
  eq(def.compact, true)
  eq(def.skills, true)
  eq(def.yolo, nil)
  same(Core.parse_allowlist(" /Compact, rv ,,bad name,x!"), { compact = true, rv = true })
  same(Core.parse_allowlist(""), {})
end)

case("cmdline checks: allowlisted, no bang, starts with /", function()
  local allow = Core.parse_allowlist("compact,btw")
  eq(Core.check_cmdline("/compact keep the API notes", allow), "compact")
  eq(Core.check_cmdline("/BTW what?", allow), "btw")
  local function refused(cmdline, why)
    local key, err = Core.check_cmdline(cmdline, allow)
    eq(key, nil, cmdline)
    eq(err:find(why, 1, true) ~= nil, true, err)
  end
  refused("/yolo", "not in remote_commands_allow")
  refused("/model", "not in remote_commands_allow")
  refused("compact", "starting with /")
  refused("!rm -rf /", "starting with /")
  refused("/btw hi\n!rm -rf /", "! lines")
  refused("/compact!", "bang")
  refused(nil, "starting with /")
  refused("/btw " .. string.rep("x", Core.MAX_CMDLINE), "exceeds")
end)

case("the commands fallback lists allowlisted builtins plus web-native pickers", function()
  local list = Core.command_list(nil, Core.parse_allowlist("compact,goal,rv"))
  local names = {}
  for i, c in ipairs(list) do
    names[i] = c.name .. (c.interactive and "*" or "")
    eq(c.allowed, true)
  end
  same(names, { "/compact", "/model*", "/thinking*", "/sessions*", "/goal", "/rv" })
  eq(list[1].description, "Summarize and compact conversation history (optional guidance)")
  eq(list[1].source, "builtin")
  eq(list[5].plugin, "maki-plugins")
end)

case("an api command list is filtered by the allowlist", function()
  local list = Core.command_list({
    { name = "/compact", description = "c", source = "builtin", max_args = 1, interactive = false },
    { name = "/yolo", description = "y", source = "builtin" },
    {
      name = "/rv",
      description = "r",
      source = "lua",
      plugin = "maki-plugins",
      argument_hint = "[args]",
    },
    { name = "/model", description = "m", source = "builtin", interactive = true },
  }, Core.parse_allowlist("compact,rv"))
  same(list, {
    {
      name = "/compact",
      description = "c",
      source = "builtin",
      interactive = false,
      allowed = true,
    },
    {
      name = "/rv",
      description = "r",
      source = "lua",
      plugin = "maki-plugins",
      argument_hint = "[args]",
      interactive = false,
      allowed = true,
    },
    { name = "/model", description = "m", source = "builtin", interactive = true, allowed = true },
  })
end)

local function catalog_effects()
  local fx = full_effects()
  fx.empty = "EMPTY"
  fx.allow = Core.parse_allowlist("compact,btw")
  fx.ran = {}
  fx.run_command = function(sid, cmdline)
    fx.ran[#fx.ran + 1] = { sid, cmdline }
    return true
  end
  fx.model = {
    spec = "anthropic/opus",
    id = "opus",
    provider = "anthropic",
    thinking = "high",
    thinking_options = { { name = "off" }, { name = "high", tokens = 32000 } },
    fast = false,
    supports_thinking = true,
    supports_fast = true,
  }
  fx.model_get = function()
    return fx.model
  end
  fx.models_available = function()
    return { "anthropic/opus", "openrouter/meta/llama" }
  end
  fx.model_info = function(spec)
    if spec == "anthropic/opus" then
      return { spec = spec, id = "opus", provider = "anthropic", context_window = 200000 }
    end
    error("unknown")
  end
  fx.sets = {}
  fx.model_set = function(sid, change)
    fx.sets[#fx.sets + 1] = { sid, change }
    fx.model.thinking = change.thinking or fx.model.thinking
    return true
  end
  return fx
end

case("maki/commands falls back to the static table without the fork API", function()
  local out = call(Core.controller(catalog_effects()), "maki/commands", {})
  local names = {}
  for i, c in ipairs(out.result.commands) do
    names[i] = c.name
  end
  same(names, { "/compact", "/btw", "/model", "/thinking", "/sessions" })
end)

case("maki/commands uses maki.api.list_commands when present", function()
  local fx = catalog_effects()
  fx.commands = function()
    return { { name = "/btw", description = "b" }, { name = "/exit", description = "x" } }
  end
  local out = call(Core.controller(fx), "maki/commands", {})
  eq(#out.result.commands, 1)
  eq(out.result.commands[1].name, "/btw")
end)

case("maki/command dispatches allowlisted lines and refuses the rest", function()
  local fx = catalog_effects()
  local ctl = Core.controller(fx)
  same(call(ctl, "maki/command", { cmdline = "/compact" }).result, { dispatched = true })
  same(fx.ran, { { "s1", "/compact" } })
  same(fx.dirty, { "s1" })
  eq(call(ctl, "maki/command", { cmdline = "/yolo" }).error.code, -32602)
  eq(call(ctl, "maki/command", { cmdline = "!ls" }).error.code, -32602)
  eq(#fx.ran, 1)
  fx.run_command = function()
    return nil, "no such session"
  end
  local refused = call(ctl, "maki/command", { cmdline = "/btw hi" })
  eq(refused.error.code, -32000)
  eq(refused.error.message, "command refused: no such session")
  fx.run_command = nil
  eq(call(Core.controller(fx), "maki/command", { cmdline = "/btw" }).error.code, -32601)
end)

case("maki/models lists specs with info and the session's current model", function()
  local out = call(Core.controller(catalog_effects()), "maki/models", {})
  same(out.result.current, {
    spec = "anthropic/opus",
    thinking = "high",
    fast = false,
    thinking_options = { { name = "off" }, { name = "high", tokens = 32000 } },
    supports_thinking = true,
    supports_fast = true,
  })
  same(out.result.models, {
    { spec = "anthropic/opus", provider = "anthropic", id = "opus", context_window = 200000 },
    { spec = "openrouter/meta/llama", provider = "openrouter", id = "meta/llama" },
  })
  local fx = catalog_effects()
  fx.model_get = function()
    return nil
  end
  eq(call(Core.controller(fx), "maki/models", {}).result.current, nil)
  fx.models_available = nil
  eq(call(Core.controller(fx), "maki/models", {}).error.code, -32601)
end)

case("maki/model_set validates, sets for the session and returns current", function()
  local fx = catalog_effects()
  local ctl = Core.controller(fx)
  local out = call(ctl, "maki/model_set", { thinking = "off" })
  eq(out.result.ok, true)
  eq(out.result.current.thinking, "off")
  same(fx.sets, { { "s1", { thinking = "off" } } })
  eq(call(ctl, "maki/model_set", {}).error.code, -32602)
  eq(call(ctl, "maki/model_set", { spec = "noslash" }).error.code, -32602)
  eq(call(ctl, "maki/model_set", { fast = "yes" }).error.code, -32602)
  fx.model_set = nil
  eq(call(Core.controller(fx), "maki/model_set", { fast = true }).error.code, -32601)
end)

case("maki/skills and maki/plugins pass through, tagging empties", function()
  local fx = catalog_effects()
  fx.skills = function(sid)
    eq(sid, "s1")
    return { { name = "a", description = "d", path = "/p" } }
  end
  fx.plugins = function()
    return { plugins = {}, source = "fallback" }
  end
  local ctl = Core.controller(fx)
  same(
    call(ctl, "maki/skills", {}).result,
    { skills = { { name = "a", description = "d", path = "/p" } } }
  )
  same(call(ctl, "maki/plugins", {}).result, { plugins = "EMPTY", source = "fallback" })
  fx.skills, fx.plugins = nil, nil
  eq(call(Core.controller(fx), "maki/skills", {}).error.code, -32601)
  eq(call(Core.controller(fx), "maki/plugins", {}).error.code, -32601)
end)

-- /remote-control

case("parse_control_args defaults to status", function()
  same(Core.parse_control_args({}), { cmd = "status" })
  same(Core.parse_control_args(nil), { cmd = "status" })
  same(Core.parse_control_args({ "" }), { cmd = "status" })
end)

case("parse_control_args takes toggle, logs and logs clear in any case", function()
  same(Core.parse_control_args({ "Toggle" }), { cmd = "toggle" })
  same(Core.parse_control_args({ "logs" }), { clear = false, cmd = "logs" })
  same(Core.parse_control_args({ "logs", "CLEAR" }), { clear = true, cmd = "logs" })
end)

case("parse_control_args rejects unknown words and extras with the usage", function()
  for _, fargs in ipairs({ { "bogus" }, { "status", "x" }, { "toggle", "now" }, { "logs", "all" } }) do
    local parsed, usage = Core.parse_control_args(fargs)
    eq(parsed, nil, table.concat(fargs, " "))
    eq(usage, Core.CONTROL_USAGE)
  end
end)

case("log_ring keeps the newest entries up to its cap, oldest first", function()
  local ring = Core.log_ring(3)
  for i = 1, 5 do
    ring.push(0, "info", "m" .. i)
  end
  eq(ring.count(), 3)
  local msgs = {}
  for _, e in ipairs(ring.entries()) do
    msgs[#msgs + 1] = e.msg
  end
  same(msgs, { "m3", "m4", "m5" })
end)

case("log_ring defaults to a cap of 200", function()
  local ring = Core.log_ring()
  for i = 1, 250 do
    ring.push(0, "debug", tostring(i))
  end
  eq(ring.count(), 200)
  eq(ring.entries()[1].msg, "51")
  eq(ring.entries()[200].msg, "250")
end)

case("log_ring lines carry a time and the level", function()
  local ring = Core.log_ring(5)
  ring.push(0, "warn", "hub down")
  local line = ring.lines()[1]
  th.eq(line:match("^%d%d:%d%d:%d%d WARN hub down$") ~= nil, true, line)
end)

case("log_ring clear empties it and keeps working", function()
  local ring = Core.log_ring(2)
  ring.push(0, "info", "a")
  ring.push(0, "info", "b")
  ring.push(0, "info", "c")
  ring.clear()
  eq(ring.count(), 0)
  same(ring.lines(), {})
  ring.push(0, "info", "d")
  eq(ring.entries()[1].msg, "d")
end)

case("mask_token shows a prefix, suffix and length, never the middle", function()
  eq(Core.mask_token("abcdefghijklmnopqrstuvwxyz"), "abcd…yz (26 chars)")
  eq(Core.mask_token("short"), "*****")
  eq(Core.mask_token(""), "(unset)")
  eq(Core.mask_token(nil), "(unset)")
end)

case("mask_url hides userinfo", function()
  eq(Core.mask_url("https://user:secret@hub.example/x"), "https://***@hub.example/x")
  eq(Core.mask_url("https://hub.example"), "https://hub.example")
  eq(Core.mask_url(""), "(unset)")
end)

local function find_line(lines, label)
  for _, l in ipairs(lines) do
    if l:sub(1, #label + 1) == label .. " " then
      return (l:sub(17):gsub("^%s+", ""))
    end
  end
  return nil
end

case("status_lines explains a plugin that is not opted in", function()
  local lines = Core.status_lines({
    opted_in = false,
    missing = { "MAKI_HUB_URL", "MAKI_HUB_TOKEN" },
    url = "",
    control = true,
    fork = false,
    allow = {},
    now = 100,
  })
  eq(find_line(lines, "hub"), "(unset)")
  eq(find_line(lines, "token"), "(unset)")
  eq(find_line(lines, "state"), "off: MAKI_HUB_URL and MAKI_HUB_TOKEN not set")
  eq(find_line(lines, "fork APIs"), "no")
  eq(find_line(lines, "allowlist"), "(none)")
  eq(find_line(lines, "last heartbeat"), nil)
end)

case("status_lines renders a running remote", function()
  local token = "tok_0123456789abcdef"
  local lines = Core.status_lines({
    opted_in = true,
    url = "https://hub.example",
    token = token,
    control = true,
    fork = true,
    allow = { new = true, compact = true },
    now = 100,
    interval = 5,
    last_beat = { at = 97, status = 200 },
    failures = 0,
    live = 2,
    polling = 2,
    mirroring = 1,
  })
  eq(find_line(lines, "hub"), "https://hub.example")
  eq(find_line(lines, "token"), "tok_…ef (20 chars)")
  eq(find_line(lines, "state"), "running")
  eq(find_line(lines, "control"), "enabled")
  eq(find_line(lines, "last heartbeat"), "3s ago, HTTP 200")
  eq(find_line(lines, "failures"), "0 in a row")
  eq(find_line(lines, "poll loops"), "2")
  eq(find_line(lines, "mirror loops"), "1")
  eq(find_line(lines, "fork APIs"), "yes (maki.api.list_commands)")
  eq(find_line(lines, "allowlist"), "compact, new")
  for _, l in ipairs(lines) do
    th.eq(l:find(token, 1, true), nil, "token leaked: " .. l)
  end
end)

case("status_lines shows paused, refused and report-only states", function()
  local base = {
    opted_in = true,
    url = "https://hub.example",
    token = "x",
    control = true,
    now = 1000,
    last_beat = { at = 880, err = "timed out" },
    failures = 4,
    polling = 1,
    mirroring = 1,
  }
  base.paused = true
  local lines = Core.status_lines(base)
  eq(find_line(lines, "state"), "paused")
  eq(find_line(lines, "poll loops"), "1 (paused)")
  eq(find_line(lines, "last heartbeat"), "2m ago, error: timed out")
  eq(find_line(lines, "failures"), "4 in a row")
  base.paused, base.token_refused = false, true
  base.last_beat = { at = 1000, status = 401 }
  lines = Core.status_lines(base)
  eq(find_line(lines, "state"), "stopped: hub refused the token (toggle to retry)")
  eq(find_line(lines, "last heartbeat"), "0s ago, HTTP 401")
  base.token_refused, base.control = false, false
  lines = Core.status_lines(base)
  eq(find_line(lines, "control"), "disabled (MAKI_HUB_CONTROL=0)")
  eq(find_line(lines, "poll loops"), "off")
  eq(find_line(lines, "last heartbeat"), "0s ago, HTTP 401")
  base.last_beat = {}
  eq(find_line(Core.status_lines(base), "last heartbeat"), "never")
end)

th.report()
