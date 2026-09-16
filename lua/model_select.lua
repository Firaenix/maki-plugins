-- Shared model catalog + picker used by automode and context.
--
-- Core-first (fork stack/06+07): the catalog comes from maki's own resolved
-- registry via maki.model.available() + maki.model.info(spec) -- pricing,
-- windows, tiers, free/subsidy flags included -- and the popup is the
-- native ratatui picker via maki.ui.picker. On an older maki binary both
-- fall back to the legacy path below: /v1/models discovery over curl (via
-- maki.fn.jobstart, because maki.net.request refuses the private IPs our
-- cliproxy + llama-cpp endpoints live on) and the Lua list_picker.
--
-- Public surface:
--   M.catalog(opts)  -> (entries, errors)
--   M.pick(opts)     -> (entry, err)
--   M.clear_cache([slug])
--
-- `entries[i]` = { spec, id, provider, provider_display, context_length?,
-- pricing? (per-TOKEN USD: prompt/completion/input_cache_write/
-- input_cache_read), tier?, free?, subsidised_by?, base_url?, protocol? }
-- where `spec = provider .. "/" .. id`, matching /model's spec format.

local ListPicker = require("maki.list_picker")

local M = {}

-- Built-in display-name / protocol hints for well-known slugs, so the picker
-- shows a friendly label even when providers.toml omits `display_name` or
-- `protocol`. This intentionally mirrors a subset of maki's ProviderKind
-- + builtin_provider tables. Unknown slugs fall back to the raw slug.
-- `base` is the discovery endpoint fallback used when providers.toml omits
-- `base_url` (or the whole entry). Public providers get a stable default;
-- local ones (llama-cpp, ollama) stay nil since ports vary per user.
local KNOWN = {
  anthropic = {
    display = "Anthropic",
    protocol = "anthropic",
    base = "https://api.anthropic.com",
  },
  openai = { display = "OpenAI", protocol = "openai", base = "https://api.openai.com/v1" },
  google = {
    display = "Google",
    protocol = "openai",
    base = "https://generativelanguage.googleapis.com/v1beta/openai",
  },
  mistral = { display = "Mistral", protocol = "openai", base = "https://api.mistral.ai/v1" },
  deepseek = {
    display = "DeepSeek",
    protocol = "openai",
    base = "https://api.deepseek.com/v1",
  },
  xai = { display = "xAI", protocol = "openai", base = "https://api.x.ai/v1" },
  zai = { display = "Z.ai", protocol = "openai", base = "https://api.z.ai/api/paas/v4" },
  openrouter = {
    display = "OpenRouter",
    protocol = "openai",
    base = "https://openrouter.ai/api/v1",
  },
  cliproxy = { display = "CLIProxy", protocol = "anthropic" },
  ["llama-cpp"] = { display = "llama.cpp", protocol = "openai" },
  ollama = { display = "Ollama", protocol = "openai" },
  copilot = { display = "GitHub Copilot", protocol = "openai" },
  synthetic = {
    display = "Synthetic",
    protocol = "openai",
    base = "https://api.synthetic.new/v1",
  },
  tensorx = { display = "TensorX", protocol = "openai" },
  opencode = { display = "opencode", protocol = "openai" },
}

-- --------------------------------------------------------------- TOML reader

-- Tiny reader for the shape providers.toml actually uses: `[section]`
-- headers with `key = "value"` or `key = true/false/<number>` beneath.
-- Nested tables, arrays, and multi-line strings are not needed for
-- providers.toml, so we don't parse them; falls through silently.
local function parse_toml(text)
  local out = {}
  local section
  for raw in text:gmatch("[^\r\n]+") do
    local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match("^#") then
      local header = line:match("^%[(.+)%]$")
      if header then
        section = header
        out[section] = out[section] or {}
      elseif section then
        local key, val = line:match("^([%w_%-]+)%s*=%s*(.+)$")
        if key and val then
          -- strip trailing comment
          val = val:gsub("%s+#.*$", "")
          local s = val:match('^"(.-)"$') or val:match("^'(.-)'$")
          if s then
            out[section][key] = s
          elseif val == "true" then
            out[section][key] = true
          elseif val == "false" then
            out[section][key] = false
          elseif tonumber(val) then
            out[section][key] = tonumber(val)
          else
            out[section][key] = val
          end
        end
      end
    end
  end
  return out
end

M.parse_toml = parse_toml

-- ---------------------------------------------------------------- providers

local providers_cache
local providers_cache_at = 0
local PROVIDERS_TTL_SECS = 30

-- Locate providers.toml. `maki.env.config_dir()` is the canonical answer;
-- fall back to $XDG_CONFIG_HOME/maki or ~/.config/maki. Called lazily so
-- plugin load never hits the fs (which would need an async runtime).
local function providers_path()
  local dir
  if maki.env and maki.env.config_dir then
    local ok, d = pcall(maki.env.config_dir)
    if ok and d then
      dir = d
    end
  end
  if not dir then
    local xdg = maki.uv.os_getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then
      dir = maki.fs.joinpath(xdg, "maki")
    else
      local home = maki.uv.os_homedir() or "~"
      dir = maki.fs.joinpath(home, ".config", "maki")
    end
  end
  return maki.fs.joinpath(dir, "providers.toml")
end

local function normalize_base(url)
  if not url or url == "" then
    return url
  end
  -- Strip well-known suffixes so we can safely append /v1/models. Users
  -- (and our KNOWN defaults) point base_url at a mix of forms: bare host,
  -- `.../v1`, `.../v1/messages`, etc. Normalise them all down to the
  -- version-less root; fetch_provider then always appends `/v1/models`.
  url = url:gsub("/+$", "")
  url = url:gsub("/v1/messages$", "")
  url = url:gsub("/v1/chat/completions$", "")
  url = url:gsub("/v1/completions$", "")
  url = url:gsub("/v1/responses$", "")
  url = url:gsub("/v1$", "")
  return url
end

-- Load and normalize every provider defined in providers.toml. Returns a
-- list of { slug, display, protocol, base_url, api_key_env, discover }
-- ordered alphabetically by display name (matching /model).
function M.providers()
  local now = os.time()
  if providers_cache and (now - providers_cache_at) < PROVIDERS_TTL_SECS then
    return providers_cache
  end

  local list = {}
  local path = providers_path()
  local text = nil
  local ok, res = pcall(maki.fs.read, path)
  if ok and type(res) == "string" then
    text = res
  end

  local doc = text and parse_toml(text) or {}
  for slug, tbl in pairs(doc) do
    if type(tbl) == "table" then
      local known = KNOWN[slug] or {}
      local display = tbl.display_name or known.display or slug
      local protocol = tbl.protocol or known.protocol or "openai"
      -- Fall back to the KNOWN default base when the toml omits base_url
      -- so public providers (openrouter, mistral, ...) work with just an
      -- api_key_env entry. Normalize both paths — KNOWN bases end in /v1
      -- and would double-append without stripping.
      local base = normalize_base(tbl.base_url or known.base)
      local discover = tbl.discover_models
      if discover == nil then
        discover = true
      end
      list[#list + 1] = {
        slug = slug,
        display = display,
        protocol = protocol,
        base_url = base,
        api_key_env = tbl.api_key_env,
        discover = discover,
      }
    end
  end

  -- Fill in any well-known providers that aren't in providers.toml so the
  -- picker still exposes them (e.g. someone with a CLIPROXY_API_KEY but no
  -- entry in the file). Providers with a default base can still be probed;
  -- ones without stay listed but non-discoverable.
  local seen = {}
  for _, p in ipairs(list) do
    seen[p.slug] = true
  end
  for slug, k in pairs(KNOWN) do
    if not seen[slug] then
      list[#list + 1] = {
        slug = slug,
        display = k.display,
        protocol = k.protocol,
        base_url = normalize_base(k.base),
        api_key_env = nil,
        discover = k.base ~= nil,
      }
    end
  end

  table.sort(list, function(a, b)
    return a.display < b.display
  end)
  providers_cache = list
  providers_cache_at = now
  return list
end

function M.provider(slug)
  for _, p in ipairs(M.providers()) do
    if p.slug == slug then
      return p
    end
  end
  return nil
end

-- ---------------------------------------------------------------- discovery

local models_cache = {}

function M.clear_cache(slug)
  if slug then
    models_cache[slug] = nil
  else
    models_cache = {}
    providers_cache = nil
  end
end

-- Build the curl auth-header flags for a provider. Passes the API key via
-- shell env-var expansion ($VAR) rather than string interpolation so the
-- key never lands in the command line or logs. Double-quoted (single
-- quotes suppress $VAR expansion) — matches automode's auth_header.
-- Empty string when no key env is set (llama-cpp typically runs open).
local function auth_flags(provider)
  if not provider.api_key_env or provider.api_key_env == "" then
    return ""
  end
  if provider.protocol == "anthropic" then
    return ' -H "x-api-key: $'
      .. provider.api_key_env
      .. '"'
      .. ' -H "anthropic-version: 2023-06-01"'
  end
  return ' -H "Authorization: Bearer $' .. provider.api_key_env .. '"'
end

local function parse_response(body, provider)
  local ok, doc = pcall(maki.json.decode, body)
  if not ok or type(doc) ~= "table" then
    return nil, "response was not JSON"
  end
  local arr = doc.data or doc.models
  if type(arr) ~= "table" then
    return nil, "response missing `data` array"
  end
  local out = {}
  for _, m in ipairs(arr) do
    local id = (type(m) == "table") and (m.id or m.name) or nil
    if type(id) == "string" and id ~= "" then
      local entry = {
        id = id,
        spec = provider.slug .. "/" .. id,
        provider = provider.slug,
        provider_display = provider.display,
        base_url = provider.base_url,
        protocol = provider.protocol,
      }
      -- Window: plain fields first (OpenRouter's context_length), then
      -- top_provider (OpenRouter wraps the upstream limit there), then the
      -- llama-server wrapper shape (status.args / status.preset).
      for _, k in ipairs({ "context_length", "context_window", "max_context_length", "max_tokens" }) do
        if type(m[k]) == "number" and m[k] > 0 then
          entry.context_length = m[k]
          break
        end
      end
      if not entry.context_length and type(m.top_provider) == "table" then
        local w = m.top_provider.context_length
        if type(w) == "number" and w > 0 then
          entry.context_length = w
        end
      end
      if not entry.context_length and type(m.status) == "table" then
        local args = m.status.args
        if type(args) == "table" then
          for i, a in ipairs(args) do
            if a == "--ctx-size" then
              local v = tonumber(args[i + 1])
              if v then
                entry.context_length = v
                break
              end
            elseif type(a) == "string" then
              local v = a:match("%-%-ctx%-size[= ]+(%d+)")
              if v then
                entry.context_length = tonumber(v)
                break
              end
            end
          end
        end
        if not entry.context_length and type(m.status.preset) == "string" then
          local v = m.status.preset:match("ctx%-size%s*=%s*(%d+)")
          if v then
            entry.context_length = tonumber(v)
          end
        end
      end
      -- Pricing: OpenRouter reports USD per token as strings; keep the raw
      -- keys verbatim so consumers see whatever the provider publishes.
      if type(m.pricing) == "table" then
        local p = {}
        for k, v in pairs(m.pricing) do
          local n = tonumber(v)
          if n then
            p[k] = n
          end
        end
        if next(p) then
          entry.pricing = p
        end
      end
      out[#out + 1] = entry
    end
  end
  return out, nil
end

M.parse_response = parse_response

local function fetch_provider(provider, opts)
  if not provider.discover then
    maki.log.info("model_select.fetch " .. provider.slug .. " skipped: discover disabled")
    return nil, "discover_models disabled"
  end
  local base = opts.url or provider.base_url
  if not base then
    maki.log.info("model_select.fetch " .. provider.slug .. " skipped: no base_url")
    return nil, "no base_url configured"
  end
  local url = base:match("/v1/models$") and base or (base .. "/v1/models")

  local now = os.time()
  local hit = models_cache[provider.slug]
  local ttl = opts.ttl_secs or 600
  if hit and hit.url == url and (now - hit.at) < ttl then
    maki.log.info(
      "model_select.fetch "
        .. provider.slug
        .. " cache hit ("
        .. tostring(#hit.entries)
        .. " models)"
    )
    return hit.entries, nil
  end

  maki.log.info("model_select.fetch " .. provider.slug .. " GET " .. url)
  -- Curl over jobstart, same pattern as automode's classify path. maki.net
  -- would be nicer but its SSRF guard blocks 127.0.0.1 (`maki-lua/src/api/
  -- net.rs:269`), which is exactly where cliproxy + llama-cpp live.
  local timeout_secs = opts.timeout_secs or 5
  local cmd = "curl -sS -m "
    .. tostring(timeout_secs)
    .. " -H 'accept: application/json'"
    .. auth_flags(provider)
    .. " -w '\\n__STATUS__%{http_code}' "
    .. "'"
    .. url:gsub("'", "'\\''")
    .. "'"
  local job = maki.fn.jobstart(cmd)
  local result = maki.fn.jobwait(job, timeout_secs * 1000 + 1000)
  if not result then
    maki.fn.jobstop(job)
    return nil, "timeout"
  end
  if result.exit_code ~= 0 then
    return nil, "curl exit " .. tostring(result.exit_code)
  end

  -- Split off the trailing __STATUS__NNN so we get body + status without
  -- a second HEAD request or the -o /dev/null dance.
  local body, status = (result.stdout or ""):match("^(.-)\n__STATUS__(%d+)%s*$")
  if not body then
    body = result.stdout or ""
    status = "200" -- best-effort: no marker means curl didn't populate one
  end
  maki.log.info("model_select.fetch " .. provider.slug .. " -> status=" .. status)
  if status ~= "200" then
    return nil, "HTTP " .. status
  end

  local entries, parse_err = parse_response(body, provider)
  if not entries then
    return nil, parse_err
  end
  if #entries == 0 then
    return nil, "empty model list"
  end

  models_cache[provider.slug] = { at = now, url = url, entries = entries }
  return entries, nil
end

M.fetch_provider = fetch_provider

-- ---------------------------------------------------------------- catalog

-- Gather models from providers. By default: every provider from
-- providers.toml (matching /model's "show everything" behaviour). Pass
-- opts.providers to restrict.
--
-- opts.providers          string[] of slugs; defaults to all discoverable.
-- opts.per_provider_urls  slug -> url override (rarely needed; TOML wins).
-- opts.ttl_secs           per-provider cache TTL (default 600).
-- opts.timeout_secs       per-request HTTP timeout (default 5).
--
-- Returns (entries, errors) where entries is a flat list sorted by
-- provider display then model id, and errors is a slug -> reason map for
-- providers that returned nothing.
-- Core path: everything maki already resolved, one info() per spec. No
-- network, no TOML parsing, and it sees pricing the /v1/models endpoints
-- never report (declared metadata, catalog fallback, subsidised providers).
local function core_catalog(opts)
  if not (maki.model and maki.model.info and maki.model.available) then
    return nil
  end
  local specs = maki.model.available()
  if not specs or #specs == 0 then
    return nil
  end
  local filter
  if opts.providers then
    filter = {}
    for _, s in ipairs(opts.providers) do
      filter[s] = true
    end
  end
  local entries = {}
  for _, spec in ipairs(specs) do
    local m = maki.model.info(spec)
    if m and (not filter or filter[m.provider]) then
      local pricing
      if m.pricing then
        -- Core rates are USD per MTok; consumers do per-token math.
        pricing = {
          prompt = m.pricing.input / 1e6,
          completion = m.pricing.output / 1e6,
          input_cache_write = m.pricing.cache_write / 1e6,
          input_cache_read = m.pricing.cache_read / 1e6,
        }
      end
      entries[#entries + 1] = {
        spec = m.spec,
        id = m.id,
        provider = m.provider,
        provider_display = m.provider_display,
        context_length = m.context_window,
        pricing = pricing,
        tier = m.tier,
        free = m.free,
        subsidised_by = m.pricing and m.pricing.subsidised_by or nil,
      }
    end
  end
  if #entries == 0 then
    return nil
  end
  table.sort(entries, function(a, b)
    if a.provider_display ~= b.provider_display then
      return a.provider_display < b.provider_display
    end
    return a.id < b.id
  end)
  return entries
end

function M.catalog(opts)
  opts = opts or {}
  local core = core_catalog(opts)
  if core then
    maki.log.info("model_select.catalog: core path, " .. tostring(#core) .. " model(s)")
    return core, {}
  end
  local all_providers = M.providers()
  maki.log.info("model_select.catalog: " .. tostring(#all_providers) .. " provider(s) known")

  local filter
  if opts.providers then
    filter = {}
    for _, s in ipairs(opts.providers) do
      filter[s] = true
    end
  end

  local combined = {}
  local errors = {}

  for _, provider in ipairs(all_providers) do
    if not filter or filter[provider.slug] then
      local per_url = opts.per_provider_urls and opts.per_provider_urls[provider.slug]
      local entries, err = fetch_provider(provider, {
        url = per_url,
        ttl_secs = opts.ttl_secs,
        timeout_secs = opts.timeout_secs,
      })
      if entries then
        for _, e in ipairs(entries) do
          combined[#combined + 1] = e
        end
      else
        errors[provider.slug] = err
      end
    end
  end

  -- Same order as /model: provider display asc, then id asc.
  table.sort(combined, function(a, b)
    if a.provider_display ~= b.provider_display then
      return a.provider_display < b.provider_display
    end
    return a.id < b.id
  end)

  return combined, errors
end

-- ---------------------------------------------------------------- picker

-- Group entries by provider_display and count them, then build ListPicker
-- items with section/section_detail so the picker renders one dim header
-- per provider (matching /model). Adjacent entries with the same
-- provider_display are already contiguous thanks to catalog()'s sort.
local function build_items(catalog)
  local counts = {}
  for _, e in ipairs(catalog) do
    counts[e.provider_display] = (counts[e.provider_display] or 0) + 1
  end
  local items = {}
  for _, e in ipairs(catalog) do
    items[#items + 1] = {
      label = e.id,
      detail = e.provider,
      section = e.provider_display,
      section_detail = "(" .. tostring(counts[e.provider_display]) .. ")",
    }
  end
  return items
end

M.build_items = build_items

-- Compact price column for the native picker: what one MTok in/out costs,
-- or the flags that matter more than the rates.
local function price_hint(e)
  if e.subsidised_by then
    return "$0 · " .. e.subsidised_by
  end
  if e.free then
    return "free"
  end
  local p = e.pricing
  if p and p.prompt and p.completion then
    return string.format("$%.3g/$%.3g", p.prompt * 1e6, p.completion * 1e6)
  end
  return nil
end

-- Native path: maki.ui.picker (fork stack/07) renders the same ratatui
-- picker /model uses; this side only supplies rows. R re-runs discovery
-- through core and reopens over the fresh catalog.
local function native_pick(catalog, opts)
  while true do
    local items = {}
    local initial
    for _, e in ipairs(catalog) do
      items[#items + 1] = {
        label = e.id,
        detail = price_hint(e) or e.provider,
        section = e.provider_display,
        data = e.spec,
      }
      if opts.initial_spec and e.spec == opts.initial_spec then
        -- Preselect matches by label; duplicate ids across providers
        -- land on the first, which is close enough for a cursor hint.
        initial = e.id
      end
    end
    local res, err = maki.ui.picker(items, {
      title = opts.title or " Models ",
      initial = initial,
      keys = { { key = "R", hint = "refresh" } },
    })
    if not res then
      return nil, err or "cancelled"
    end
    if res.key == "R" then
      if maki.model.refresh then
        maki.model.refresh({ live = true })
      end
      catalog = core_catalog(opts) or catalog
    else
      local entry = catalog[res.index]
      if not entry then
        return nil, "picker returned invalid index"
      end
      return entry, nil
    end
  end
end

-- Open the picker over a catalog (auto-discovered if not passed) and
-- return the chosen entry.
--
-- opts.title         string shown at the top.
-- opts.footer        string shown at the bottom (legacy picker only).
-- opts.providers     restrict discovery to these slugs.
-- opts.catalog       skip discovery, use this list directly.
-- opts.initial_spec  pre-select the row whose entry.spec matches.
--
-- Returns (entry, nil) on choice, (nil, "cancelled") on close, or
-- (nil, err) when nothing can be shown.
function M.pick(opts)
  opts = opts or {}
  maki.log.info("model_select.pick: entered")
  local catalog = opts.catalog
  local errors
  if not catalog then
    catalog, errors = M.catalog(opts)
  end
  maki.log.info(
    "model_select.pick: catalog has " .. tostring(catalog and #catalog or 0) .. " entries"
  )

  if not catalog or #catalog == 0 then
    local parts = {}
    if errors then
      for slug, err in pairs(errors) do
        parts[#parts + 1] = slug .. ": " .. err
      end
    end
    local msg = "no models discovered"
    if #parts > 0 then
      msg = msg .. " (" .. table.concat(parts, "; ") .. ")"
    end
    return nil, msg
  end

  if maki.ui and maki.ui.picker then
    return native_pick(catalog, opts)
  end

  local initial
  if opts.initial_spec then
    for i, e in ipairs(catalog) do
      if e.spec == opts.initial_spec then
        initial = i
        break
      end
    end
  end

  local footer = opts.footer
  if errors and next(errors) then
    local parts = {}
    for slug, err in pairs(errors) do
      parts[#parts + 1] = slug .. ": " .. err
    end
    local warn = "unreachable: " .. table.concat(parts, ", ")
    footer = footer and (footer .. "  |  " .. warn) or warn
  end

  local result = ListPicker.open(build_items(catalog), {
    title = opts.title or " Models ",
    footer = footer,
    cursor = initial,
  })

  if not result or result.type ~= "choice" then
    return nil, "cancelled"
  end
  local entry = catalog[result.index]
  if not entry then
    return nil, "picker returned invalid index"
  end
  return entry, nil
end

return M
