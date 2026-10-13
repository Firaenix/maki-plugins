local th = require("./th")
local Store = require("../lua/describe_store")

local case, eq, same = th.case, th.eq, th.same

-- Calls

case("remember keeps a bash call by tool id", function()
  local calls = Store.calls()
  calls:remember("t1", { command = "ls -la", intent = "Lists the files.", workdir = "/repo" })
  same(calls:get("t1"), { command = "ls -la", sentence = "Lists the files.", workdir = "/repo" })
end)

case("the sentence falls back to description", function()
  local calls = Store.calls()
  calls:remember("t1", { command = "ls", description = "List files" })
  eq(calls:get("t1").sentence, "List files")
end)

case("an intent that is not a string falls back to description", function()
  local calls = Store.calls()
  calls:remember("t1", { command = "ls", intent = 42, description = "List files" })
  eq(calls:get("t1").sentence, "List files")
end)

case("whitespace in the sentence collapses to single spaces", function()
  local calls = Store.calls()
  calls:remember("t1", { command = "ls", intent = "  Lists\n\tthe   files.  " })
  eq(calls:get("t1").sentence, "Lists the files.")
end)

case("a blank intent counts as missing", function()
  local calls = Store.calls()
  calls:remember("t1", { command = "ls", intent = "   ", description = "List files" })
  eq(calls:get("t1").sentence, "List files")
end)

case("a long sentence is capped on a character boundary", function()
  local calls = Store.calls()
  local intent = string.rep("a", Store.MAX_TEXT_BYTES - 1) .. "é tail"
  calls:remember("t1", { command = "ls", intent = intent })
  eq(calls:get("t1").sentence, string.rep("a", Store.MAX_TEXT_BYTES - 1) .. "…")
end)

case("nested calls and calls without a command are skipped", function()
  local calls = Store.calls()
  calls:remember("", { command = "ls" })
  calls:remember(nil, { command = "ls" })
  calls:remember("t2", { command = "" })
  calls:remember("t3", { intent = "No command." })
  calls:remember("t4", "not a table")
  eq(calls:get(""), nil)
  eq(calls:get("t2"), nil)
  eq(calls:get("t3"), nil)
  eq(calls:get("t4"), nil)
end)

case("the oldest call is dropped past the cap", function()
  local calls = Store.calls(2)
  calls:remember("t1", { command = "a" })
  calls:remember("t2", { command = "b" })
  calls:remember("t3", { command = "c" })
  eq(calls:get("t1"), nil)
  eq(calls:get("t2").command, "b")
  eq(calls:get("t3").command, "c")
end)

case("remembering the same id again does not take a second slot", function()
  local calls = Store.calls(2)
  calls:remember("t1", { command = "a" })
  calls:remember("t1", { command = "a2" })
  calls:remember("t2", { command = "b" })
  eq(calls:get("t1").command, "a2")
  eq(calls:get("t2").command, "b")
end)

case("forget drops a call and frees its slot", function()
  local calls = Store.calls(2)
  calls:remember("t1", { command = "a" })
  calls:remember("t2", { command = "b" })
  calls:forget("t1")
  calls:forget("unknown")
  calls:forget(nil)
  calls:remember("t3", { command = "c" })
  eq(calls:get("t1"), nil)
  eq(calls:get("t2").command, "b")
  eq(calls:get("t3").command, "c")
end)

-- Prompts

local CALL = { command = "ls", sentence = "Lists the files." }

case("the front prompt of the focused session is current", function()
  local prompts = Store.prompts()
  prompts:focus("s1")
  prompts:open("s1", 7, CALL)
  eq(prompts:current().request_id, 7)
end)

case("nothing is current before focus is known", function()
  local prompts = Store.prompts()
  prompts:open("s1", 7, CALL)
  eq(prompts:current(), nil)
end)

case("a prompt in a background session is never current", function()
  local prompts = Store.prompts()
  prompts:focus("s1")
  prompts:open("s2", 7, CALL)
  eq(prompts:current(), nil)
  prompts:focus("s2")
  eq(prompts:current().request_id, 7)
end)

case("a foreign prompt at the front hides the ones behind it", function()
  local prompts = Store.prompts()
  prompts:focus("s1")
  prompts:open("s1", 1, nil)
  prompts:open("s1", 2, CALL)
  eq(prompts:current(), nil)
  prompts:resolve(1)
  eq(prompts:current().request_id, 2)
end)

case("a handed-off prompt is not current and keeps its place", function()
  local prompts = Store.prompts()
  prompts:focus("s1")
  prompts:open("s1", 1, CALL)
  prompts:open("s1", 2, CALL)
  prompts:hand_off(1)
  eq(prompts:current(), nil)
  prompts:resolve(1)
  eq(prompts:current().request_id, 2)
end)

case("resolving an unknown request changes nothing", function()
  local prompts = Store.prompts()
  prompts:focus("s1")
  prompts:open("s1", 1, CALL)
  prompts:resolve(99)
  eq(prompts:current().request_id, 1)
end)

case("an event without a session or request id is ignored", function()
  local prompts = Store.prompts()
  prompts:focus("s1")
  prompts:open(nil, 1, CALL)
  prompts:open("s1", nil, CALL)
  eq(prompts:current(), nil)
end)

case("a formatter result for a closed prompt is dropped", function()
  local prompts = Store.prompts()
  prompts:focus("s1")
  prompts:open("s1", 1, CALL)
  eq(prompts:set_formatted(1, "ls\n"), true)
  eq(prompts:current().formatted, "ls\n")
  prompts:resolve(1)
  eq(prompts:set_formatted(1, "late\n"), false)
  eq(prompts:current(), nil)
end)

-- Layer

case("the layer remembers the call as the inner layers left it", function()
  local calls = Store.calls()
  local layer = Store.layer(calls)
  local out = layer(function(input)
    return { command = "rg foo", description = input.description }
  end, { command = "grep -r foo", description = "Search" }, { tool_id = "t1" })
  eq(out.command, "rg foo")
  eq(calls:get("t1").command, "rg foo")
end)

case("the layer remembers the input when prev leaves it alone", function()
  local calls = Store.calls()
  local layer = Store.layer(calls)
  local results = { layer(function() end, { command = "ls" }, { tool_id = "t1" }) }
  eq(#results, 0)
  eq(calls:get("t1").command, "ls")
end)

case("the layer hands back everything prev answered", function()
  local layer = Store.layer(Store.calls())
  local a, b = layer(function()
    return nil, "stopped"
  end, { command = "ls" }, { tool_id = "t1" })
  eq(a, nil)
  eq(b, "stopped")
  local ask = { ask = "risky" }
  local c, d = layer(function(input)
    return input, ask
  end, { command = "ls" }, { tool_id = "t2" })
  eq(c.command, "ls")
  eq(d, ask)
end)

case("a failure to remember is reported and the call goes on", function()
  local warned
  local broken = {
    remember = function()
      error("boom")
    end,
  }
  local layer = Store.layer(broken, function(msg)
    warned = msg
  end)
  local out = layer(function(input)
    return input
  end, { command = "ls" }, { tool_id = "t1" })
  eq(out.command, "ls")
  eq(type(warned) == "string" and warned:find("boom", 1, true) ~= nil, true)
end)

-- View

local View = require("../lua/describe_view")

case("sanitize makes control bytes visible and expands tabs", function()
  eq(View.sanitize("a\tb\r\nc\27[31md\7"), "a  b\nc\\x1b[31md\\x07")
end)

case("sanitize replaces bytes that are not UTF-8", function()
  eq(View.sanitize("ok \255 end"), "ok ? end")
end)

case("wrap_words breaks at spaces and splits a word wider than the line", function()
  same(View.wrap_words("one two three", 7), { "one two", "three" })
  same(View.wrap_words("abcdefghij", 4), { "abcd", "efgh", "ij" })
end)

case("rows numbers source lines and wraps a long one under one number", function()
  same(View.rows("short\n" .. string.rep("x", 10), 4), {
    { lineno = 1, text = "shor" },
    { text = "t" },
    { lineno = 2, text = "xxxx" },
    { text = "xxxx" },
    { text = "xx" },
  })
end)

case("content counts lines, drops trailing newlines and sizes the gutter", function()
  local c = View.content({ sentence = "Lists files.", workdir = "/repo" }, "ls\npwd\n\n", 40)
  eq(c.total, 2)
  eq(c.gutter, 3)
  same(c.sentence, { "Lists files." })
  eq(c.where, "in /repo")
end)

local function numbered(n)
  local lines = {}
  for i = 1, n do
    lines[i] = "echo " .. i
  end
  return table.concat(lines, "\n")
end

case("compact shows the sentence, the first rows and how much is left", function()
  local c = View.content({ sentence = "Echoes numbers." }, numbered(12), 40)
  local out = View.compact(c)
  eq(out[1], "Echoes numbers.")
  eq(out[2], "")
  same(out[3], { { " 1  ", "dim" }, { "echo 1" } })
  same(out[#out], { { "… 4 more lines, v shows all", "dim" } })
  eq(#out, 2 + View.COMPACT_ROWS + 1)
end)

case("compact without a sentence starts with the code", function()
  local c = View.content({}, "ls", 40)
  same(View.compact(c), { { { "1  ", "dim" }, { "ls" } } })
end)

case("compact on one long line says the rest is in the full view", function()
  local c = View.content({}, string.rep("x", 400), 20)
  local out = View.compact(c)
  same(out[#out], { { "… v shows all", "dim" } })
end)

case("compact uses highlighted spans when the panel supplies them", function()
  local c = View.content({}, "ls", 40)
  c.styled = { { { "ls", { fg = "#ff0000" } } } }
  same(View.compact(c)[1], { { "1  ", "dim" }, { "ls", { fg = "#ff0000" } } })
end)

case("compact height fits the content and leaves room for the prompt", function()
  eq(View.compact_height(6, 50), 8)
  eq(View.compact_height(40, 30), 16)
  eq(View.compact_height(40, 10), View.MIN_HEIGHT)
end)

case("titles say how long the script is and whether shfmt formatted it", function()
  local c = View.content({}, numbered(30), 40)
  eq(View.compact_title(c), " bash · 30 lines · as written ")
  c.formatted = true
  eq(View.compact_title(c), " bash · 30 lines · shfmt ")
end)

local function long_content()
  return View.content({ sentence = "Echoes numbers." }, numbered(30), 40)
end

case("full shows the rows that fit under the header", function()
  local c = long_content()
  -- 12 rows tall: 2 border, 2 header (the sentence and a blank), 8 code rows.
  local out = View.full(c, 12, 5)
  eq(#out, 2 + 8)
  same(out[3], { { " 5  ", "dim" }, { "echo 5" } })
  eq(View.full_title(c, 5, 12), " bash · as written · rows 5-12 of 30 ")
end)

case("v opens the full view, and Esc or v goes back", function()
  local c = long_content()
  local state = { mode = "compact", top = 1, can_answer = true }
  eq(View.handle_key(state, "v", c, 12), "redraw")
  eq(state.mode, "full")
  eq(View.handle_key(state, "<Esc>", c, 12), "redraw")
  eq(state.mode, "compact")
  View.handle_key(state, "v", c, 12)
  eq(View.handle_key(state, "v", c, 12), "redraw")
  eq(state.mode, "compact")
end)

case("scrolling moves by line and page and stops at both ends", function()
  local c = long_content()
  local state = { mode = "full", top = 1, can_answer = true }
  eq(View.handle_key(state, "k", c, 12), nil)
  eq(View.handle_key(state, "j", c, 12), "redraw")
  eq(state.top, 2)
  View.handle_key(state, "<PageDown>", c, 12)
  eq(state.top, 10)
  View.handle_key(state, "G", c, 12)
  eq(state.top, 23)
  eq(View.handle_key(state, "<Down>", c, 12), nil)
  View.handle_key(state, "g", c, 12)
  eq(state.top, 1)
end)

case("scroll keys do nothing in the compact view", function()
  local c = long_content()
  local state = { mode = "compact", top = 1, can_answer = true }
  eq(View.handle_key(state, "j", c, 12), nil)
  eq(state.top, 1)
end)

case("y, n and Tab act from either view", function()
  local c = long_content()
  for _, mode in ipairs({ "compact", "full" }) do
    local state = { mode = mode, top = 1, can_answer = true }
    eq(View.handle_key(state, "y", c, 12), "allow")
    eq(View.handle_key(state, "n", c, 12), "deny")
    eq(View.handle_key(state, "<Tab>", c, 12), "hand_off")
    eq(View.handle_key(state, "<C-c>", c, 12), "hand_off")
  end
end)

case("without answering, y and n do nothing and the footer drops them", function()
  local c = long_content()
  local state = { mode = "compact", top = 1, can_answer = false }
  eq(View.handle_key(state, "y", c, 12), nil)
  eq(View.handle_key(state, "n", c, 12), nil)
  same(View.footer(state), { { "v", "full view" }, { "Tab", "more answers" } })
end)

case("the footer names the keys of each view", function()
  same(
    View.footer({ mode = "compact", can_answer = true }),
    { { "y", "allow" }, { "n", "deny" }, { "v", "full view" }, { "Tab", "more answers" } }
  )
  same(View.footer({ mode = "full", can_answer = true }), {
    { "y", "allow" },
    { "n", "deny" },
    { "j/k", "scroll" },
    { "v", "back" },
    { "Tab", "more answers" },
  })
end)

case("before anything is drawn only Tab and Ctrl+C act", function()
  local state = { mode = "compact", top = 1, can_answer = true }
  eq(View.handle_key(state, "<Tab>", nil, 12), "hand_off")
  eq(View.handle_key(state, "<C-c>", nil, 12), "hand_off")
  eq(View.handle_key(state, "y", nil, 12), nil)
  eq(View.handle_key(state, "n", nil, 12), nil)
  eq(View.handle_key(state, "v", nil, 12), nil)
  eq(state.mode, "compact")
end)

case("a resize pulls the top back into range", function()
  eq(View.clamp_top(23, long_content(), 30), 5)
end)

th.report()
