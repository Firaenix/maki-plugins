-- "#" completion: insert a PR/MR link from the repo in cwd, via gh or glab.
--
-- Needs the fork's register_input_completer; on an older maki binary this
-- file is a no-op so startup keeps working.

if not maki.api.register_input_completer then
  return
end

local LIMIT = 15
local TIMEOUT_MS = 8000

-- Completer handlers run outside any tool-call task scope, so jobs must
-- be plugin-owned; the default owner = "task" refuses to start there.
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

-- The query and repo URL travel as env vars, never spliced into the
-- command line.
local function fetch(base, url, query)
  local cmd = base .. ' -R "$REPO"'
  if query ~= "" then
    cmd = cmd .. ' --search "$Q"'
  end
  local out = run(cmd, { REPO = url, Q = query })
  if not out then
    return nil
  end
  local parsed = maki.json.decode(out)
  if type(parsed) ~= "table" then
    return nil
  end
  return parsed
end

local function github_items(url, query)
  local prs = fetch("gh pr list --limit " .. LIMIT .. " --json number,title,url,author", url, query)
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

local function gitlab_items(url, query)
  local mrs = fetch("glab mr list --per-page " .. LIMIT .. " --output json", url, query)
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

maki.api.register_input_completer({
  trigger = "#",
  name = "forge-prs",
  handler = function(query)
    local f = forge()
    if not f then
      return {}
    end
    if f.kind == "github" then
      return github_items(f.url, query)
    end
    return gitlab_items(f.url, query)
  end,
})
