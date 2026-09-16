-- skills — user-facing `/skills` slash command that lists every skill
-- the bundled `skill` tool would discover, without going through the LLM.
--
-- The builtin skill plugin (see maki's plugins/skill/init.lua) exposes
-- skills as a tool the model calls; there is no direct way for the user
-- to inspect what skills are actually reachable in the current session.
-- This plugin adds that missing view: same discovery paths, same
-- frontmatter parsing, rendered to a scrollable panel.
--
-- Discovery mirrors the builtin exactly:
--   global:  $HOME/.claude/skills, $HOME/.config/opencode/skills,
--            $HOME/.agents/skills
--   config:  $XDG_CONFIG_HOME/maki/skills
--   project: <ancestor up to first .git>/{.maki,.claude,.opencode,.agents}/skills
--
-- Later paths override earlier ones by name (same as the builtin), so a
-- project-local skill shadows a global one of the same name.

local SKILL_FILE = "SKILL.md"
local TICK_MS = 200

local PROJECT_SKILL_DIRS = {
  ".maki/skills",
  ".claude/skills",
  ".opencode/skills",
  ".agents/skills",
}
local GLOBAL_SKILL_DIRS = {
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
  local fm, _ = maki.yaml.decode(yaml_str)
  if not fm then
    fm = {}
  end
  return fm, body
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

local function find_project_ancestors()
  local cwd = maki.uv.cwd()
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

local function discover_skills()
  local skills = {}

  local config = maki.env.config_dir()
  if config then
    scan_skill_dir(maki.fs.joinpath(config, "skills"), skills)
  end

  local home = maki.uv.os_homedir()
  if home then
    for _, rel in ipairs(GLOBAL_SKILL_DIRS) do
      scan_skill_dir(maki.fs.joinpath(home, rel), skills)
    end
  end

  for _, ancestor in ipairs(find_project_ancestors()) do
    for _, rel in ipairs(PROJECT_SKILL_DIRS) do
      scan_skill_dir(maki.fs.joinpath(ancestor, rel), skills)
    end
  end

  return skills
end

-- Squash home to `~` and collapse consecutive whitespace so descriptions
-- lifted from multi-line YAML render as one grid row.
local function shorten(path)
  local home = maki.uv.os_homedir()
  if home and path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

local function one_line(s)
  return (s or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function build_lines(skills)
  local sorted = {}
  for _, s in pairs(skills) do
    sorted[#sorted + 1] = s
  end
  table.sort(sorted, function(a, b)
    return a.name < b.name
  end)

  local lines = {}
  if #sorted == 0 then
    lines[1] = { { "No skills discovered.", "muted" } }
    lines[2] = { { "", "muted" } }
    lines[3] = { { "Drop a SKILL.md under any of:", "muted" } }
    for _, rel in ipairs(GLOBAL_SKILL_DIRS) do
      lines[#lines + 1] = { { "  ~/" .. rel .. "/<name>/SKILL.md", "muted" } }
    end
    return lines, 60, math.max(6, #lines + 2)
  end

  -- Two-column layout: name (bold) then description (dim), with the
  -- source path on a following dim line for skills that have descriptions.
  local name_w = 0
  for _, s in ipairs(sorted) do
    local w = maki.ui.display_width(s.name)
    if w > name_w then
      name_w = w
    end
  end
  name_w = math.min(name_w, 32)

  local desc_w_max = 0
  for _, s in ipairs(sorted) do
    local desc = one_line(s.description)
    local w = maki.ui.display_width(desc)
    if w > desc_w_max then
      desc_w_max = w
    end
  end

  local tsize = maki.ui.terminal_size()
  local avail = math.max(40, tsize.cols - 6) - name_w - 3
  local desc_w = math.min(desc_w_max, math.max(20, avail))

  local function pad(s, w)
    local dw = maki.ui.display_width(s)
    if dw >= w then
      return s
    end
    return s .. string.rep(" ", w - dw)
  end

  for _, s in ipairs(sorted) do
    local desc = one_line(s.description)
    if maki.ui.display_width(desc) > desc_w then
      desc = desc:sub(1, desc_w - 1) .. "…"
    end
    lines[#lines + 1] = {
      { pad(s.name, name_w), "identifier" },
      { "  ", "muted" },
      { desc, "muted" },
    }
    lines[#lines + 1] = {
      { string.rep(" ", name_w + 2), "muted" },
      { shorten(s.location), "path" },
    }
  end

  local width = math.min(tsize.cols - 4, name_w + 3 + desc_w + 2)
  local height = math.min(tsize.rows - 4, #lines + 2)
  return lines, math.max(50, width), math.max(6, height)
end

maki.api.register_command({
  name = "/skills",
  description = "List every skill the `skill` tool can load in this session.",
  handler = function()
    local skills = discover_skills()
    local buf = maki.ui.buf()
    local lines, width, height = build_lines(skills)
    buf:set_lines(lines)

    local count = 0
    for _ in pairs(skills) do
      count = count + 1
    end

    local title
    if count == 0 then
      title = "Skills (none)"
    elseif count == 1 then
      title = "Skills (1)"
    else
      title = "Skills (" .. count .. ")"
    end

    local win = maki.ui.open_win(buf, {
      title = title,
      border = "rounded",
      width = width,
      height = height,
      footer = { { "q", "close" } },
    })

    while true do
      local ev = win:recv(TICK_MS)
      if not ev or ev.type == "close" then
        break
      end
      if ev.type == "key" and (ev.key == "q" or ev.key == "esc") then
        break
      end
    end
    win:close()
  end,
})
