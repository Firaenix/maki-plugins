-- When the current provider is cliproxy, strip its MCP alias decoration from
-- tool names. CLIProxyAPI cloaks non-Claude-Code tools as
-- mcp__<w1>_<w2>__<decoration>_<name>. The proxy reverses aliases in
-- tool_use.name fields, but tool names inside strings (code_execution.code,
-- batch.tool_calls[].tool) are not reversed, so they reach dispatch decorated
-- and fail to resolve. This layer rewrites them back to the registered name
-- by stripping decoration words until we find a registered tool.
--
-- Only active when the provider is cliproxy. maki.api.get_tools() is
-- session-agnostic and needs no ctx, but the registry is not populated yet
-- when plugins load, so it is built lazily on first hook invocation and
-- cached.

local function is_cliproxy(ctx)
  local ok, snap = pcall(maki.session.read, { session = ctx.session_id })
  return ok and snap and type(snap.model) == "string" and snap.model:find("^cliproxy/") == 1
end

local registry = nil

local function get_registry()
  if registry then
    return registry
  end
  local ok, tools = pcall(maki.api.get_tools)
  if not ok or not tools then
    maki.log.warn("tool-alias: get_tools failed: " .. tostring(tools))
    return nil
  end
  local map = {}
  for _, t in ipairs(tools) do
    map[t.name] = t.name
    if t.alias then
      map[t.alias] = t.name
    end
  end
  if next(map) then
    registry = map -- only cache once populated; retry on an empty read
  end
  return map
end

local function is_lower_word(w)
  if #w < 2 then
    return false
  end
  for i = 1, #w do
    local b = w:byte(i)
    if b < 97 or b > 122 then
      return false
    end
  end
  return true
end

-- Strip mcp__<w1>_<w2>__<decoration>_<name> to <name>.
-- The alias format is: mcp__ + server pair (2 words) + __ + semantic suffix.
-- The semantic suffix is a decoration word (or words) + the canonical tool
-- name. We find "__" positions where the part before is exactly two
-- lowercase words and check if what follows (after stripping leading
-- decoration words) matches a registered tool name.
local function strip_alias(token, registry)
  if not token:find("^mcp__") then
    return nil
  end
  local without_mcp = token:sub(6) -- skip "mcp__"
  for i = #without_mcp - 2, 1, -1 do
    if without_mcp:sub(i, i + 1) == "__" then
      local prefix = without_mcp:sub(1, i - 1)
      local rest = without_mcp:sub(i + 2)
      local parts = {}
      for part in prefix:gmatch("[^_]+") do
        table.insert(parts, part)
      end
      if #parts == 2 and is_lower_word(parts[1]) and is_lower_word(parts[2]) then
        while rest:find("_") do
          if registry[rest] then
            return registry[rest]
          end
          local first_underscore = rest:find("_", 1, true)
          if not first_underscore then
            break
          end
          rest = rest:sub(first_underscore + 1)
        end
        if registry[rest] then
          return registry[rest]
        end
      end
    end
  end
  return nil
end

local function fix_code(code, registry)
  local changed = 0
  local out = code:gsub("[a-z0-9_]*_[a-z0-9_]*", function(token)
    local canon = strip_alias(token, registry)
    if canon then
      changed = changed + 1
      return canon
    end
    return token
  end)
  return out, changed
end

local function fix_tool_calls(entries, registry)
  local changed = 0
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and type(entry.tool) == "string" then
      local canon = strip_alias(entry.tool, registry)
      if canon and canon ~= entry.tool then
        maki.log.info(("tool-alias: batch call %s -> %s"):format(entry.tool, canon))
        entry.tool = canon
        changed = changed + 1
      end
    end
  end
  return changed
end

local function fix(input, registry)
  local changed = 0
  if type(input.code) == "string" then
    local code, n = fix_code(input.code, registry)
    if n > 0 then
      maki.log.info(("tool-alias: rewrote %d decorated tool name(s) in code"):format(n))
      input.code = code
      changed = changed + n
    end
  end
  if type(input.tool_calls) == "table" then
    changed = changed + fix_tool_calls(input.tool_calls, registry)
  end
  return changed > 0
end

local function make_layer()
  return function(prev, input, ctx)
    if type(input) ~= "table" or not is_cliproxy(ctx) then
      return prev(input, ctx)
    end
    local reg = get_registry()
    if reg then
      local ok, changed = pcall(fix, input, reg)
      if not ok then
        maki.log.warn("tool-alias: layer error: " .. tostring(changed))
      end
    end
    return prev(input, ctx)
  end
end

for _, tool in ipairs({ "batch", "code_execution" }) do
  local slot = "tool." .. tool .. ".input"
  local ok, err = pcall(maki.api.set_slot, slot, make_layer())
  if ok then
    maki.log.info("tool-alias: layering " .. slot)
  else
    maki.log.warn("tool-alias: could not wrap " .. slot .. ": " .. tostring(err))
  end
end
