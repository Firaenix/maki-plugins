-- "#" completion: insert a PR/MR link from the repo in cwd, via gh or glab.
--
-- Needs maki.ui.input and friends; on an older maki binary this file is a
-- no-op so startup keeps working.

if not maki.ui.input then
  return
end

local InputPopup = require("input_popup")

-- Fetched in one go and filtered in Lua, so this is how deep the list of open
-- PRs goes rather than how many rows are on screen.
local FETCH_LIMIT = 100
local ROWS = 10
local TIMEOUT_MS = 8000
-- Seconds a fetched list stays usable. The old host API called the completer
-- per keystroke and coalesced for us; this one does not, and `gh pr list` is a
-- network call. A list a minute out of date costs the user a PR that will be
-- there next time, which beats a request per keystroke by a mile.
local CACHE_TTL = 60

-- Handlers run outside any tool-call task scope, so jobs must be
-- plugin-owned; the default owner = "task" refuses to start there.
local function run(cmd, env)
  local id = maki.fn.jobstart(cmd, { env = env, owner = "plugin" })
  local res = maki.fn.jobwait(id, TIMEOUT_MS)
  if not res or res.exit_code ~= 0 or not res.stdout or res.stdout == "" then
    return nil
  end
  return res.stdout
end

-- A fork's PRs live on upstream, so that remote wins when present. The
-- jj fallback covers jj workspaces, which have no .git for git/gh/glab
-- to sniff — everything downstream passes the URL explicitly via -R.
local function remote_url()
  for _, remote in ipairs({ "upstream", "origin" }) do
    local url = run("git remote get-url " .. remote .. " 2>/dev/null")
      or run("jj git remote list 2>/dev/null | grep '^" .. remote .. " ' | cut -d' ' -f2")
    url = url and url:match("%S+")
    if url then
      return url
    end
  end
  return nil
end

-- { kind, url } or false, keyed by cwd so /cd re-detects
local forges = {}

local function forge()
  local cwd = maki.uv.cwd() or ""
  local cached = forges[cwd]
  if cached ~= nil then
    return cached
  end
  local url = remote_url()
  local detected = false
  if url and url:find("github", 1, true) then
    detected = { kind = "github", url = url }
  elseif url and url:find("gitlab", 1, true) then
    detected = { kind = "gitlab", url = url }
  end
  forges[cwd] = detected
  return detected
end

-- The repo URL travels as an env var, never spliced into the command line.
-- Nothing else reaches the shell now: the query is no longer a `--search`
-- argument at all, because the whole list is fetched once and narrowed in Lua.
local function fetch(base, url)
  local out = run(base .. ' -R "$REPO"', { REPO = url })
  if not out then
    return nil
  end
  local parsed = maki.json.decode(out)
  if type(parsed) ~= "table" then
    return nil
  end
  return parsed
end

local function github_items(url)
  local prs = fetch("gh pr list --limit " .. FETCH_LIMIT .. " --json number,title,url,author", url)
  if not prs then
    return nil
  end
  local items = {}
  for _, pr in ipairs(prs) do
    items[#items + 1] = {
      label = "#" .. pr.number .. " " .. (pr.title or ""),
      insert = pr.url,
      detail = pr.author and pr.author.login or nil,
    }
  end
  return items
end

local function gitlab_items(url)
  local mrs = fetch("glab mr list --per-page " .. FETCH_LIMIT .. " --output json", url)
  if not mrs then
    return nil
  end
  local items = {}
  for _, mr in ipairs(mrs) do
    items[#items + 1] = {
      label = "!" .. mr.iid .. " " .. (mr.title or ""),
      insert = mr.web_url,
      detail = mr.author and mr.author.username or nil,
    }
  end
  return items
end

-- { items | false, at }, keyed by cwd for the same reason the forge is.
local lists = {}

-- One round trip per cwd per TTL, unfiltered. The popup calls this on every
-- keystroke and does its own narrowing, so everything after the first `#`
-- costs nothing.
local function items()
  local cwd = maki.uv.cwd() or ""
  local hit = lists[cwd]
  if hit and os.time() - hit.at < CACHE_TTL then
    return hit.items or nil
  end
  local f = forge()
  if not f then
    return nil
  end
  local fetched
  if f.kind == "github" then
    fetched = github_items(f.url)
  else
    fetched = gitlab_items(f.url)
  end
  -- A failure is cached as well, for the same TTL. An unauthenticated gh or a
  -- forge that is down would otherwise pay the full 8s timeout again on the
  -- next keystroke, and the one after that.
  lists[cwd] = { items = fetched or false, at = os.time() }
  return fetched
end

InputPopup.attach({
  trigger = "#",
  name = "forge-prs",
  max_items = ROWS,
  pending = "loading...",
  items = items,
  insert = function(item)
    return item.insert .. " "
  end,
})
