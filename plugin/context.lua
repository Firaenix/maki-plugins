-- /context — omp-style context-window usage panel.
--
-- Core-first: window and pricing come from maki.model.info (fork stack/06),
-- which exposes what maki itself resolved — including catalog-fallback
-- rates and the subsidy tag for providers whose /v1/models returns bare
-- ids (cliproxy on Claude Max). When that API is missing (older maki) the
-- panel falls back to fetching the authorised providers' /v1/models
-- endpoints via the shared model_select discovery. The window is then
-- cross-checked across every authorised provider; pricing is only ever
-- shown from the *current* provider, since anyone else's rates aren't what
-- this session is billed at.

local model_select = require("model_select")

local GRID_COLS = 20
local GRID_ROWS = 10
local GRID_CELLS = GRID_COLS * GRID_ROWS
local GUTTER = "   "

local GLYPH_USED = "⛁"
local GLYPH_FREE = "⛶"
local GLYPH_BUFFER = "⛝"

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local TICK_MS = 150
local RESCAN_TICKS = 34 -- ~5s between session rescans (model-switch detection)

-- In-flight fetches keyed by provider slug, shared across open panels and
-- model switches so the same catalog is never fetched twice concurrently.
local fetching = {}

local function fmt(n)
  n = n or 0
  if n >= 1000000 then
    return (string.format("%.1fm", n / 1000000):gsub("%.0m$", "m"))
  end
  if n >= 1000 then
    return string.format("%.0fK", n / 1000)
  end
  return tostring(math.floor(n))
end

local function pct(part, whole)
  if not whole or whole <= 0 then
    return "0%"
  end
  local p = part / whole * 100
  if p > 0 and p < 0.05 then
    return "<0.1%"
  end
  return string.format("%.1f%%", p)
end

local function fmt_cost(n)
  if n >= 1 then
    return string.format("$%.2f", n)
  elseif n >= 0.01 then
    return string.format("$%.3f", n)
  elseif n > 0 then
    return string.format("$%.4f", n)
  end
  return "$0"
end

-- per-token rate -> "$X.XX/MTok"
local function fmt_rate(r)
  local m = r * 1e6
  if m >= 0.01 then
    return string.format("$%.2f", m)
  end
  return string.format("$%.4f", m)
end

local function pad(s, w)
  local dw = maki.ui.display_width(s)
  if dw >= w then
    return s
  end
  return s .. string.rep(" ", w - dw)
end

local function theme(name, fallback)
  return maki.ui.theme_color(name) or fallback
end

-- ---------------------------------------------------------------- lookup

-- Ids differ across providers (org prefix, dots vs dashes, :batch tier
-- suffix, [1m] context hint). Strip everything maki might append so the
-- real provider id can match the real catalog id.
local function norm_id(id)
  local bare = id:match("([^/]+)$") or id
  -- Walk backwards dropping any bracketed/colon-suffixed metadata maki or
  -- its model picker attach: [1m] for context, :batch for tier, etc.
  while true do
    local stripped = bare:gsub("%[.*$", ""):gsub(":.*$", ""):gsub("%-%s*$", "")
    if stripped == bare then
      break
    end
    bare = stripped
  end
  return bare:lower():gsub("%.", "-")
end

local function find_entry(entries, model_id)
  local want = norm_id(model_id)
  for _, e in ipairs(entries or {}) do
    if norm_id(e.id) == want then
      return e
    end
  end
  return nil
end

-- Resolve window + pricing for the current spec. Core answers first via
-- maki.model.info; the HTTP catalogs only fill what core couldn't. The
-- window otherwise comes from any provider that lists the model; pricing
-- only from st.provider.
local function resolve(st)
  local info = {}
  if maki.model and maki.model.info then
    local m = maki.model.info(st.spec)
    if m then
      info.window = m.context_window
      if m.pricing then
        -- Core rates are USD per MTok; the panel's math is per token.
        info.pricing = {
          prompt = m.pricing.input / 1e6,
          completion = m.pricing.output / 1e6,
          input_cache_write = m.pricing.cache_write / 1e6,
          input_cache_read = m.pricing.cache_read / 1e6,
        }
        info.subsidised_by = m.pricing.subsidised_by
      end
    end
  end
  local cur = find_entry(st.entries[st.provider], st.model_id)
  if cur then
    info.window = info.window or cur.context_length
    info.pricing = info.pricing or cur.pricing
  end
  if not info.window then
    for slug, entries in pairs(st.entries) do
      if slug ~= st.provider then
        local e = find_entry(entries, st.model_id)
        if e and e.context_length then
          info.window = e.context_length
          break
        end
      end
    end
  end
  st.info = info
end

-- Fetch catalogs the panel still needs: the current provider always (its
-- prices bill this session), and — only while the window is unknown — every
-- other authorised provider until one reports the model's window. Runs in
-- the background; st.dirty is set once fresh data lands so the event loop
-- re-renders.
local function ensure_info(st)
  resolve(st)
  if st.info.window and st.info.pricing then
    st.pending = false
    return
  end
  st.pending = true
  st.gen = (st.gen or 0) + 1
  local gen = st.gen
  st.inflight = 0

  -- Every fetch answered and pricing still didn't land: stop claiming to
  -- fetch, so build() renders the honest no-pricing note instead of an
  -- eternal spinner.
  local function fetch_done()
    if st.gen ~= gen then
      return
    end
    st.inflight = st.inflight - 1
    if st.inflight <= 0 and not (st.info.window and st.info.pricing) then
      st.pending = false
      st.dirty = true
    end
  end

  local function fetch(slug)
    if st.entries[slug] or fetching[slug] then
      return
    end
    fetching[slug] = true
    st.inflight = st.inflight + 1
    maki.async.run(function()
      local entries =
        model_select.fetch_provider(st.by_slug[slug] or { slug = slug, discover = true }, {})
      fetching[slug] = nil
      if st.gen == gen then
        st.entries[slug] = entries or {}
        resolve(st)
        -- Stop early once window + pricing are both known.
        if st.info.window and st.info.pricing then
          st.pending = false
        end
        st.dirty = true
      end
      fetch_done()
    end)
  end

  fetch(st.provider)
  if not st.info.window then
    for _, p in ipairs(st.providers) do
      if p.slug ~= st.provider then
        fetch(p.slug)
      end
    end
  end
  -- Nothing scheduled (all catalogs cached, or a fetch is owned by an
  -- earlier open): there is nothing more to wait for.
  if st.inflight == 0 then
    st.pending = false
  end
end

-- ---------------------------------------------------------------- session

-- What the agent loop reserves for the compaction pass. Mirrors the
-- agent.compaction_buffer key in init.lua ("N%" or absolute tokens);
-- defaults assume maki's own default of 20%.
local function compaction_buffer_tokens(window)
  local frac, abs = 0.2, nil
  local cfg_dir = maki.env.config_dir()
  if cfg_dir then
    local text = maki.fs.read(maki.fs.joinpath(cfg_dir, "init.lua"))
    if text then
      local p = text:match('compaction_buffer%s*=%s*"([%d%.]+)%%"')
      if p then
        frac = tonumber(p) / 100
      else
        local n = text:match("compaction_buffer%s*=%s*(%d+)")
        if n then
          abs = tonumber(n)
        end
      end
    end
  end
  local buf_tokens = abs or math.floor(window * frac)
  return buf_tokens
end

local function load_session(state_dir)
  local id = maki.session.current()
  if not id then
    -- No interactive UI (ACP/SDK): fall back to the cwd → session map.
    local latest = maki.fs.read(maki.fs.joinpath(state_dir, "sessions", "cwd_latest.json"))
    if latest then
      local ok, map = pcall(maki.json.decode, latest)
      if ok and type(map) == "table" then
        id = map[maki.uv.cwd()]
      end
    end
  end
  if not id then
    return nil, "no active session"
  end

  local content, err = maki.fs.read(maki.fs.joinpath(state_dir, "sessions", id .. ".jsonl"))
  if not content then
    return nil, err or "session file not found"
  end

  local sess = { id = id, msgs = 0 }
  for _, line in ipairs(maki.split(content, "\n")) do
    -- Only header/meta lines need parsing; msgs are just counted, which
    -- keeps large sessions cheap. Prefixes: msg=10, meta=11, header=13.
    local head = line:sub(1, 13)
    if head:sub(1, 10) == '{"t":"msg"' then
      sess.msgs = sess.msgs + 1
    elseif head:sub(1, 11) == '{"t":"meta"' then
      local ok, obj = pcall(maki.json.decode, line)
      if ok and type(obj) == "table" then
        sess.meta = obj
      end
    elseif head == '{"t":"header"' then
      local ok, obj = pcall(maki.json.decode, line)
      if ok and type(obj) == "table" then
        sess.header = obj
      end
    end
  end
  return sess
end

-- ---------------------------------------------------------------- render

local function build(st)
  local sess = st.sess
  local info = st.info or {}
  local meta = sess.meta or {}
  local used = meta.context_size or 0
  local usage = meta.token_usage or {}
  local window = info.window

  local buf_tokens = 0
  if window then
    buf_tokens = math.min(compaction_buffer_tokens(window), math.max(0, window - used))
  end
  local free_tokens = window and math.max(0, window - used - buf_tokens) or nil

  local used_color = theme("accent", "#7aa2f7")
  local buf_color = theme("warning", "#e0af68")
  local free_color = theme("dim", "#565f89")

  -- Grid cells: used, then free, then the compaction buffer at the tail.
  local cells = {}
  if window and window > 0 then
    local per_cell = window / GRID_CELLS
    local function ratio_cells(t)
      if t <= 0 then
        return 0
      end
      return math.max(1, math.floor(t / per_cell + 0.5))
    end
    local used_c = ratio_cells(used)
    local buf_c = ratio_cells(buf_tokens)
    if used_c + buf_c > GRID_CELLS then
      used_c = math.max(0, GRID_CELLS - buf_c)
    end
    for _ = 1, used_c do
      cells[#cells + 1] = { GLYPH_USED, used_color }
    end
    for _ = used_c + 1, GRID_CELLS - buf_c do
      cells[#cells + 1] = { GLYPH_FREE, free_color }
    end
    for _ = 1, buf_c do
      cells[#cells + 1] = { GLYPH_BUFFER, buf_color }
    end
  else
    for _ = 1, GRID_CELLS do
      cells[#cells + 1] = { GLYPH_FREE, free_color }
    end
  end

  local pretty = st.model_id:gsub("%-", " ")
  pretty = pretty:sub(1, 1):upper() .. pretty:sub(2)
  local legend = {}
  if window then
    legend[#legend + 1] =
      { { pretty, "bold" }, { string.format(" (%s context)", fmt(window)), "dim" } }
    legend[#legend + 1] = { { st.spec .. " · provider " .. st.provider, "dim" } }
  else
    legend[#legend + 1] = { { pretty, "bold" }, { " (window unknown)", "dim" } }
    legend[#legend + 1] = { { st.spec .. " · provider " .. st.provider, "dim" } }
  end
  if used > 0 and window then
    legend[#legend + 1] = {
      { fmt(used), "bold" },
      { "/" .. fmt(window) .. " tokens", "dim" },
      { " (" .. pct(used, window) .. ")", "dim" },
    }
  elseif used > 0 then
    legend[#legend + 1] = { { fmt(used) .. " tokens used", "bold" } }
  else
    legend[#legend + 1] = { { "no API turn yet", "dim" } }
  end
  legend[#legend + 1] = { { "" } }
  legend[#legend + 1] = { { "Usage", "dim" } }
  legend[#legend + 1] = {
    { GLYPH_USED .. " ", { fg = used_color } },
    { pad("Used", 18) },
    { pad(fmt(used), 8) },
    { pct(used, window), "dim" },
  }
  if buf_tokens > 0 then
    legend[#legend + 1] = {
      { GLYPH_BUFFER .. " ", { fg = buf_color } },
      { pad("Autocompact buffer", 18) },
      { pad(fmt(buf_tokens), 8) },
      { pct(buf_tokens, window), "dim" },
    }
  end
  if free_tokens then
    legend[#legend + 1] = {
      { GLYPH_FREE .. " ", { fg = free_color } },
      { pad("Free", 18) },
      { pad(fmt(free_tokens), 8) },
      { pct(free_tokens, window), "dim" },
    }
  end
  legend[#legend + 1] = { { "" } }
  legend[#legend + 1] = { { "Session totals", "dim" } }
  legend[#legend + 1] = {
    {
      string.format(
        "in %s · out %s · cache %s",
        fmt(usage.input_tokens or 0),
        fmt(usage.output_tokens or 0),
        fmt(usage.cache_read_input_tokens or 0)
      ),
      "dim",
    },
  }
  legend[#legend + 1] = {
    { string.format("%d messages · %s", sess.msgs, meta.title or "untitled"), "dim" },
  }

  -- Cost section. While the current provider's catalog is in flight the
  -- section is a spinner placeholder; it resolves to real rows (or vanishes
  -- when the provider publishes no prices) once data lands.
  local pricing = info.pricing
  if st.pending and not pricing then
    legend[#legend + 1] = { { "" } }
    legend[#legend + 1] = { { "Cost breakdown", "dim" } }
    legend[#legend + 1] = { { SPINNER[st.spinner] .. " fetching provider pricing…", "dim" } }
  elseif not (pricing and pricing.prompt and pricing.completion) then
    legend[#legend + 1] = { { "" } }
    legend[#legend + 1] = { { "Cost breakdown", "dim" } }
    legend[#legend + 1] = { { "  no published pricing for this provider", "dim" } }
  elseif pricing and pricing.prompt and pricing.completion then
    local input_t = usage.input_tokens or 0
    local cache_w_t = usage.cache_creation_input_tokens or 0
    local cache_r_t = usage.cache_read_input_tokens or 0
    local output_t = usage.output_tokens or 0
    -- Cache-write falls back to the plain input rate when the provider
    -- doesn't distinguish it; cache-read to input as well (conservative).
    local cost = {
      input = input_t * pricing.prompt,
      cache_write = cache_w_t * (pricing.input_cache_write or pricing.prompt),
      cache_read = cache_r_t * (pricing.input_cache_read or pricing.prompt),
      output = output_t * pricing.completion,
    }
    cost.total = cost.input + cost.cache_write + cost.cache_read + cost.output

    legend[#legend + 1] = { { "" } }
    legend[#legend + 1] = { { "Cost breakdown", "dim" } }
    legend[#legend + 1] = {
      {
        string.format(
          "  rates/MTok: in %s · out %s · cache %s",
          fmt_rate(pricing.prompt),
          fmt_rate(pricing.completion),
          fmt_rate(pricing.input_cache_read or pricing.prompt)
        ),
        "dim",
      },
    }
    if input_t > 0 then
      legend[#legend + 1] = {
        { pad("  Input", 18) },
        { pad(fmt(input_t), 10) },
        { fmt_cost(cost.input), "dim" },
      }
    end
    if cache_w_t > 0 then
      legend[#legend + 1] = {
        { pad("  Cache write", 18) },
        { pad(fmt(cache_w_t), 10) },
        { fmt_cost(cost.cache_write), "dim" },
      }
    end
    if cache_r_t > 0 then
      legend[#legend + 1] = {
        { pad("  Cache read", 18) },
        { pad(fmt(cache_r_t), 10) },
        { fmt_cost(cost.cache_read), "dim" },
      }
    end
    if output_t > 0 then
      legend[#legend + 1] = {
        { pad("  Output", 18) },
        { pad(fmt(output_t), 10) },
        { fmt_cost(cost.output), "dim" },
      }
    end
    legend[#legend + 1] = {
      { pad("  Total", 18), "bold" },
      { pad("", 10) },
      { fmt_cost(cost.total), "bold" },
    }
    if info.subsidised_by then
      -- The breakdown above is the list-price reference; the subscription
      -- already paid for these tokens.
      legend[#legend + 1] = {
        { "  billed $0 — covered by " .. info.subsidised_by, "dim" },
      }
    end
  end

  local rows = math.max(GRID_ROWS, #legend)
  local lines = {}
  for r = 1, rows do
    local spans = {}
    for c = 1, GRID_COLS do
      local cell = cells[(r - 1) * GRID_COLS + c]
      if cell then
        spans[#spans + 1] = { cell[1], { fg = cell[2] } }
      end
    end
    spans[#spans + 1] = { GUTTER }
    if legend[r] then
      for _, s in ipairs(legend[r]) do
        spans[#spans + 1] = s
      end
    end
    lines[r] = spans
  end

  local legend_w = 0
  for _, lg in ipairs(legend) do
    local w = 0
    for _, s in ipairs(lg) do
      w = w + maki.ui.display_width(s[1])
    end
    legend_w = math.max(legend_w, w)
  end
  local tsize = maki.ui.terminal_size()
  local width = math.max(40, math.min(tsize.cols - 4, GRID_COLS + 3 + legend_w + 4))
  local height = math.max(6, math.min(tsize.rows - 4, rows + 2))
  return lines, width, height
end

-- ---------------------------------------------------------------- command

maki.api.register_command({
  name = "/context",
  description = "Context window usage panel (used / buffer / free / cost)",
  handler = function()
    local state_dir = maki.env.state_dir()
    if not state_dir then
      maki.ui.flash("/context: cannot resolve maki state dir")
      return
    end
    local sess, err = load_session(state_dir)
    if not sess then
      maki.ui.flash("/context: " .. tostring(err))
      return
    end

    local providers = model_select.providers()
    local by_slug = {}
    for _, p in ipairs(providers) do
      by_slug[p.slug] = p
    end

    local function spec_parts(spec)
      local provider, model_id = (spec or "unknown"):match("^([^/]+)/(.+)$")
      if not provider then
        provider, model_id = "?", spec or "unknown"
      end
      return provider, model_id
    end

    local spec = (sess.header and sess.header.model) or "unknown"
    local provider, model_id = spec_parts(spec)
    local st = {
      sess = sess,
      spec = spec,
      provider = provider,
      model_id = model_id,
      providers = providers,
      by_slug = by_slug,
      entries = {}, -- slug -> catalog entries (from model_select's cache)
      spinner = 1,
      gen = 0,
    }

    ensure_info(st)

    local buf = maki.ui.buf()
    local lines, width, height = build(st)
    buf:set_lines(lines)

    local win = maki.ui.open_win(buf, {
      title = "Context",
      border = "rounded",
      width = width,
      height = height,
      footer = { { "q", "close" } },
    })

    local ticks = 0
    while true do
      local ev = win:recv(TICK_MS)
      if not ev or ev.type == "close" then
        break
      end
      if ev.type == "key" and (ev.key == "q" or ev.key == "esc") then
        break
      end
      if ev.type == "timeout" then
        ticks = ticks + 1
        -- Model switched while the panel is open: re-resolve and refetch.
        if ticks % RESCAN_TICKS == 0 then
          local fresh = load_session(state_dir)
          if fresh then
            st.sess = fresh
            local nspec = (fresh.header and fresh.header.model) or "unknown"
            if nspec ~= st.spec then
              local np, nm = spec_parts(nspec)
              st.spec, st.provider, st.model_id = nspec, np, nm
              ensure_info(st)
            end
            st.dirty = true
          end
        end
        if st.pending then
          st.spinner = st.spinner % #SPINNER + 1
          local l, w, h = build(st)
          buf:set_lines(l)
          win:set_config({ width = w, height = h })
        elseif st.dirty then
          st.dirty = false
          local l, w, h = build(st)
          buf:set_lines(l)
          win:set_config({ width = w, height = h })
        end
      end
    end
    win:close()
  end,
})
