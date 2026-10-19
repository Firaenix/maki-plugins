-- plugins_core: what /plugins and the remote's maki/plugins report about every
-- plugin this maki knows. Pure apart from M.maki_api(), so the spec can run it
-- under plain luau.
--
-- A fork maki answers maki.api.list_plugins() directly. Without it the list
-- is rebuilt from what a plugin can see:
--   bundled:  the plugins compiled into maki (BUNDLED below)
--   packages: maki.pack.get() plus a scan of <data>/site/pack, where both
--             <group>/<name>/<rev> (managed) and <group>/{start,opt}/<name>
--             (hand-placed) layouts are recognised
--   errors:   the tail of maki.log, JSON lines carrying plugin=<name> or
--             "failed to load package", newer than this process's start
-- The fallback cannot see commands of bundled plugins and reads a package's
-- commands and tools off its source, so its counts are best-effort.

local M = {}

M.MAX_ERRORS = 20
-- Startup load failures can be logged a little before this module loads.
M.START_SLACK_SEC = 120
M.LOG_TAIL_BYTES = 4000000
M.LOG_TAIL_LINES = 2000

-- Directories under maki's plugins/ that are plugins (lib is a library).
M.BUNDLED = {
  "bash",
  "batch",
  "code_execution",
  "completion",
  "deepseek",
  "edit",
  "glob",
  "grep",
  "index",
  "list",
  "memory",
  "mistral",
  "openrouter",
  "question",
  "read",
  "regolo",
  "requesty",
  "sessions",
  "skill",
  "synthetic",
  "task",
  "tensorx",
  "thinking",
  "todo_write",
  "view_image",
  "webfetch",
  "websearch",
  "write",
}

M.GLYPHS = { error = "✗", loaded = "●", disabled = "○" }
M.SECTIONS = { error = "Errors", loaded = "Loaded", disabled = "Disabled" }
local SECTION_ORDER = { error = 1, loaded = 2, disabled = 3 }

-- "2026-10-18T14:15:22.133574Z" -> unix seconds (UTC), or nil.
function M.iso_to_unix(ts)
  if type(ts) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days_from_civil (Howard Hinnant), valid for the proleptic Gregorian calendar.
  y = mo <= 2 and y - 1 or y
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (mo + (mo > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

local ESCAPES = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }

-- The string value of "key" in a one-line JSON object, unescaped, or nil.
-- Not a JSON parser: enough for tracing's flat field layout.
function M.json_field(line, key)
  local needle = '"' .. key .. '":"'
  local start = line:find(needle, 1, true)
  if not start then
    return nil
  end
  local i = start + #needle
  local out = {}
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' then
      return table.concat(out)
    elseif c == "\\" then
      local e = line:sub(i + 1, i + 1)
      if e == "u" then
        local code = tonumber(line:sub(i + 2, i + 5), 16)
        out[#out + 1] = code and utf8.char(code) or ""
        i = i + 6
      else
        out[#out + 1] = ESCAPES[e] or e
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return nil
end

local function first_line(s)
  return (tostring(s or ""):match("^[^\n]*"))
end

-- One maki.log line as {kind="error"|"load", plugin, t?, seam, msg, path?},
-- or nil when it is not about a plugin. JSON lines (maki's default) and
-- tracing's text format (`... plugin=name ...`) are both read.
function M.parse_log_line(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end
  if line:sub(1, 1) == "{" then
    local message = M.json_field(line, "message") or ""
    local t = M.iso_to_unix(M.json_field(line, "timestamp"))
    if message == "failed to load package" then
      return {
        kind = "load",
        plugin = M.json_field(line, "package") or "?",
        t = t,
        seam = "load",
        msg = M.json_field(line, "error") or message,
        path = M.json_field(line, "path"),
      }
    end
    local plugin = M.json_field(line, "plugin")
    local level = M.json_field(line, "level")
    local target = M.json_field(line, "target") or ""
    if not plugin then
      return nil
    end
    -- maki.log.warn from a plugin is its own chatter; maki's warnings about
    -- a plugin (failed callbacks, stuck tasks) and any ERROR count.
    local from_plugin = target == "maki_lua::api::log"
    if not (level == "ERROR" or (level == "WARN" and not from_plugin)) then
      return nil
    end
    local err = M.json_field(line, "error")
    local command = M.json_field(line, "command")
    return {
      kind = "error",
      plugin = plugin,
      t = t,
      seam = command or M.json_field(line, "at") or (from_plugin and "log" or "runtime"),
      msg = err and (message .. ": " .. err) or message,
    }
  end
  local level = line:match("%f[%a](ERROR)%f[%A]") or line:match("%f[%a](WARN)%f[%A]")
  if line:find("failed to load package", 1, true) then
    return {
      kind = "load",
      plugin = line:match("package=(%S+)") or "?",
      seam = "load",
      msg = line:match("error=(.*)$") or line,
      path = line:match("path=(%S+)"),
    }
  end
  local plugin = line:match("plugin=(%S+)")
  if plugin and level then
    return { kind = "error", plugin = plugin, seam = "runtime", msg = line }
  end
  return nil
end

-- {errors = name -> [{t, seam, msg}] newest last (max 20), loads = name ->
-- {msg, path, t}}. Lines older than {since} are skipped; undated ones kept.
function M.parse_log(lines, since)
  local errors, loads = {}, {}
  for _, line in ipairs(lines or {}) do
    local e = M.parse_log_line(line)
    if e and (not since or not e.t or e.t >= since) then
      if e.kind == "load" then
        loads[e.plugin] = { msg = e.msg, path = e.path, t = e.t }
      else
        local list = errors[e.plugin] or {}
        list[#list + 1] = { t = e.t or 0, seam = e.seam, msg = e.msg }
        if #list > M.MAX_ERRORS then
          table.remove(list, 1)
        end
        errors[e.plugin] = list
      end
    end
  end
  return { errors = errors, loads = loads }
end

-- Commands, tools and autocmd count read off a plugin's source.
function M.scan_source(text, into)
  local out = into or { commands = {}, tools = {}, autocmds = 0 }
  if type(text) ~= "string" then
    return out
  end
  for name in text:gmatch('register_command%(%s*{%s*name%s*=%s*"([^"]+)"') do
    out.commands[#out.commands + 1] = name
  end
  for name in text:gmatch('register_tool%(%s*{%s*name%s*=%s*"([^"]+)"') do
    out.tools[#out.tools + 1] = name
  end
  for _ in text:gmatch("create_autocmd%(") do
    out.autocmds = out.autocmds + 1
  end
  return out
end

local function entry(name, source)
  return {
    name = name,
    source = source,
    enabled = true,
    loaded = true,
    errors = {},
    commands = {},
    tools = {},
    autocmds = 0,
  }
end

-- The fallback list from what M.maki_api gathered:
--   input.packs    maki.pack.get() records {spec={name}, path, rev, active}
--   input.scanned  {name, path, kind="start"|"opt"|nil} from the site scan
--   input.log      M.parse_log result
--   input.sources  function(path) -> list of source texts, optional
--   input.bundled  names, default M.BUNDLED
function M.build_fallback(input)
  local by_name, order = {}, {}
  local function put(e)
    if not by_name[e.name] then
      order[#order + 1] = e.name
    end
    by_name[e.name] = e
    return e
  end

  for _, name in ipairs(input.bundled or M.BUNDLED) do
    put(entry(name, "bundled"))
  end
  for _, r in ipairs(input.packs or {}) do
    local name = type(r.spec) == "table" and r.spec.name or r.name
    if type(name) == "string" then
      local e = put(entry(name, "package"))
      e.path = r.path
      e.enabled = r.active == true
      e.loaded = r.active == true
    end
  end
  for _, s in ipairs(input.scanned or {}) do
    if not by_name[s.name] then
      local e = put(entry(s.name, "package"))
      e.path = s.path
      -- start/ loads at startup; opt/ and undeclared managed packages do not.
      e.enabled = s.kind == "start"
      e.loaded = s.kind == "start"
    end
  end

  local log = input.log or { errors = {}, loads = {} }
  for name, le in pairs(log.loads or {}) do
    local e = by_name[name] or put(entry(name, "package"))
    e.load_error = le.msg
    e.loaded = false
    e.path = e.path or le.path
  end
  for name, list in pairs(log.errors or {}) do
    local e = by_name[name] or put(entry(name, name == "init" and "init" or "package"))
    e.errors = list
  end

  if input.sources then
    for _, name in ipairs(order) do
      local e = by_name[name]
      if e.path then
        local ok, texts = pcall(input.sources, e.path)
        for _, text in ipairs(ok and type(texts) == "table" and texts or {}) do
          M.scan_source(text, e)
        end
      end
    end
  end

  local out = {}
  for i, name in ipairs(order) do
    out[i] = by_name[name]
  end
  return out
end

local function str_list(v)
  local out = {}
  for _, x in ipairs(type(v) == "table" and v or {}) do
    if type(x) == "string" then
      out[#out + 1] = x
    end
  end
  return out
end

-- An API record with every field the contract promises present.
function M.normalize(p)
  local errors = {}
  for _, e in ipairs(type(p.errors) == "table" and p.errors or {}) do
    if type(e) == "table" then
      errors[#errors + 1] =
        { t = tonumber(e.t) or 0, seam = tostring(e.seam or ""), msg = tostring(e.msg or "") }
    end
  end
  while #errors > M.MAX_ERRORS do
    table.remove(errors, 1)
  end
  return {
    name = tostring(p.name or "?"),
    source = p.source or "package",
    path = type(p.path) == "string" and p.path or nil,
    enabled = p.enabled ~= false,
    loaded = p.loaded == true,
    load_error = type(p.load_error) == "string" and p.load_error or nil,
    errors = errors,
    commands = str_list(p.commands),
    tools = str_list(p.tools),
    autocmds = tonumber(p.autocmds) or 0,
  }
end

-- Empty arrays swapped for the caller's tagged one so they encode as [].
local function tag_empties(list, empty)
  if empty == nil then
    return list
  end
  for _, p in ipairs(list) do
    for _, k in ipairs({ "errors", "commands", "tools" }) do
      if #p[k] == 0 then
        p[k] = empty
      end
    end
  end
  return list
end

-- {plugins, source="api"|"fallback"}. {api} is M.maki_api() or a stub:
-- list_plugins?, pack_get?, scan_packs?, log_lines?, sources?, since?, empty?
function M.collect(api)
  api = api or {}
  if type(api.list_plugins) == "function" then
    local ok, list = pcall(api.list_plugins)
    if ok and type(list) == "table" then
      local out = {}
      for _, p in ipairs(list) do
        if type(p) == "table" then
          out[#out + 1] = M.normalize(p)
        end
      end
      return { plugins = tag_empties(out, api.empty), source = "api" }
    end
  end
  local function call(fn)
    if type(fn) ~= "function" then
      return nil
    end
    local ok, v = pcall(fn)
    return ok and type(v) == "table" and v or nil
  end
  local list = M.build_fallback({
    packs = call(api.pack_get),
    scanned = call(api.scan_packs),
    log = M.parse_log(call(api.log_lines), api.since),
    sources = api.sources,
    bundled = api.bundled,
  })
  return { plugins = tag_empties(list, api.empty), source = "fallback" }
end

function M.status(p)
  if p.load_error or (type(p.errors) == "table" and #p.errors > 0) then
    return "error"
  end
  if not p.enabled or not p.loaded then
    return "disabled"
  end
  return "loaded"
end

-- Heartbeat's plugins_summary.
function M.summary(list)
  local errors = 0
  for _, p in ipairs(list or {}) do
    if M.status(p) == "error" then
      errors = errors + 1
    end
  end
  return { total = #(list or {}), errors = errors }
end

function M.latest_error(p)
  if p.load_error then
    return first_line(p.load_error)
  end
  local errs = type(p.errors) == "table" and p.errors or {}
  local last = errs[#errs]
  return last and first_line(last.msg) or nil
end

-- Full text of the newest error, for copying.
function M.error_text(p)
  if p.load_error then
    return p.load_error
  end
  local errs = type(p.errors) == "table" and p.errors or {}
  local last = errs[#errs]
  return last and last.msg or nil
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

-- Picker rows, Errors then Loaded then Disabled, by name within each:
-- {label, detail, section, status, plugin}.
function M.format(list)
  local rows = {}
  for _, p in ipairs(list or {}) do
    local status = M.status(p)
    local counts = ("%s, %s, %s"):format(
      plural(#(p.commands or {}), "cmd"),
      plural(#(p.tools or {}), "tool"),
      plural(tonumber(p.autocmds) or 0, "autocmd")
    )
    local detail = p.source .. " · " .. counts
    local latest = status == "error" and M.latest_error(p) or nil
    if latest then
      detail = detail .. " · " .. latest
    end
    rows[#rows + 1] = {
      label = M.GLYPHS[status] .. " " .. p.name,
      detail = detail,
      section = M.SECTIONS[status],
      status = status,
      plugin = p,
    }
  end
  table.sort(rows, function(a, b)
    local sa, sb = SECTION_ORDER[a.status], SECTION_ORDER[b.status]
    if sa ~= sb then
      return sa < sb
    end
    return a.plugin.name < b.plugin.name
  end)
  return rows
end

local function join(list)
  return #list > 0 and table.concat(list, ", ") or "none"
end

-- Text lines for one plugin's detail pane.
function M.detail_lines(p, fmt_time)
  fmt_time = fmt_time
    or function(t)
      return t and t > 0 and os.date("!%Y-%m-%d %H:%M:%S", t) or "?"
    end
  local lines = {
    ("%s  (%s, %s)"):format(p.name, p.source, M.status(p)),
    "path:     " .. (p.path or "—"),
    "commands: " .. join(p.commands or {}),
    "tools:    " .. join(p.tools or {}),
    "autocmds: " .. tostring(p.autocmds or 0),
  }
  if p.load_error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "load error:"
    for l in tostring(p.load_error):gmatch("[^\n]+") do
      lines[#lines + 1] = "  " .. l
    end
  end
  local errs = type(p.errors) == "table" and p.errors or {}
  if #errs > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("errors (last %d, newest last):"):format(#errs)
    for _, e in ipairs(errs) do
      lines[#lines + 1] = ("  %s [%s] %s"):format(fmt_time(e.t), e.seam or "?", first_line(e.msg))
    end
  end
  return lines
end

local function sh_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
M.sh_quote = sh_quote

-- Shell pipeline returning the plugin-relevant tail of {log}.
function M.log_tail_cmd(log)
  return ("tail -c %d %s | grep -E '\"plugin\":|plugin=|failed to load package' | tail -n %d"):format(
    M.LOG_TAIL_BYTES,
    sh_quote(log),
    M.LOG_TAIL_LINES
  )
end

-- Captured once, when the first plugin of this process requires the module.
local process_start = os.time()

-- The IO half: an api table for M.collect built from maki's Lua API, every
-- piece feature-detected so a missing one only thins the report.
function M.maki_api()
  local api = {
    since = process_start - M.START_SLACK_SEC,
    empty = maki.json.decode("[]"),
  }
  if type(maki.api.list_plugins) == "function" then
    api.list_plugins = maki.api.list_plugins
  end
  local pack = maki.pack
  if type(pack) == "table" and type(pack.get) == "function" then
    api.pack_get = function()
      local list = pack.get()
      return list
    end
  end

  local function site_pack()
    local home = maki.uv.os_homedir()
    local data = maki.uv.os_getenv("XDG_DATA_HOME")
    if not data or data == "" then
      data = home and maki.fs.joinpath(home, ".local", "share") or nil
    end
    return data and maki.fs.joinpath(data, "maki", "site", "pack") or nil
  end

  local function dirs(path)
    local out = {}
    for _, e in ipairs(maki.fs.dir(path) or {}) do
      if e[2] == "directory" and e[1]:sub(1, 1) ~= "." then
        out[#out + 1] = e[1]
      end
    end
    return out
  end

  api.scan_packs = function()
    local root = site_pack()
    local out = {}
    if not root then
      return out
    end
    for _, group in ipairs(dirs(root)) do
      local gpath = maki.fs.joinpath(root, group)
      for _, name in ipairs(dirs(gpath)) do
        local path = maki.fs.joinpath(gpath, name)
        if name == "start" or name == "opt" then
          for _, child in ipairs(dirs(path)) do
            out[#out + 1] = { name = child, path = maki.fs.joinpath(path, child), kind = name }
          end
        else
          out[#out + 1] = { name = name, path = path }
        end
      end
    end
    return out
  end

  api.sources = function(path)
    local texts = {}
    local files = {}
    for _, sub in ipairs({ "plugin", "" }) do
      local dir = sub == "" and path or maki.fs.joinpath(path, sub)
      for _, e in ipairs(maki.fs.dir(dir) or {}) do
        if e[2] == "file" and (e[1]:match("%.lua$")) and (sub ~= "" or e[1] == "init.lua") then
          files[#files + 1] = maki.fs.joinpath(dir, e[1])
        end
      end
    end
    for _, f in ipairs(files) do
      texts[#texts + 1] = maki.fs.read(f)
    end
    return texts
  end

  if type(maki.fn) == "table" and type(maki.fn.jobstart) == "function" then
    api.log_lines = function()
      local logs = maki.env.logs_dir and maki.env.logs_dir()
      if not logs then
        return nil
      end
      local log = maki.fs.joinpath(logs, "maki.log")
      if not maki.fs.metadata(log) then
        return nil
      end
      local id = maki.fn.jobstart(M.log_tail_cmd(log))
      local res = id and maki.fn.jobwait(id, 10000)
      if not res then
        return nil
      end
      local lines = {}
      for l in (res.stdout or ""):gmatch("[^\n]+") do
        lines[#lines + 1] = l
      end
      return lines
    end
  end
  return api
end

return M
