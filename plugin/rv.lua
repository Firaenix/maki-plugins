-- /rv: in-maki review UI over the `rv` CLI (jj stack review).
--
-- All review state lives in rv's own store (.review/): the file list comes
-- from `rv status --json`, diffs from `rv diff --json`, comments from
-- `rv comments --json`, and every mutation goes through `rv comment`,
-- `rv reply`, `rv resolve`, `rv abandon`. Nothing is kept only in memory.
--
-- Layout: a left column of two stacked panels + a right pane.
--   * Files    — the review range's files as a directory tree, with a badge
--     showing open comments per file. Enter/l focuses the diff.
--   * Comments — every rv comment with its state glyph; Enter jumps to the
--     anchored diff line, R replies, x resolves (toggle), a abandons.
--   * Right: syntax-highlighted side-aware diff (the left/right numbers are
--     exactly what `rv comment --line` accepts) or the comment detail.
--   * In the diff: `c` comments the current line (side derived from the
--     line kind), R/x/a act on the comment under the cursor.
--   * `s` queues a worker prompt on the current session to fix open comments.
--
-- /rv accepts passthrough arguments for every rv call, e.g. `/rv --from main`.
--
-- Rendering notes (inherited from maki-review, which this UI is modeled on):
--   * The cursor row is drawn manually (padded to full width and restyled)
--     instead of relying on the host's `cursor_line`, because span
--     backgrounds (diff tints) patch over the native highlight.
--   * Only the Files window is ever focused; it receives all keys. The
--     "active pane" is plugin state, indicated by border style.

local TextInput = require("maki.text_input")

-- Blend fractions for diff line background tints.
local ADD_TINT = { "#3fb950", 0.18 }
local DEL_TINT = { "#f85149", 0.18 }
local COM_TINT = { "#e3b341", 0.22 }

-- Glyph + style per rv comment state.
local STATE_GLYPH = {
  open = { "●", "warning" },
  ["awaiting-verification"] = { "◐", "accent" },
  resolved = { "✓", "diff_new" },
  abandoned = { "✗", "dim" },
  outdated = { "○", "dim" },
}
local STATE_ORDER = {
  open = 1,
  ["awaiting-verification"] = 2,
  outdated = 3,
  resolved = 4,
  abandoned = 5,
}

local KIND_LETTER = { added = "A", modified = "M", removed = "D", renamed = "R" }
local STATUS_STYLE = { M = "warning", A = "diff_new", D = "diff_old", R = "accent" }

--- shell helpers -----------------------------------------------------------

local function sh_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Runs a shell command; any nonzero exit is a failure (rv's contract).
local function run(cmd)
  local id = maki.fn.jobstart(cmd)
  local res = maki.fn.jobwait(id, 30000)
  if not res then
    return nil, "timed out: " .. cmd
  end
  if res.exit_code ~= 0 then
    local err = (res.stderr or ""):match("^%s*(.-)%s*$")
    return nil, err ~= "" and err or ("exit " .. res.exit_code)
  end
  return res.stdout or ""
end

--- rv plumbing -------------------------------------------------------------

-- rv global options (e.g. "--from main") passed to /rv, threaded into
-- every invocation because they define the review range.
local function rv_cmd(state, args)
  local extra = state.rv_args and state.rv_args ~= "" and (state.rv_args .. " ") or ""
  return "rv " .. extra .. args
end

local function rv_run(state, args)
  return run(rv_cmd(state, args))
end

local function rv_json(state, args)
  local out, err = rv_run(state, args)
  if not out then
    return nil, err
  end
  local ok, val = pcall(maki.json.decode, out)
  if not ok then
    return nil, "bad rv JSON: " .. tostring(val)
  end
  return val
end

-- rv reads the last jj snapshot; poke jj so working-copy edits are seen.
local function jj_snapshot()
  if maki.fn.executable("jj") == 1 then
    run("jj status >/dev/null 2>&1")
  end
end

-- Writes `text` to a temp file and returns a shell redirect for `-m -`,
-- so bodies full of quotes and backticks never meet the shell.
local MSG_FILE = "/tmp/.maki-rv-msg"
local function msg_redirect(text)
  maki.fs.write(MSG_FILE, text)
  return " -m - < " .. sh_quote(MSG_FILE)
end

--- colors ------------------------------------------------------------------

local function hex_rgb(hex)
  local h = hex:gsub("#", "")
  return tonumber(h:sub(1, 2), 16), tonumber(h:sub(3, 4), 16), tonumber(h:sub(5, 6), 16)
end

-- Mix color `top` into `base` by fraction t (0..1). Both "#rrggbb".
local function blend(base, top, t)
  local br, bg_, bb = hex_rgb(base)
  local tr, tg, tb = hex_rgb(top)
  return string.format(
    "#%02x%02x%02x",
    math.floor(br + (tr - br) * t + 0.5),
    math.floor(bg_ + (tg - bg_) * t + 0.5),
    math.floor(bb + (tb - bb) * t + 0.5)
  )
end

local tints -- { add, del, com } computed lazily from the theme background
local function get_tints()
  if tints then
    return tints
  end
  -- Themes may not define "background"; black matches maki.color's fallback.
  local bg = maki.ui.theme_color("background") or "#000000"
  tints = {
    add = blend(bg, ADD_TINT[1], ADD_TINT[2]),
    del = blend(bg, DEL_TINT[1], DEL_TINT[2]),
    com = blend(bg, COM_TINT[1], COM_TINT[2]),
  }
  return tints
end

--- data loading ------------------------------------------------------------

-- Converts one `rv diff --json` file entry into render lines, inserting
-- gap separators where difftastic skipped unchanged regions.
local function to_dlines(entry)
  local out = {}
  local prev
  for _, l in ipairs(entry.lines or {}) do
    if prev then
      local jump = (l.right and prev.right and l.right > prev.right + 1)
        or (l.left and prev.left and l.left > prev.left + 1)
      if jump then
        out[#out + 1] = { kind = "gap" }
      end
    end
    out[#out + 1] = { kind = l.kind, left = l.left, right = l.right, text = l.text or "" }
    prev = l
  end
  return out
end

local function norm_state(c)
  return (c.state or "open"):gsub("_", "-")
end

-- Reloads everything from rv: status, all diffs, comments.
-- Returns true, or nil + err when the review itself is unreadable.
local function fetch(state)
  jj_snapshot()
  local status, err = rv_json(state, "status --json")
  if not status then
    return nil, err
  end
  state.status = status

  -- One call yields every file's diff; per-file adds/dels fall out of it.
  local diffs = rv_json(state, "diff --json") or {}
  state.diffmap = {}
  for _, entry in ipairs(diffs) do
    state.diffmap[entry.file] = entry
  end

  state.files = {}
  for _, f in ipairs(status.files or {}) do
    local ch = {
      path = f.path,
      status = KIND_LETTER[f.kind] or (f.kind or "?"):sub(1, 1):upper(),
      binary = f.binary,
      adds = 0,
      dels = 0,
    }
    local entry = state.diffmap[f.path]
    if entry then
      for _, l in ipairs(entry.lines or {}) do
        if l.kind == "added" then
          ch.adds = ch.adds + 1
        elseif l.kind == "removed" then
          ch.dels = ch.dels + 1
        end
      end
    end
    state.files[#state.files + 1] = ch
  end
  table.sort(state.files, function(a, b)
    return a.path < b.path
  end)

  local comments = rv_json(state, "comments --json") or {}
  for _, c in ipairs(comments) do
    c.state = norm_state(c)
  end
  table.sort(comments, function(a, b)
    local sa = STATE_ORDER[a.state] or 9
    local sb = STATE_ORDER[b.state] or 9
    if sa ~= sb then
      return sa < sb
    end
    if a.anchor.file ~= b.anchor.file then
      return a.anchor.file < b.anchor.file
    end
    return (a.anchor.line or 0) < (b.anchor.line or 0)
  end)
  state.comments = comments
  return true
end

local function open_count(state)
  local n = 0
  for _, c in ipairs(state.comments or {}) do
    if c.state == "open" then
      n = n + 1
    end
  end
  return n
end

--- comments ----------------------------------------------------------------

-- The rv coordinate of a diff line: the number `rv comment --line` accepts.
local function dline_coord(dl)
  if dl.kind == "removed" then
    return dl.left, "left"
  end
  return dl.right, "right"
end

-- Comments anchored on this diff line of `file` (any state).
local function comments_on(state, file, dl)
  local list = {}
  for _, c in ipairs(state.comments or {}) do
    if c.anchor.file == file then
      local line = c.resolved_line or c.anchor.line
      if c.anchor.side == "left" then
        if dl.kind == "removed" and dl.left == line then
          list[#list + 1] = c
        end
      elseif dl.kind ~= "removed" and dl.right == line then
        list[#list + 1] = c
      end
    end
  end
  return list
end

local function open_comment_count(state, path)
  local n = 0
  for _, c in ipairs(state.comments or {}) do
    if c.anchor.file == path and c.state == "open" then
      n = n + 1
    end
  end
  return n
end

local function comment_loc(c)
  local line = c.resolved_line or c.anchor.line
  local loc = c.anchor.file .. ":" .. tostring(line or "?")
  if c.anchor.side == "left" then
    loc = loc .. " (left)"
  end
  return loc
end

--- handoff -----------------------------------------------------------------

local function build_worker_prompt(state)
  local base = rv_cmd(state, "")
  local p = {
    "Open review comments are waiting in this repository's rv review.",
    "Work through every open comment via the rv CLI (never touch .review/ by hand):",
    "",
    "1. `"
      .. base
      .. "comments --json --state open` — each comment's id, file, line, side and body.",
    "2. For each: read the code, apply the fix the comment asks for on the working copy.",
    "   `" .. base .. "diff <file> --json` prints the side-aware coordinates comments use.",
    "3. `"
      .. base
      .. 'reply <id> -m "<one line: what you changed>"` then `'
      .. base
      .. "resolve <id>`.",
    "4. If a comment should not be acted on, reply with the reason and `"
      .. base
      .. "abandon <id>` instead.",
    "",
    "Done when `" .. base .. "status --check` exits 0.",
  }
  return table.concat(p, "\n")
end

-- Queues the worker prompt on the current session (picked up when the
-- agent reaches it if a turn is streaming).
local function handoff(state)
  local n = open_count(state)
  if n == 0 then
    maki.ui.flash("No open comments — press c on a diff line first")
    return false
  end
  local how, err = maki.session.prompt(build_worker_prompt(state))
  if not how then
    maki.ui.flash("Failed to prompt session: " .. tostring(err))
    return false
  end
  maki.ui.flash(n .. " open comment(s) → worker prompt " .. how)
  return true
end

--- span helpers ------------------------------------------------------------

local function wrap(text, width)
  local lines = {}
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    if raw == "" then
      lines[#lines + 1] = ""
    end
    while #raw > 0 do
      if #raw <= width then
        lines[#lines + 1] = raw
        break
      end
      local cut = width
      for i = width, math.max(width - 20, 1), -1 do
        if raw:sub(i, i) == " " then
          cut = i
          break
        end
      end
      lines[#lines + 1] = raw:sub(1, cut)
      raw = raw:sub(cut + 1):gsub("^%s+", "")
    end
  end
  return lines
end

local function display_len(s)
  local ok, n = pcall(utf8.len, s)
  if ok and n then
    return n
  end
  return #s
end

local function spans_len(spans)
  local n = 0
  for _, sp in ipairs(spans) do
    n = n + display_len(sp[1])
  end
  return n
end

-- Pads `spans` with spaces (styled `style`) up to `width` columns.
local function pad_spans(spans, width, style)
  local n = spans_len(spans)
  if n < width then
    spans[#spans + 1] = { string.rep(" ", width - n), style or "" }
  end
  return spans
end

-- Restyles every span with `style`.
local function restyle(spans, style)
  local out = {}
  for _, sp in ipairs(spans) do
    out[#out + 1] = { sp[1], style }
  end
  return out
end

-- Returns copies of `spans` with `bg` added to each span's style,
-- keeping syntax foreground colors.
local function with_bg(spans, bg)
  local out = {}
  for _, sp in ipairs(spans) do
    local s = sp[2]
    local ns = { bg = bg }
    if type(s) == "table" then
      ns.fg = s.fg
      ns.bold = s.bold
      ns.italic = s.italic
      ns.underline = s.underline
    end
    out[#out + 1] = { sp[1], ns }
  end
  return out
end

--- syntax highlighting -----------------------------------------------------

-- Highlights every code line of a diff in a single call. rv names the
-- language ("Rust"); fall back to the file extension.
local function highlight_dlines(entry, dlines)
  local lang = (entry.language or ""):lower()
  if lang == "" or lang == "text" then
    lang = entry.file:match("%.([%w_]+)$") or ""
  end
  local code, idxs = {}, {}
  for i, dl in ipairs(dlines) do
    if dl.kind ~= "gap" then
      code[#code + 1] = dl.text
      idxs[#idxs + 1] = i
    end
  end
  if #code == 0 then
    return nil
  end
  local ok, styled =
    pcall(maki.ui.highlight, table.concat(code, "\n"), lang, { independent = true })
  if not ok or type(styled) ~= "table" or #styled ~= #code then
    maki.log.info(
      "rv: highlight failed for "
        .. entry.file
        .. " (lang '"
        .. lang
        .. "'): "
        .. (not ok and tostring(styled) or (#styled .. " lines for " .. #code))
    )
    return nil
  end
  -- An unknown language yields spans with no styles at all; discard those
  -- so the diff falls back to red/green fg styling instead of plain text.
  local any_style = false
  for _, spans in ipairs(styled) do
    for _, sp in ipairs(spans) do
      local st = sp[2]
      if type(st) == "table" and (st.fg or st.bold or st.italic or st.underline) then
        any_style = true
        break
      end
    end
    if any_style then
      break
    end
  end
  if not any_style then
    maki.log.info("rv: no syntax styles for " .. entry.file .. " (lang '" .. lang .. "')")
    return nil
  end
  local hl = {}
  for j, spans in ipairs(styled) do
    hl[idxs[j]] = spans
  end
  return hl
end

--- rendering ---------------------------------------------------------------

-- Shortens a path from the left to fit `max` columns.
local function fit_path(path, max)
  if display_len(path) <= max then
    return path
  end
  return "…" .. path:sub(-(max - 1))
end

-- Builds a directory tree from the flat file list. Single-child directory
-- chains are compressed into one node ("a/b/c").
local function build_tree(changes)
  local root = { dirs = {}, dorder = {}, files = {} }
  for i, ch in ipairs(changes) do
    local parts = {}
    for s in ch.path:gmatch("[^/]+") do
      parts[#parts + 1] = s
    end
    local node, prefix = root, ""
    for j = 1, #parts - 1 do
      prefix = prefix == "" and parts[j] or (prefix .. "/" .. parts[j])
      local d = node.dirs[parts[j]]
      if not d then
        d = { name = parts[j], path = prefix, dirs = {}, dorder = {}, files = {} }
        node.dirs[parts[j]] = d
        node.dorder[#node.dorder + 1] = d
      end
      node = d
    end
    node.files[#node.files + 1] = { name = parts[#parts], idx = i }
  end
  local function compress(node)
    for _, d in ipairs(node.dorder) do
      while #d.dorder == 1 and #d.files == 0 do
        local child = d.dorder[1]
        d.name = d.name .. "/" .. child.name
        d.path = child.path
        d.dirs = child.dirs
        d.dorder = child.dorder
        d.files = child.files
      end
      compress(d)
    end
  end
  compress(root)
  return root
end

-- Renders the file tree into fbuf. Returns row_map:
-- row -> file idx or { dir = path }.
local function render_file_list(state)
  local width = math.max(state.lwidth, 20)
  local active = state.pane == "files" and not state.centry and not state.rentry
  local changes = state.files
  local lines, row_map = {}, {}
  if #changes == 0 then
    lines[#lines + 1] = { { "  No changes in range.", "dim" } }
  end

  local function push(spans, val)
    lines[#lines + 1] = spans
    row_map[#lines] = val
    if #lines == state.fcursor then
      if active then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      else
        -- Inactive panel: keep the selection visible, without the bar.
        local marked = restyle(spans, "active")
        marked[1] = { "▎" .. spans[1][1]:sub(2), "accent" }
        lines[#lines] = marked
      end
    end
  end

  -- Total files and open comments under a directory node.
  local function dir_stats(d)
    local nfiles, ncoms = #d.files, 0
    for _, f in ipairs(d.files) do
      ncoms = ncoms + open_comment_count(state, changes[f.idx].path)
    end
    for _, sub in ipairs(d.dorder) do
      local sf, sc = dir_stats(sub)
      nfiles = nfiles + sf
      ncoms = ncoms + sc
    end
    return nfiles, ncoms
  end

  local function emit_file(f, depth)
    local ch = changes[f.idx]
    local n = open_comment_count(state, ch.path)
    local right
    if ch.binary then
      right = "bin"
    else
      right = "+" .. ch.adds .. " -" .. ch.dels
    end
    local badge = n > 0 and ("● " .. n .. " ") or ""
    local prefix = " " .. string.rep("  ", depth) .. ch.status .. " "
    local avail = width - display_len(prefix) - display_len(right) - display_len(badge) - 2
    local spans = {
      { prefix, STATUS_STYLE[ch.status] or "item" },
      { fit_path(f.name, math.max(avail, 8)), "item" },
    }
    pad_spans(spans, width - display_len(right) - display_len(badge) - 1)
    if badge ~= "" then
      spans[#spans + 1] = { badge, "warning" }
    end
    spans[#spans + 1] = { right, ch.binary and "dim" or "accent" }
    push(spans, f.idx)
  end

  local walk
  local function emit_dir(d, depth)
    local isc = state.fcollapsed[d.path]
    local nfiles, ncoms = dir_stats(d)
    local right = isc and (nfiles .. " files") or ""
    local badge = ncoms > 0 and ("● " .. ncoms .. " ") or ""
    local prefix = " " .. string.rep("  ", depth) .. (isc and "▸ " or "▾ ")
    local avail = width - display_len(prefix) - display_len(right) - display_len(badge) - 2
    local spans = {
      { prefix, "accent" },
      { fit_path(d.name .. "/", math.max(avail, 8)), "item" },
    }
    pad_spans(spans, width - display_len(right) - display_len(badge) - 1)
    if badge ~= "" then
      spans[#spans + 1] = { badge, "warning" }
    end
    if right ~= "" then
      spans[#spans + 1] = { right, "dim" }
    end
    push(spans, { dir = d.path })
    if not isc then
      walk(d, depth + 1)
    end
  end

  walk = function(node, depth)
    for _, d in ipairs(node.dorder) do
      emit_dir(d, depth)
    end
    for _, f in ipairs(node.files) do
      emit_file(f, depth)
    end
  end
  walk(build_tree(changes), 0)

  state.fbuf:set_lines(lines)
  return row_map
end

-- Renders the rv comment list into mbuf. Returns row_map (row -> comment idx).
local function render_comment_list(state)
  local width = math.max(state.lwidth, 20)
  local active = state.pane == "comments" and not state.centry and not state.rentry
  local lines, row_map = {}, {}
  if #(state.comments or {}) == 0 then
    lines[#lines + 1] = { { "  No comments yet.", "dim" } }
    lines[#lines + 1] = { { "  Press c on a diff line.", "dim" } }
  end
  for i, c in ipairs(state.comments or {}) do
    local g = STATE_GLYPH[c.state] or { "?", "dim" }
    local name = c.anchor.file:match("([^/]+)$") or c.anchor.file
    local loc = name .. ":" .. tostring(c.resolved_line or c.anchor.line or "?")
    loc = fit_path(loc, math.max(width - 4, 8))
    local spans = {
      { " " .. g[1] .. " ", g[2] },
      { loc, c.state == "open" and "item" or "dim" },
    }
    local avail = width - 3 - display_len(loc) - 2
    if avail > 4 then
      local preview = (c.body or ""):gsub("%s+", " ")
      if display_len(preview) > avail then
        preview = preview:sub(1, math.max(avail - 1, 1)) .. "…"
      end
      spans[#spans + 1] = { " " .. preview, "dim" }
    end
    lines[#lines + 1] = spans
    row_map[#lines] = i
    if #lines == state.mcursor then
      if active then
        lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
      else
        local marked = restyle(spans, "active")
        marked[1] = { "▎" .. g[1] .. " ", g[2] }
        lines[#lines] = marked
      end
    end
  end
  state.mbuf:set_lines(lines)
  return row_map
end

-- Appends one comment block (header, body, reply) to `lines`.
local function emit_comment_block(lines, c, width, indent)
  local tint = get_tints()
  local cbg = tint.com
  local bar = { fg = COM_TINT[1], bg = cbg, bold = true }
  local txt = cbg and { bg = cbg, bold = true } or "warning"
  local g = STATE_GLYPH[c.state] or { "?", "dim" }
  local hdr = {
    { indent .. "┏ ", bar },
    { g[1] .. " " .. c.id .. "  " .. c.state, bar },
  }
  if c.settled_by then
    hdr[#hdr + 1] = { "  · by " .. c.settled_by, bar }
  end
  if cbg then
    pad_spans(hdr, width, { bg = cbg })
  end
  lines[#lines + 1] = hdr
  for _, cl in ipairs(wrap(c.body or "", math.max(width - 10, 20))) do
    local cspans = { { indent .. "┃ ", bar }, { cl, txt } }
    if cbg then
      pad_spans(cspans, width, { bg = cbg })
    end
    lines[#lines + 1] = cspans
  end
  if c.reply and c.reply ~= "" then
    for j, rl in ipairs(wrap(c.reply, math.max(width - 12, 20))) do
      local rspans = {
        { indent .. "┃ ", bar },
        { (j == 1 and "↳ " or "  ") .. rl, cbg and { bg = cbg, italic = true } or "dim" },
      }
      if cbg then
        pad_spans(rspans, width, { bg = cbg })
      end
      lines[#lines + 1] = rspans
    end
  end
end

-- Renders the diff of the selected file into rbuf.
-- Returns row_map (row -> dline idx), editor_row.
local function render_diff(state)
  local width = math.max(state.rwidth, 20)
  local lines, row_map = {}, {}
  local ch = state.change
  local tint = get_tints()

  if not ch then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  Select a file on the left.", "dim" } }
    state.rbuf:set_lines(lines)
    return row_map, nil
  end

  local dlines = state.dlines
  if not dlines then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  " .. (state.diff_err or "No diff to show."), "dim" } }
    state.rbuf:set_lines(lines)
    return row_map, nil
  end

  local editor_row = nil
  local active = state.pane == "diff"

  for i, dl in ipairs(dlines) do
    if dl.kind == "gap" then
      lines[#lines + 1] = { { "      ⋯", "dim" } }
      continue
    end

    local cs = comments_on(state, ch.path, dl)
    local sign = dl.kind == "added" and "+" or dl.kind == "removed" and "-" or " "
    local base = dl.kind == "added" and "diff_new" or dl.kind == "removed" and "diff_old" or "item"
    local lgut = (dl.kind ~= "added" and dl.left) and string.format("%4d", dl.left) or "    "
    local rgut = (dl.kind ~= "removed" and dl.right) and string.format("%4d", dl.right) or "    "

    -- Code text: syntax-highlighted spans when available.
    local text_spans
    if state.hl and state.hl[i] and #state.hl[i] > 0 then
      text_spans = state.hl[i]
    else
      text_spans = { { dl.text, base } }
    end

    local mark = "  "
    if #cs > 0 then
      mark = (STATE_GLYPH[cs[1].state] or { "●" })[1] .. " "
    end
    local spans = {
      { mark, "warning" },
      { lgut .. " ", "dim" },
      { rgut .. " ", "dim" },
      { sign .. " ", base },
    }
    for _, sp in ipairs(text_spans) do
      spans[#spans + 1] = { sp[1], sp[2] }
    end

    -- Full-row background tint by line kind.
    local bg = nil
    if dl.kind == "added" then
      bg = tint.add
    elseif dl.kind == "removed" then
      bg = tint.del
    end
    if bg then
      spans = with_bg(spans, bg)
      pad_spans(spans, width, { bg = bg })
    end

    lines[#lines + 1] = spans
    row_map[#lines] = i
    if active and #lines == state.dcursor and not state.centry then
      lines[#lines] = pad_spans(restyle(spans, "selected"), width, "selected")
    end

    -- Inline comment editor, right below the anchor line.
    if state.centry and state.centry.at == i then
      lines[#lines + 1] = {
        { "    ┌ ", "accent" },
        { "Comment (" .. state.centry.label .. ")", "accent" },
        { "  Enter: save  Esc: cancel", "dim" },
      }
      local r = state.centry.input:render("    │ ", 6, math.max(width - 8, 20))
      for _, l in ipairs(r.lines) do
        lines[#lines + 1] = l
        editor_row = #lines
      end
      lines[#lines + 1] = { { "    └", "accent" } }
    end

    -- Saved rv comments, below the line they anchor on.
    for _, c in ipairs(cs) do
      emit_comment_block(lines, c, width, "    ")
    end
  end

  state.rbuf:set_lines(lines)
  return row_map, editor_row
end

-- Right pane: full detail of the comment under the cursor.
local function render_comment_detail(state)
  local width = math.max(state.rwidth, 20)
  local lines = {}
  local c = (state.comments or {})[state.mrow_map and state.mrow_map[state.mcursor]]
  if not c then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { "  No comment selected.", "dim" } }
    state.rbuf:set_lines(lines)
    return nil
  end
  local g = STATE_GLYPH[c.state] or { "?", "dim" }
  lines[#lines + 1] = { { "", "" } }
  lines[#lines + 1] = { { " " .. comment_loc(c), "accent" } }
  local meta = " " .. g[1] .. " " .. c.state
  if c.settled_by then
    meta = meta .. " by " .. c.settled_by
  end
  if c.outdated then
    meta = meta .. "  ·  outdated"
  end
  lines[#lines + 1] = { { meta, g[2] } }
  lines[#lines + 1] = { { "", "" } }
  emit_comment_block(lines, c, width, " ")

  local editor_row = nil
  if state.rentry then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = {
      { " ┌ ", "accent" },
      { "Reply to " .. c.id, "accent" },
      { "  Enter: save  Esc: cancel", "dim" },
    }
    local r = state.rentry.input:render(" │ ", 3, math.max(width - 6, 20))
    for _, l in ipairs(r.lines) do
      lines[#lines + 1] = l
      editor_row = #lines
    end
    lines[#lines + 1] = { { " └", "accent" } }
  end

  -- The frozen anchor context rv stored with the comment.
  local ctx = c.anchor.context or {}
  if #ctx > 0 then
    lines[#lines + 1] = { { "", "" } }
    lines[#lines + 1] = { { " anchor context:", "dim" } }
    local ln = c.anchor.context_start or 1
    for _, sl in ipairs(ctx) do
      local at = ln == c.anchor.line
      lines[#lines + 1] = {
        { string.format(" %4d ", ln), at and "warning" or "dim" },
        { sl, at and "item" or "dim" },
        { at and "  ◀" or "", "warning" },
      }
      ln = ln + 1
    end
  end
  state.rbuf:set_lines(lines)
  return editor_row
end

-- Renders a left panel and clamps its cursor to a mapped row, re-rendering
-- once when the cursor had to move (so the selection bar lands right).
local function render_clamped(state, render, cur_key, buf)
  local map = render(state)
  if not map[state[cur_key]] then
    state[cur_key] = 1
    for r = 1, buf:len() do
      if map[r] then
        state[cur_key] = r
        break
      end
    end
    map = render(state)
  end
  return map
end

local function redraw(state)
  state.frow_map = render_clamped(state, render_file_list, "fcursor", state.fbuf)
  state.mrow_map = render_clamped(state, render_comment_list, "mcursor", state.mbuf)

  -- Right pane: diff when browsing files (or focused), comment detail
  -- when the comments panel drives it.
  local drow_map, editor_row = {}, nil
  if state.src == "comments" and state.pane ~= "diff" then
    editor_row = render_comment_detail(state)
  else
    drow_map, editor_row = render_diff(state)
  end
  state.drow_map = drow_map

  if state.change and state.pane == "diff" and not state.drow_map[state.dcursor] then
    for r = state.dcursor, 1, -1 do
      if drow_map[r] then
        state.dcursor = r
        break
      end
    end
    if not drow_map[state.dcursor] then
      state.dcursor = 1
    end
  end

  local editing = state.centry ~= nil or state.rentry ~= nil
  local diff_active = state.pane == "diff" or state.centry ~= nil
  local nopen = open_count(state)

  local function panel_cfg(win, title, active, footer)
    win:set_config({
      title = title,
      border = active and "double" or "rounded",
      footer = active and footer or { { "Tab", "focus" } },
    })
  end

  panel_cfg(
    state.fwin,
    " Files (" .. #state.files .. ")  " .. (state.status.revset or "") .. " ",
    state.pane == "files" and not editing,
    {
      { "Enter", "diff" },
      { "r", "refresh" },
      { "s", "worker " .. nopen },
      { "Esc", "close" },
    }
  )

  panel_cfg(
    state.mwin,
    " Comments (" .. nopen .. " open / " .. #(state.comments or {}) .. ") ",
    state.pane == "comments" and not editing,
    {
      { "Enter", "goto" },
      { "R", "reply" },
      { "x", "resolve" },
      { "a", "abandon" },
      { "s", "worker " .. nopen },
    }
  )

  local rtitle = " Diff "
  if state.src == "comments" and state.pane ~= "diff" then
    rtitle = " Comment "
  elseif state.change then
    rtitle = " "
      .. fit_path(state.change.path, math.max(state.rwidth - 14, 12))
      .. "  +"
      .. state.change.adds
      .. " -"
      .. state.change.dels
      .. " "
  end
  state.rwin:set_config({
    title = rtitle,
    border = diff_active and "double" or "rounded",
    footer = (state.centry or state.rentry) and { { "Enter", "save" }, { "Esc", "cancel" } }
      or (
        diff_active
          and {
            { "c", "comment" },
            { "R", "reply" },
            { "x", "resolve" },
            { "a", "abandon" },
            { "Esc", "back" },
          }
        or { { "Enter", "diff" } }
      ),
  })

  state.fwin:set_cursor(state.fcursor)
  state.mwin:set_cursor(state.mcursor)
  state.rwin:set_cursor(editor_row or state.dcursor)
end

--- preview loading ---------------------------------------------------------

-- Loads the right-pane diff for the file selected in the Files panel.
local function load_preview(state)
  state.change = nil
  state.dlines = nil
  state.hl = nil
  state.diff_err = nil
  state.centry = nil
  state.rentry = nil
  state.dcursor = 1

  if state.src == "comments" then
    return
  end

  local ch = state.files[state.frow_map and state.frow_map[state.fcursor]]
  state.change = ch
  if not ch then
    return
  end
  if ch.binary then
    state.diff_err = "Binary file — nothing to show."
    return
  end
  local entry = state.diffmap[ch.path]
  if not entry then
    state.diff_err = "No diff for this file."
    return
  end
  if entry.suppressed then
    state.diff_err = "Diff suppressed (too large for difftastic)."
  end

  local cached = state.cache[ch.path]
  if not cached then
    local dlines = to_dlines(entry)
    cached = { dlines = dlines, hl = highlight_dlines(entry, dlines) }
    state.cache[ch.path] = cached
  end
  state.dlines = cached.dlines
  state.hl = cached.hl

  -- Cursor starts on the first changed line.
  state.dcursor = 1
  for i, dl in ipairs(cached.dlines) do
    if dl.kind == "added" or dl.kind == "removed" then
      state.dcursor = i
      break
    end
  end
end

-- Re-reads everything from rv. keep_diff keeps the current file and diff
-- cursor (used after comment mutations, where the code didn't change).
local function refresh(state, keep_diff)
  state.cache = {}
  local ok, err = fetch(state)
  if not ok then
    maki.ui.flash("rv: " .. tostring(err))
    return
  end
  redraw(state) -- rebuild row maps before reloading the preview
  if not keep_diff then
    load_preview(state)
  else
    local ch = state.change
    if ch then
      local entry = state.diffmap[ch.path]
      if entry then
        local dlines = to_dlines(entry)
        state.cache[ch.path] = { dlines = dlines, hl = highlight_dlines(entry, dlines) }
        state.dlines = state.cache[ch.path].dlines
        state.hl = state.cache[ch.path].hl
      end
    end
  end
  redraw(state)
end

--- pane switching ----------------------------------------------------------

local function set_pane(state, pane)
  if pane == "diff" and not state.dlines then
    maki.ui.flash("No diff to focus")
    return
  end
  if state.pane == pane then
    return
  end
  state.pane = pane
  if pane ~= "diff" then
    state.src = pane
    load_preview(state)
  end
  redraw(state)
end

local function toggle_dir(state, dir)
  state.fcollapsed[dir] = not state.fcollapsed[dir] and true or nil
  redraw(state)
end

--- navigation --------------------------------------------------------------

local function active_view(state)
  if state.pane == "files" then
    return state.fcursor, state.frow_map, state.fbuf
  elseif state.pane == "comments" then
    return state.mcursor, state.mrow_map, state.mbuf
  end
  return state.dcursor, state.drow_map, state.rbuf
end

local function active_height(state)
  if state.pane == "files" then
    return state.fheight
  elseif state.pane == "comments" then
    return state.mheight
  end
  return state.rheight
end

local function set_active_cursor(state, r)
  if state.pane == "diff" then
    if r ~= state.dcursor then
      state.dcursor = r
      redraw(state)
    end
    return
  end
  local key = state.pane == "files" and "fcursor" or "mcursor"
  if r ~= state[key] then
    state[key] = r
    load_preview(state)
    redraw(state)
  end
end

local function move(state, dir, count)
  count = count or 1
  local cursor, row_map, buf = active_view(state)
  local r = cursor
  local total = buf:len()
  for _ = 1, count do
    local nr = r + dir
    while nr >= 1 and nr <= total and not row_map[nr] do
      nr = nr + dir
    end
    if row_map[nr] then
      r = nr
    else
      break
    end
  end
  set_active_cursor(state, r)
end

local function jump(state, to_end)
  local _, row_map, buf = active_view(state)
  local best
  local from, to, step = 1, buf:len(), 1
  if to_end then
    from, to, step = buf:len(), 1, -1
  end
  for r = from, to, step do
    if row_map[r] then
      best = r
      break
    end
  end
  if best then
    set_active_cursor(state, best)
  end
end

-- Comments panel Enter: jump to the comment's anchored line in the diff.
local function goto_comment(state)
  local c = (state.comments or {})[state.mrow_map and state.mrow_map[state.mcursor]]
  if not c then
    return
  end
  local function find_file_row()
    for r, v in pairs(state.frow_map or {}) do
      if type(v) == "number" and state.files[v].path == c.anchor.file then
        return r
      end
    end
  end
  local row = find_file_row()
  if not row then
    state.fcollapsed = {} -- the file may be inside a collapsed directory
    state.src = "files"
    redraw(state)
    row = find_file_row()
  end
  if not row then
    maki.ui.flash("File not in this review range: " .. c.anchor.file)
    return
  end
  state.fcursor = row
  state.src = "files"
  load_preview(state)
  redraw(state) -- build drow_map for the new diff
  if not state.dlines then
    maki.ui.flash("No diff to show for " .. c.anchor.file)
    return
  end
  local line = c.resolved_line or c.anchor.line
  local best
  for r = 1, state.rbuf:len() do
    local i = state.drow_map[r]
    local dl = i and state.dlines[i]
    if dl then
      if c.anchor.side == "left" then
        if dl.kind == "removed" and dl.left == line then
          best = r
          break
        end
      elseif dl.kind ~= "removed" and dl.right == line then
        best = r
        break
      end
    end
  end
  if best then
    state.dcursor = best
  end
  state.pane = "diff"
  redraw(state)
end

--- comment actions ---------------------------------------------------------

-- The comment the diff cursor is on, or the one selected in the panel.
local function selected_comment(state)
  if state.pane == "diff" then
    local i = state.drow_map[state.dcursor]
    local dl = i and state.dlines and state.dlines[i]
    if not dl or not state.change then
      return nil
    end
    return comments_on(state, state.change.path, dl)[1]
  end
  return (state.comments or {})[state.mrow_map and state.mrow_map[state.mcursor]]
end

local function open_comment_editor(state)
  local at = state.drow_map[state.dcursor]
  local dl = state.dlines and state.dlines[at]
  if not dl or dl.kind == "gap" then
    maki.ui.flash("Move onto a diff line first (j/k)")
    return
  end
  local line, side = dline_coord(dl)
  if not line then
    maki.ui.flash("No rv coordinate on this line")
    return
  end
  state.centry = {
    input = TextInput.new(),
    at = at,
    line = line,
    side = side,
    label = state.change.path .. ":" .. line .. (side == "left" and " (left)" or ""),
  }
  redraw(state)
end

local function save_comment(state)
  local e = state.centry
  local text = e.input:value():match("^%s*(.-)%s*$")
  if text == "" then
    state.centry = nil
    redraw(state)
    return
  end
  local cmd = "comment "
    .. sh_quote(state.change.path)
    .. " --line "
    .. e.line
    .. " --side "
    .. e.side
    .. msg_redirect(text)
  local out, err = rv_run(state, cmd)
  maki.fs.rm(MSG_FILE)
  if not out then
    -- Keep the editor (and its text) so the comment isn't lost.
    maki.ui.flash("rv: " .. tostring(err))
    return
  end
  state.centry = nil
  local saved = out:match("^%s*(.-)%s*$")
  maki.ui.flash(saved ~= "" and saved or "Comment saved")
  refresh(state, true)
end

local function open_reply_editor(state)
  local c = selected_comment(state)
  if not c then
    maki.ui.flash("No comment here to reply to")
    return
  end
  local input = TextInput.new()
  if c.reply and c.reply ~= "" then
    input:insert_text(c.reply) -- rv replaces the reply; pre-fill to edit
  end
  state.rentry = { input = input, id = c.id }
  redraw(state)
end

local function save_reply(state)
  local e = state.rentry
  local text = e.input:value():match("^%s*(.-)%s*$")
  state.rentry = nil
  if text == "" then
    redraw(state)
    return
  end
  local out, err = rv_run(state, "reply " .. e.id .. msg_redirect(text))
  maki.fs.rm(MSG_FILE)
  if not out then
    maki.ui.flash("rv: " .. tostring(err))
  else
    maki.ui.flash("Replied to " .. e.id)
  end
  refresh(state, true)
end

-- x resolves (re-applying reopens, rv's own undo); a abandons.
local function settle(state, verb)
  local c = selected_comment(state)
  if not c then
    maki.ui.flash("No comment selected")
    return
  end
  local out, err = rv_run(state, verb .. " " .. c.id .. " --by user")
  if not out then
    maki.ui.flash("rv: " .. tostring(err))
  else
    maki.ui.flash(c.id .. ": " .. verb)
  end
  refresh(state, true)
end

--- windows -----------------------------------------------------------------

local function layout()
  local sz = maki.ui.terminal_size()
  local w = math.floor(sz.cols * 0.94)
  local h = math.floor(sz.rows * 0.86)
  local lw = math.max(28, math.min(46, math.floor(w * 0.30)))
  local rw = w - lw
  local row = math.max(math.floor((sz.rows - h) / 2) - 1, 0)
  local col = math.floor((sz.cols - w) / 2)
  local fh = math.max(math.floor(h * 0.45), 5)
  local mh = math.max(h - fh, 4)
  return { lw = lw, rw = rw, h = h, fh = fh, mh = mh, row = row, col = col }
end

-- Opens (or reopens) all panes. Only the Files window takes focus and
-- receives keys; the other windows are display-only.
local function open_windows(state)
  for _, w in ipairs({ "fwin", "mwin", "rwin" }) do
    if state[w] then
      state[w]:close()
    end
  end
  local L = layout()
  state.rwin = maki.ui.open_win(state.rbuf, {
    title = " Diff ",
    width = L.rw,
    height = L.h,
    row = L.row,
    col = L.col + L.lw,
    anchor = "NW",
    focus = false,
  })
  state.mwin = maki.ui.open_win(state.mbuf, {
    title = " Comments ",
    width = L.lw,
    height = L.mh,
    row = L.row + L.fh,
    col = L.col,
    anchor = "NW",
    focus = false,
  })
  state.fwin = maki.ui.open_win(state.fbuf, {
    title = " Files ",
    width = L.lw,
    height = L.fh,
    row = L.row,
    col = L.col,
    anchor = "NW",
    focus = true,
  })
  state.lwidth = state.fwin.width
  state.rwidth = state.rwin.width
  state.fheight = state.fwin.height
  state.mheight = state.mwin.height
  state.rheight = state.rwin.height
  state.term = maki.ui.terminal_size()
end

--- main loop ---------------------------------------------------------------

local function open_review(args)
  if maki.fn.executable("rv") == 0 then
    maki.ui.flash("rv not found on PATH")
    return
  end

  local state = {
    rv_args = args,
    fbuf = maki.ui.buf(),
    mbuf = maki.ui.buf(),
    rbuf = maki.ui.buf(),
    pane = "files",
    src = "files",
    fcursor = 1,
    mcursor = 1,
    dcursor = 1,
    frow_map = {},
    mrow_map = {},
    drow_map = {},
    fcollapsed = {},
    cache = {},
  }

  local ok, err = fetch(state)
  if not ok then
    maki.ui.flash("rv: " .. tostring(err))
    return
  end

  open_windows(state)
  redraw(state) -- build row maps before the first preview
  for r = 1, state.fbuf:len() do
    if type(state.frow_map[r]) == "number" then
      state.fcursor = r -- start on the first file, not a directory row
      break
    end
  end
  load_preview(state)
  redraw(state)

  while true do
    local ev = state.fwin:recv()
    if not ev or ev.type == "close" then
      break
    end

    if ev.type == "resize" then
      -- Windows emit a resize event on their first layout pass too; only
      -- reopen when the terminal itself changed, or we'd loop forever.
      local sz = maki.ui.terminal_size()
      if sz.cols ~= state.term.cols or sz.rows ~= state.term.rows then
        open_windows(state)
      end
      redraw(state)
      continue
    end

    if ev.type == "paste" then
      local entry = state.centry or state.rentry
      if entry then
        entry.input:insert_text(ev.text)
        redraw(state)
      end
      continue
    end

    if ev.type ~= "key" then
      continue
    end
    local key = ev.key

    -- An open editor owns the keyboard.
    if state.centry then
      if key == "enter" then
        save_comment(state)
      elseif key == "esc" or key == "ctrl+c" then
        state.centry = nil
        redraw(state)
      else
        if state.centry.input:handle_key(key) ~= TextInput.Result.IGNORED then
          redraw(state)
        end
      end
      continue
    end
    if state.rentry then
      if key == "enter" then
        save_reply(state)
      elseif key == "esc" or key == "ctrl+c" then
        state.rentry = nil
        redraw(state)
      else
        if state.rentry.input:handle_key(key) ~= TextInput.Result.IGNORED then
          redraw(state)
        end
      end
      continue
    end

    if key == "up" or key == "k" then
      move(state, -1)
    elseif key == "down" or key == "j" then
      move(state, 1)
    elseif key == "pageup" then
      move(state, -1, math.max(active_height(state) - 2, 1))
    elseif key == "pagedown" then
      move(state, 1, math.max(active_height(state) - 2, 1))
    elseif key == "g" or key == "home" then
      jump(state, false)
    elseif key == "G" or key == "end" then
      jump(state, true)
    elseif key == "tab" then
      set_pane(
        state,
        state.pane == "diff" and state.src or (state.pane == "files" and "comments" or "files")
      )
    elseif key == "r" then
      refresh(state)
    elseif key == "s" then
      if handoff(state) then
        break
      end
      redraw(state)
    elseif key == "R" then
      open_reply_editor(state)
    elseif key == "x" then
      settle(state, "resolve")
    elseif key == "a" then
      settle(state, "abandon")
    elseif key == "q" or key == "ctrl+c" then
      break
    elseif state.pane ~= "diff" then -- one of the left panels
      if key == "enter" or key == "l" or key == "right" then
        if state.pane == "comments" then
          goto_comment(state)
        else
          local cursor, row_map = active_view(state)
          local sel = row_map[cursor]
          if type(sel) == "table" and sel.dir then
            toggle_dir(state, sel.dir)
          else
            set_pane(state, "diff")
          end
        end
      elseif key == "h" or key == "left" then
        local cursor, row_map = active_view(state)
        local sel = row_map[cursor]
        if
          state.pane == "files"
          and type(sel) == "table"
          and sel.dir
          and not state.fcollapsed[sel.dir]
        then
          toggle_dir(state, sel.dir) -- collapse the directory under the cursor
        end
      elseif key == "esc" then
        break
      end
    else -- diff pane
      if key == "c" or key == "enter" then
        open_comment_editor(state)
      elseif key == "h" or key == "left" or key == "esc" then
        set_pane(state, state.src)
      end
    end
  end

  for _, w in ipairs({ "fwin", "mwin", "rwin" }) do
    if state[w] then
      state[w]:close()
    end
  end
end

--- registration ------------------------------------------------------------

maki.api.register_command({
  name = "/rv",
  description = "Review the jj stack with rv: browse diffs, leave/settle comments, hand fixes to maki. Args pass through, e.g. /rv --from main",
  handler = function(opts)
    local args = (opts and opts.args or ""):match("^%s*(.-)%s*$")
    local ok, err = pcall(open_review, args)
    if not ok then
      maki.log.error("rv review crashed: " .. tostring(err))
      maki.ui.flash("rv review error: " .. tostring(err))
    end
  end,
})

-- Nudge after each turn while rv comments are open (only in repos that
-- actually have a review going, so this stays free everywhere else).
local last_open = nil
maki.api.create_autocmd("TurnEnd", {
  callback = function()
    maki.async.run(function()
      if not maki.fs.metadata(".review") then
        return
      end
      local status = rv_json({ rv_args = "" }, "status --json")
      local n = status and status.comments and status.comments.open
      if n and n > 0 and n ~= last_open then
        last_open = n
        maki.ui.flash(n .. " rv comment(s) open — /rv to review")
      end
    end)
  end,
})
