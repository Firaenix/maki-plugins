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
    return true
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
  fx.refuse = "gone"
  eq(call(ctl, "maki/cancel", {}).error.code, -32000)
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

case("capabilities follow the session API that exists", function()
  same(
    Core.capabilities({}),
    { cancel = false, answer_question = false, permission_decisions = { "allow", "deny" } }
  )
  local caps = Core.capabilities({ cancel = print, answer_question = print })
  eq(caps.cancel, true)
  eq(caps.answer_question, true)
  eq(Core.capabilities(nil).cancel, false)
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

th.report()
