local th = require("./th")
local Core = require("../lua/plugins_core")

local case, eq, same = th.case, th.eq, th.same

local LOAD_FAIL =
  [[{"timestamp":"2026-09-16T08:28:17.908450Z","level":"ERROR","fields":{"message":"failed to load package","package":"maki-plugins","path":"/data/site/pack/core/maki-plugins/abc","error":"lua error in maki-plugins: permission denied: 'reviewers'\nstack traceback: x"},"target":"maki_lua::loader"}]]
local CALLBACK_FAIL =
  [[{"timestamp":"2026-10-18T14:15:22.000000Z","level":"WARN","fields":{"message":"defer_fn callback failed","plugin":"rv","error":"attempt to index nil \"x\""},"target":"maki_lua::runtime"}]]
local PLUGIN_WARN =
  [[{"timestamp":"2026-10-18T14:15:23.000000Z","level":"WARN","fields":{"message":"remote: heartbeat failed","plugin":"maki-plugins"},"target":"maki_lua::api::log"}]]
local PLUGIN_ERROR =
  [[{"timestamp":"2026-10-18T14:15:24.000000Z","level":"ERROR","fields":{"message":"remote: hub refused the token","plugin":"maki-plugins"},"target":"maki_lua::api::log"}]]
local PLUGIN_INFO =
  [[{"timestamp":"2026-10-18T14:15:25.000000Z","level":"INFO","fields":{"message":"remote: heartbeat recovered","plugin":"maki-plugins"},"target":"maki_lua::api::log"}]]

-- Timestamps

case("iso_to_unix converts UTC timestamps", function()
  eq(Core.iso_to_unix("1970-01-01T00:00:00Z"), 0)
  eq(Core.iso_to_unix("2000-03-01T00:00:00Z"), 951868800)
  eq(Core.iso_to_unix("2026-10-18T14:15:22.133574Z"), 1792332922)
  eq(Core.iso_to_unix("junk"), nil)
  eq(Core.iso_to_unix(nil), nil)
end)

-- Log parsing

case("json_field unescapes quotes, newlines and unicode", function()
  eq(Core.json_field([[{"a":"x\"y\nz\u00e9"}]], "a"), 'x"y\nzé')
  eq(Core.json_field([[{"a":"x"}]], "b"), nil)
end)

case("a load failure names the package, path and error", function()
  local e = Core.parse_log_line(LOAD_FAIL)
  eq(e.kind, "load")
  eq(e.plugin, "maki-plugins")
  eq(e.path, "/data/site/pack/core/maki-plugins/abc")
  eq(e.msg, "lua error in maki-plugins: permission denied: 'reviewers'\nstack traceback: x")
  eq(e.t, Core.iso_to_unix("2026-09-16T08:28:17Z"))
end)

case("maki's warnings about a plugin are errors, the plugin's own warnings are not", function()
  local e = Core.parse_log_line(CALLBACK_FAIL)
  eq(e.kind, "error")
  eq(e.plugin, "rv")
  eq(e.seam, "runtime")
  eq(e.msg, 'defer_fn callback failed: attempt to index nil "x"')
  eq(Core.parse_log_line(PLUGIN_WARN), nil)
  eq(Core.parse_log_line(PLUGIN_INFO), nil)
  eq(Core.parse_log_line(PLUGIN_ERROR).seam, "log")
end)

case("text-format log lines are read too", function()
  local e =
    Core.parse_log_line("2026-10-18T14:15:22Z  WARN maki_lua::runtime: keybind failed plugin=goal")
  eq(e.plugin, "goal")
  eq(e.kind, "error")
  local l = Core.parse_log_line(
    "2026-10-18T14:15:22Z ERROR maki_lua::loader: failed to load package package=foo path=/p error=boom"
  )
  eq(l.kind, "load")
  eq(l.plugin, "foo")
  eq(l.msg, "boom")
  eq(Core.parse_log_line("INFO something unrelated"), nil)
end)

case("parse_log drops lines older than the process and keeps the newest 20", function()
  local lines = { LOAD_FAIL, CALLBACK_FAIL }
  for i = 1, 25 do
    lines[#lines + 1] = CALLBACK_FAIL:gsub("nil", "nil" .. i)
  end
  local log = Core.parse_log(lines, Core.iso_to_unix("2026-10-01T00:00:00Z"))
  eq(log.loads["maki-plugins"], nil, "the September load failure predates this process")
  eq(#log.errors.rv, Core.MAX_ERRORS)
  eq(log.errors.rv[Core.MAX_ERRORS].msg, 'defer_fn callback failed: attempt to index nil25 "x"')
  local all = Core.parse_log({ LOAD_FAIL }, nil)
  eq(all.loads["maki-plugins"].path, "/data/site/pack/core/maki-plugins/abc")
end)

-- Source scan

case("scan_source finds commands, tools and autocmds", function()
  local s = Core.scan_source([[
maki.api.register_command({
  name = "/goal",
  handler = h,
})
maki.api.register_tool({ name = "goal_complete", schema = {} })
maki.api.create_autocmd("TurnEnd", {})
maki.api.create_autocmd({ "A", "B" }, {})
]])
  same(s.commands, { "/goal" })
  same(s.tools, { "goal_complete" })
  eq(s.autocmds, 2)
end)

-- Collect

case("collect prefers maki.api.list_plugins and normalises its records", function()
  local res = Core.collect({
    list_plugins = function()
      return {
        { name = "rv", source = "package", enabled = true, loaded = true, autocmds = 2 },
      }
    end,
    empty = "EMPTY",
    log_lines = function()
      error("the fallback must not run")
    end,
  })
  eq(res.source, "api")
  eq(res.plugins[1].name, "rv")
  eq(res.plugins[1].errors, "EMPTY")
  eq(res.plugins[1].commands, "EMPTY")
  eq(res.plugins[1].autocmds, 2)
end)

case("the fallback merges bundled, packs, the site scan and the log", function()
  local res = Core.collect({
    bundled = { "bash" },
    pack_get = function()
      return {
        { spec = { name = "maki-plugins" }, path = "/pack/core/maki-plugins/abc", active = true },
      }
    end,
    scan_packs = function()
      return {
        { name = "maki-plugins", path = "/pack/core/maki-plugins" },
        { name = "handmade", path = "/pack/me/start/handmade", kind = "start" },
        { name = "later", path = "/pack/me/opt/later", kind = "opt" },
        { name = "stale", path = "/pack/core/stale" },
      }
    end,
    log_lines = function()
      return { LOAD_FAIL:gsub("maki%-plugins", "handmade"), CALLBACK_FAIL }
    end,
    sources = function(path)
      if path == "/pack/core/maki-plugins/abc" then
        return { 'maki.api.register_command({ name = "/plugins" })' }
      end
      return {}
    end,
  })
  eq(res.source, "fallback")
  local by = {}
  for _, p in ipairs(res.plugins) do
    by[p.name] = p
  end
  eq(by.bash.source, "bundled")
  eq(Core.status(by.bash), "loaded")
  same(by["maki-plugins"].commands, { "/plugins" })
  eq(Core.status(by["maki-plugins"]), "loaded")
  eq(Core.status(by.handmade), "error")
  eq(by.handmade.loaded, false)
  eq(Core.status(by.later), "disabled")
  eq(Core.status(by.stale), "disabled")
  eq(by.rv.source, "package", "a plugin only seen in the log still shows up")
  eq(#by.rv.errors, 1)
  same(Core.summary(res.plugins), { errors = 2, total = 6 })
end)

case("a broken api function only thins the fallback", function()
  local res = Core.collect({
    bundled = {},
    pack_get = function()
      error("no lockfile")
    end,
  })
  eq(res.source, "fallback")
  eq(#res.plugins, 0)
end)

-- Format

local function plugin(name, fields)
  local p = { name = name, source = "package", enabled = true, loaded = true }
  p.errors, p.commands, p.tools, p.autocmds = {}, {}, {}, 0
  for k, v in pairs(fields or {}) do
    p[k] = v
  end
  return p
end

case("format orders Errors, Loaded, Disabled and names within each", function()
  local rows = Core.format({
    plugin("zeta"),
    plugin("off", { enabled = false, loaded = false }),
    plugin("alpha", { commands = { "/a" }, tools = { "t1", "t2" }, autocmds = 1 }),
    plugin("broken", { loaded = false, load_error = "boom\ntrace" }),
    plugin("noisy", {
      errors = {
        { t = 1, seam = "runtime", msg = "first" },
        { t = 2, seam = "x", msg = "last\nmore" },
      },
    }),
  })
  local labels = {}
  for i, r in ipairs(rows) do
    labels[i] = r.section .. ":" .. r.label
  end
  same(labels, {
    "Errors:✗ broken",
    "Errors:✗ noisy",
    "Loaded:● alpha",
    "Loaded:● zeta",
    "Disabled:○ off",
  })
  eq(rows[1].detail, "package · 0 cmds, 0 tools, 0 autocmds · boom")
  eq(rows[2].detail, "package · 0 cmds, 0 tools, 0 autocmds · last")
  eq(rows[3].detail, "package · 1 cmd, 2 tools, 1 autocmd")
end)

case("detail lines show path, commands, tools and every kept error", function()
  local lines = Core.detail_lines(
    plugin("rv", {
      path = "/p/rv",
      commands = { "/rv" },
      errors = { { t = 0, seam = "runtime", msg = "bad\ntrace" } },
    }),
    function()
      return "T"
    end
  )
  same(lines, {
    "rv  (package, error)",
    "path:     /p/rv",
    "commands: /rv",
    "tools:    none",
    "autocmds: 0",
    "",
    "errors (last 1, newest last):",
    "  T [runtime] bad",
  })
end)

case("error_text copies the full newest error", function()
  eq(Core.error_text(plugin("a", { load_error = "x\ny" })), "x\ny")
  eq(Core.error_text(plugin("b", { errors = { { msg = "1" }, { msg = "2\n3" } } })), "2\n3")
  eq(Core.error_text(plugin("c")), nil)
end)

case("the log tail command quotes the path", function()
  local cmd = Core.log_tail_cmd("/a b/it's.log")
  eq(cmd:find("'/a b/it'\\''s.log'", 1, true) ~= nil, true, cmd)
end)

th.report()
