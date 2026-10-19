-- A small harness for describe's pure modules, run under the luau CLI:
--
--   nix run nixpkgs#luau -- tests/describe_spec.lua
--
-- maki's own plugin specs run inside a maki build. These modules make no maki
-- calls, so plain luau is enough and the pack needs no build to be tested.

local M = {}

local failures = {}
local passed = 0

local function dump(v)
  if type(v) ~= "table" then
    return type(v) == "string" and string.format("%q", v) or tostring(v)
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. dump(v[k])
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. tostring(err)
  end
end

function M.eq(actual, expected, msg)
  if actual ~= expected then
    local text =
      string.format("%s\nexpected: %s\n  actual: %s", msg or "", dump(expected), dump(actual))
    error(text, 2)
  end
end

-- Compares tables by content, so a test can state a whole rendered line.
function M.same(actual, expected, msg)
  local a, e = dump(actual), dump(expected)
  if a ~= e then
    error(string.format("%s\nexpected: %s\n  actual: %s", msg or "", e, a), 2)
  end
end

function M.report()
  for _, failure in ipairs(failures) do
    print("FAIL " .. failure)
  end
  print(string.format("%d passed, %d failed", passed, #failures))
  if #failures > 0 then
    error(#failures .. " failing case(s)", 0)
  end
end

return M
