-- Replaces maki's builtin websearch (hosted Exa AI) with a self-hosted
-- SearXNG instance, so searches run against our container on the framework
-- instead of a third party. Ported from github.com/g4bwy/maki-plugins.
--
-- Inert unless SEARXNG_URL is exported (the dotfiles' maki wrapper exports it
-- on every host: the LAN address from the home network, the
-- search.firaenix.me vhost elsewhere). Returning before register_tool leaves
-- the builtin Exa tool in place wherever it is unset, which is also the only
-- way to avoid the shadow-tool registration error while the host's init.lua
-- keeps the builtin enabled. The instance must list json in its
-- search.formats (hosts/nixos-framework/containers/searxng/settings.yml).
--
-- When the instance is down or errors, the handler transparently falls back
-- to the builtin's Exa MCP path, mirrored from plugins/websearch/ in the
-- maki fork (providers.lua + parse_sse.lua inlined; those modules are
-- private to the builtin plugin scope). If upstream's Exa path changes
-- shape, this file is the drift.

local truncate = require("maki.truncate")
local ToolView = require("maki.tool_view")
local output_limits = require("maki.output_limits")

local base_url = maki.uv.os_getenv("SEARXNG_URL")
if not base_url or base_url == "" then
  maki.log.debug("websearch: SEARXNG_URL unset, leaving the builtin tool in place")
  return
end
base_url = base_url:gsub("/$", "")

-- The LAN path needs no credential; the public vhost answers 401 without it
-- (the dotfiles' Caddy reads the same key from agenix).
local api_key = maki.uv.os_getenv("SEARXNG_KEY")
if api_key == "" then
  api_key = nil
end

local DEFAULT_NUM_RESULTS = 8
local PROFILES = {
  fast = { categories = "general", timeout_secs = 10 },
  deep = { categories = "deep", timeout_secs = 30 },
}

-- No register_options here: no per-tool overrides, so resolve() always falls
-- through to the agent-wide agent.max_output_lines / max_output_bytes.
local opts = {}

-- The builtin's Exa path, kept working when SearXNG cannot answer. Keyless
-- by default; EXA_API_KEY upgrades it, exactly like the builtin does. (The
-- builtin trims the key because Lua treats "" as truthy and a blank header
-- would beat the keyless path.)
local EXA_ENDPOINT = "https://mcp.exa.ai/mcp"
local EXA_TIMEOUT_SECS = 25
local EXA_MAX_RESPONSE_BYTES = 5 * 1024 * 1024

local function exa_api_key()
  local key = (maki.uv.os_getenv("EXA_API_KEY") or ""):match("^%s*(.-)%s*$")
  return key ~= "" and key or nil
end

-- Rate limits and auth failures arrive as HTTP 200 carrying a jsonrpc error
-- or result.isError; without the failure check they'd read as "no results".
local function exa_parse_sse(body)
  for line in body:gmatch("[^\n]+") do
    local data = line:match("^data: (.+)")
    if data then
      local parsed, parse_err = maki.json.decode(data)
      if not parsed then
        return nil, "SSE JSON parse error: " .. parse_err
      end
      local err = parsed.error
      if err ~= nil then
        local message = type(err) == "table" and err.message or err
        return nil, "MCP error: " .. (type(message) == "string" and message or "unknown error")
      end
      if parsed.result and parsed.result.isError then
        local bad = parsed.result.content and parsed.result.content[1]
          and parsed.result.content[1].text
        return nil, "MCP tool error: " .. (bad or "unknown error")
      end
      local text = parsed.result and parsed.result.content
        and parsed.result.content[1] and parsed.result.content[1].text
      if type(text) == "string" and #text > 0 then
        return text
      end
    end
  end
  return "No search results found"
end

local function exa_search(query, num_results)
  local payload, encode_err = maki.json.encode({
    jsonrpc = "2.0",
    id = 1,
    method = "tools/call",
    params = {
      name = "web_search_exa",
      arguments = {
        query = query,
        numResults = num_results,
        type = "auto",
        livecrawl = "fallback",
      },
    },
  })
  if not payload then
    return nil, "failed to encode request: " .. tostring(encode_err)
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json, text/event-stream",
  }
  local key = exa_api_key()
  if key then
    headers["x-api-key"] = key
  end

  local resp, err = maki.net.request(EXA_ENDPOINT, {
    method = "POST",
    body = payload,
    headers = headers,
    timeout = EXA_TIMEOUT_SECS,
    max_bytes = EXA_MAX_RESPONSE_BYTES,
  })
  if not resp then
    return nil, tostring(err)
  end
  if resp.status < 200 or resp.status >= 300 then
    return nil, "HTTP " .. tostring(resp.status) .. ": " .. resp.body:sub(1, 200)
  end
  return exa_parse_sse(resp.body)
end

local function web_view_opts(ctx)
  local tol = ctx:tool_output_lines()
  return { max_lines = (tol and tol.web) or 3, keep = "head" }
end

local function url_encode(value)
  return (value:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function engine_note(unresponsive)
  if type(unresponsive) ~= "table" then
    return ""
  end
  local parts = {}
  for _, entry in ipairs(unresponsive) do
    if type(entry) == "table" and type(entry[1]) == "string" then
      local reason = entry[2]
      parts[#parts + 1] = type(reason) == "string" and (entry[1] .. ": " .. reason) or entry[1]
    end
  end
  if #parts == 0 then
    return ""
  end
  return "\n\n[unresponsive engines] " .. table.concat(parts, ", ")
end

local function format_results(results)
  local lines = {}
  for i, r in ipairs(results) do
    local parts = { "#" .. i .. " " .. (r.title or "Untitled") }
    if r.url then
      parts[#parts + 1] = r.url
    end
    if r.content then
      parts[#parts + 1] = r.content
    end
    lines[#lines + 1] = table.concat(parts, "\n")
  end
  return table.concat(lines, "\n\n")
end

local function searxng_search(input, base_url)
  local profile = PROFILES[input.profile or "fast"]
  local url = string.format(
    "%s/search?q=%s&format=json&categories=%s&pageno=1",
    base_url, url_encode(input.query), profile.categories
  )
  if input.language then
    url = url .. "&language=" .. url_encode(input.language)
  end

  local req_opts = { timeout = profile.timeout_secs }
  if api_key then
    req_opts.headers = { authorization = "Bearer " .. api_key }
  end
  local resp, err = maki.net.request(url, req_opts)
  if not resp then
    return nil, tostring(err)
  end
  if resp.status < 200 or resp.status >= 300 then
    return nil, "HTTP " .. tostring(resp.status) .. ": " .. resp.body:sub(1, 200)
  end

  local data, parse_err = maki.json.decode(resp.body)
  if not data then
    return nil, "failed to parse response: " .. tostring(parse_err)
  end

  local note = engine_note(data.unresponsive_engines)
  local results = data.results
  if not results or #results == 0 then
    return { text = "No search results found" .. note }
  end

  local num_results = input.num_results or DEFAULT_NUM_RESULTS
  if #results > num_results then
    local trimmed = {}
    for i = 1, num_results do
      trimmed[i] = results[i]
    end
    results = trimmed
  end
  return { text = format_results(results), note = note }
end

maki.api.register_tool({
  name = "websearch",
  kind = "fetch",
  description = "Search the web for real-time information using SearXNG.\n\n"
    .. "Today's date is "
    .. os.date("%Y-%m-%d")
    .. ".\n\n"
    .. "- Use for current events, documentation, APIs, or anything not in local files.\n"
    .. "- Prefer specific, targeted queries over broad ones.\n"
    .. "- Results include page titles, URLs, and content snippets.\n"
    .. "- `profile` picks the engine set. `fast` (default) answers in about a second and is "
    .. "right for nearly every query. `deep` adds news, academic and browser-backed engines, "
    .. "can take 25 seconds, and regularly reports failed engines; use it when a fast search "
    .. "came back thin, or when the query needs obscure sources or broad coverage.",

  schema = {
    type = "object",
    properties = {
      query = { type = "string", description = "Search query", required = true },
      num_results = { type = "integer", description = "Number of results to return (default 8)" },
      language = {
        type = "string",
        description = "Restrict results to a language: SearXNG code, e.g. \"en\", \"de\", \"zh-CN\". "
          .. "Omit to use the SearXNG instance's configured default.",
      },
      profile = {
        type = "string",
        enum = { "fast", "deep" },
        description = "Engine set. \"fast\" (default): ~1 s, general web engines. "
          .. "\"deep\": slower (up to ~25 s) and broader — news, academic and "
          .. "browser-backed engines. Pick it for coverage or obscure queries.",
      },
    },
  },
  permission = "net",
  permission_scopes = "query",
  audiences = { "main", "research_sub", "general_sub", "interpreter" },

  header = function(input)
    return input.query
  end,

  restore = function(_input, output, _is_error, ctx)
    return ToolView.restore(output, web_view_opts(ctx))
  end,

  handler = function(input, ctx)
    local query = input.query
    if not query then
      return { llm_output = "error: query is required", is_error = true }
    end

    local num_results = input.num_results or DEFAULT_NUM_RESULTS
    local max_lines, max_bytes = output_limits.resolve(opts, ctx)

    local out, searxng_err = searxng_search(input, base_url)
    if not out then
      -- SearXNG cannot answer: serve the builtin's Exa backend in its place.
      maki.log.warn("websearch: SearXNG failed (" .. searxng_err .. "), falling back to Exa")
      local text, exa_err = exa_search(query, num_results)
      if not text then
        return {
          llm_output = "error: SearXNG failed (" .. searxng_err .. "); Exa fallback failed (" .. exa_err .. ")",
          is_error = true,
        }
      end
      return {
        llm_output = truncate(text, max_lines, max_bytes),
        body = ToolView.restore(text, web_view_opts(ctx)),
      }
    end

    return {
      llm_output = truncate(out.text, max_lines, max_bytes) .. (out.note or ""),
      body = ToolView.restore(out.text .. (out.note or ""), web_view_opts(ctx)),
    }
  end,
})
