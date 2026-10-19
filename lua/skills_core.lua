-- skills_core: the skill discovery the bundled `skill` tool does, shared by
-- /skills and the remote plugin's maki/skills.
--
-- Discovery mirrors the builtin exactly:
--   global:  $HOME/.claude/skills, $HOME/.config/opencode/skills,
--            $HOME/.agents/skills
--   config:  $XDG_CONFIG_HOME/maki/skills
--   project: <ancestor up to first .git>/{.maki,.claude,.opencode,.agents}/skills
--
-- Later paths override earlier ones by name (same as the builtin), so a
-- project-local skill shadows a global one of the same name.

local M = {}

local SKILL_FILE = "SKILL.md"

local PROJECT_SKILL_DIRS = {
  ".maki/skills",
  ".claude/skills",
  ".opencode/skills",
  ".agents/skills",
}
M.GLOBAL_SKILL_DIRS = {
  ".claude/skills",
  ".config/opencode/skills",
  ".agents/skills",
}

-- Inlined from plugins/skill/skill_helpers.lua; user plugins cannot
-- require modules from another plugin's dir.
local function parse_frontmatter(content)
  local rest = content:match("^%s*%-%-%-\n(.*)")
  if not rest then
    return {}, content
  end
  local end_pos = rest:find("\n%-%-%-")
  if not end_pos then
    return {}, content
  end
  local yaml_str = rest:sub(1, end_pos)
  local body = rest:sub(end_pos + 4):match("^%s*(.-)%s*$")
  local fm = maki.yaml.decode(yaml_str)
  return fm or {}, body
end

local function scan_skill_dir(dir, skills)
  local entries = maki.fs.dir(dir)
  if not entries then
    return
  end
  for _, entry in ipairs(entries) do
    if entry[2] == "directory" then
      local skill_path = maki.fs.joinpath(dir, entry[1], SKILL_FILE)
      local content = maki.fs.read(skill_path)
      if content then
        local fm, body = parse_frontmatter(content)
        if body and #body > 0 then
          local name = (fm and fm.name) or entry[1]
          skills[name] = {
            name = name,
            description = (fm and fm.description) or "",
            location = skill_path,
          }
        end
      end
    end
  end
end

local function find_project_ancestors(cwd)
  if not cwd then
    return {}
  end
  local dirs = { cwd }
  if maki.fs.metadata(maki.fs.joinpath(cwd, ".git")) then
    return dirs
  end
  for _, parent in ipairs(maki.fs.parents(cwd)) do
    dirs[#dirs + 1] = parent
    if maki.fs.metadata(maki.fs.joinpath(parent, ".git")) then
      break
    end
  end
  return dirs
end

-- name -> {name, description, location}. {cwd} defaults to maki's.
function M.discover(cwd)
  local skills = {}

  local config = maki.env.config_dir()
  if config then
    scan_skill_dir(maki.fs.joinpath(config, "skills"), skills)
  end

  local home = maki.uv.os_homedir()
  if home then
    for _, rel in ipairs(M.GLOBAL_SKILL_DIRS) do
      scan_skill_dir(maki.fs.joinpath(home, rel), skills)
    end
  end

  for _, ancestor in ipairs(find_project_ancestors(cwd or maki.uv.cwd())) do
    for _, rel in ipairs(PROJECT_SKILL_DIRS) do
      scan_skill_dir(maki.fs.joinpath(ancestor, rel), skills)
    end
  end

  return skills
end

-- Sorted by name, in the maki/skills wire shape.
function M.list(cwd)
  local out = {}
  for _, s in pairs(M.discover(cwd)) do
    out[#out + 1] = {
      name = s.name,
      description = type(s.description) == "string" and s.description or "",
      path = s.location,
    }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

return M
