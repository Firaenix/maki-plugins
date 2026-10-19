-- plugins — `/plugins` lists every plugin this maki knows, its status, what
-- it registered and its recent errors. Data comes from lua/plugins_core.lua:
-- maki.api.list_plugins() on the fork, else a pack scan plus maki.log.
--
-- Sections: Errors, then Loaded, then Disabled. Enter opens the detail pane
-- (path, commands, tools, last 20 errors). Y copies the newest error, R
-- refreshes; both are uppercase because lowercase keys feed the filter.
-- A toast at startup flags plugins that failed to load.

local Core = require("plugins_core")
local ListPicker = require("maki.list_picker")
local Toast = require("maki.toast")
if type(Toast) ~= "table" or type(Toast.show) ~= "function" then
  Toast = {
    show = function(text, opts)
      maki.ui.flash(((opts and opts.title) and (opts.title .. ": ") or "") .. tostring(text))
    end,
  }
end

local TICK_MS = 200
local STARTUP_DELAY_MS = 2000

local function collect()
  local ok, res = pcall(Core.collect, Core.maki_api())
  if not ok then
    maki.log.warn("plugins: collect failed: " .. tostring(res))
    return { plugins = {}, source = "fallback" }
  end
  return res
end

local function clipboard_cmd()
  for _, c in ipairs({ "pbcopy", "wl-copy", "xclip -selection clipboard", "xsel -b" }) do
    if maki.fn.executable(c:match("^%S+")) == 1 then
      return c
    end
  end
  return nil
end

local function copy(text)
  local cmd = clipboard_cmd()
  if not cmd then
    return false, "no clipboard tool (pbcopy, wl-copy, xclip, xsel)"
  end
  local tmp = maki.fs.joinpath(maki.env.state_dir(), "plugins-copy.txt")
  maki.fs.write(tmp, text)
  local id, err = maki.fn.jobstart(cmd .. " < " .. Core.sh_quote(tmp))
  if not id then
    return false, err
  end
  local res = maki.fn.jobwait(id, 5000)
  maki.fs.rm(tmp)
  return res ~= nil and res.exit_code == 0, res and res.stderr or "timed out"
end

local function copy_error(p)
  local text = p and Core.error_text(p)
  if not text then
    maki.ui.flash("no error to copy")
    return
  end
  local ok, err = copy(text)
  maki.ui.flash(ok and ("copied " .. p.name .. " error") or ("copy failed: " .. tostring(err)))
end

local function show_detail(p)
  local tsize = maki.ui.terminal_size()
  local lines = {}
  local width = 40
  for _, l in ipairs(Core.detail_lines(p)) do
    local style = l:match("^  ") and "muted" or "item"
    lines[#lines + 1] = { { l, style } }
    width = math.max(width, maki.ui.display_width(l) + 4)
  end
  local buf = maki.ui.buf()
  buf:set_lines(lines)
  local win = maki.ui.open_win(buf, {
    title = " " .. p.name .. " ",
    border = "rounded",
    width = math.min(width, tsize.cols - 4),
    height = math.min(#lines + 2, tsize.rows - 4),
    footer = { { "Y", "copy error" }, { "q", "back" } },
  })
  while true do
    local ev = win:recv(TICK_MS)
    if not ev or ev.type == "close" then
      break
    end
    if ev.type == "key" then
      if ev.key == "q" or ev.key == "<Esc>" then
        break
      elseif ev.key == "Y" or ev.key == "y" then
        copy_error(p)
      end
    end
  end
  win:close()
end

local function open()
  local res = collect()
  local cursor = 1
  while true do
    local rows = Core.format(res.plugins)
    local summary = Core.summary(res.plugins)
    local title = (" Plugins (%d, %d with errors%s) "):format(
      summary.total,
      summary.errors,
      res.source == "fallback" and ", from logs" or ""
    )
    local pick = ListPicker.open(rows, {
      title = title,
      cursor = cursor,
      action_keys = { "Y", "R" },
      footer = { { "Enter", "detail" }, { "Y", "copy error" }, { "R", "refresh" } },
      key = function(row)
        return row.plugin and row.plugin.name
      end,
    })
    if pick.type == "close" then
      return
    end
    cursor = pick.index or cursor
    local p = pick.item and pick.item.plugin
    if pick.type == "choice" and p then
      show_detail(p)
    elseif pick.type == "key" and pick.key == "R" then
      res = collect()
    elseif pick.type == "key" and pick.key == "Y" then
      copy_error(p)
    end
  end
end

maki.api.register_command({
  name = "/plugins",
  description = "List plugins with their status, commands, tools and recent errors",
  handler = open,
})

-- Load failures are otherwise only in maki.log.
maki.async.spawn(function()
  maki.async.sleep(STARTUP_DELAY_MS)
  local res = collect()
  local failed = {}
  for _, p in ipairs(res.plugins) do
    if p.load_error then
      failed[#failed + 1] = p.name
    end
  end
  if #failed > 0 then
    pcall(
      Toast.show,
      table.concat(failed, ", ") .. "\n/plugins for details",
      { title = "plugins failed to load", timeout_secs = 10 }
    )
  end
end)
