-- What the describe panel draws, and what its keys do. Pure, with no maki
-- calls: the panel passes in sizes, a display-width function and highlighted
-- rows, so tests/ runs this under plain luau.
--
-- Lines are in `buf:line` form: a string, or a list of `{ text, style }` spans.

local M = {}

M.COMPACT_ROWS = 8
-- open_win sizes the outer box, so the border takes a row at each end.
M.CHROME = 2
-- Rows the compact panel leaves free for the native prompt, whose tool line
-- and key hints must stay visible below it.
M.PROMPT_ROWS = 14
M.MIN_HEIGHT = 5

local GAP = "  "
local DIM = "dim"

local SCROLL = { ["j"] = 1, ["<Down>"] = 1, ["k"] = -1, ["<Up>"] = -1 }

local function plain_width(s)
  return utf8.len(s) or #s
end

-- A command can hold tabs, carriage returns and raw escape bytes. Drawn as
-- they are they would shift columns or reach the terminal, so they become
-- visible text.
function M.sanitize(text)
  text = text:gsub("\r\n", "\n"):gsub("\t", "  ")
  text = text:gsub("%c", function(c)
    if c == "\n" then
      return c
    end
    return string.format("\\x%02x", c:byte())
  end)
  if not utf8.len(text) then
    text = text:gsub("[\128-\255]", "?")
  end
  return text
end

-- Cuts {s} into pieces no wider than {width}, between characters. Code wraps
-- this way: breaking at spaces would move tokens to where they are not.
local function hard_wrap(s, width, dw)
  local out, cur, cur_w = {}, {}, 0
  for _, cp in utf8.codes(s) do
    local ch = utf8.char(cp)
    local w = dw(ch)
    if cur_w > 0 and cur_w + w > width then
      out[#out + 1] = table.concat(cur)
      cur, cur_w = {}, 0
    end
    cur[#cur + 1] = ch
    cur_w = cur_w + w
  end
  out[#out + 1] = table.concat(cur)
  return out
end

function M.wrap_words(text, width, dw)
  dw = dw or plain_width
  local lines, cur, cur_w = {}, nil, 0
  for word in text:gmatch("%S+") do
    local w = dw(word)
    if cur and cur_w + 1 + w <= width then
      cur, cur_w = cur .. " " .. word, cur_w + 1 + w
    else
      if cur then
        lines[#lines + 1] = cur
      end
      local pieces = w > width and hard_wrap(word, width, dw) or { word }
      for i = 1, #pieces - 1 do
        lines[#lines + 1] = pieces[i]
      end
      cur = pieces[#pieces]
      cur_w = dw(cur)
    end
  end
  if cur then
    lines[#lines + 1] = cur
  end
  return lines
end

-- One entry per screen row, with `lineno` only on the first row of each
-- source line, so a wrapped line still reads as one.
function M.rows(code, width, dw)
  dw = dw or plain_width
  local rows, n = {}, 0
  for line in (code .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    for i, piece in ipairs(hard_wrap(line, width, dw)) do
      rows[#rows + 1] = { lineno = i == 1 and n or nil, text = piece }
    end
  end
  return rows
end

-- Everything the panel draws for one call at one width. {code} is the
-- sanitized command, formatted or as written; {inner} is the width inside the
-- border.
function M.content(call, code, inner, dw)
  dw = dw or plain_width
  code = code:gsub("\n+$", "")
  local total = select(2, code:gsub("\n", "")) + 1
  local gutter = #tostring(total) + #GAP
  local sentence = call.sentence and M.wrap_words(M.sanitize(call.sentence), inner, dw) or {}
  return {
    sentence = sentence,
    where = call.workdir and ("in " .. M.sanitize(call.workdir)) or nil,
    rows = M.rows(code, math.max(1, inner - gutter), dw),
    total = total,
    gutter = gutter,
  }
end

local function header(content)
  local out = {}
  for _, line in ipairs(content.sentence) do
    out[#out + 1] = line
  end
  if content.where then
    out[#out + 1] = { { content.where, DIM } }
  end
  if #out > 0 then
    out[#out + 1] = ""
  end
  return out
end

local function code_line(content, i)
  local row = content.rows[i]
  local num = row.lineno and tostring(row.lineno) or ""
  local pad = string.rep(" ", content.gutter - #GAP - #num)
  local line = { { pad .. num .. GAP, DIM } }
  local spans = content.styled and content.styled[i]
  if spans then
    for _, span in ipairs(spans) do
      line[#line + 1] = span
    end
  else
    line[#line + 1] = { row.text }
  end
  return line
end

function M.compact(content)
  local lines = header(content)
  local shown = math.min(#content.rows, M.COMPACT_ROWS)
  for i = 1, shown do
    lines[#lines + 1] = code_line(content, i)
  end
  if shown < #content.rows then
    local last = 0
    for i = shown, 1, -1 do
      if content.rows[i].lineno then
        last = content.rows[i].lineno
        break
      end
    end
    local more = content.total - last
    local note = "… v shows all"
    if more > 0 then
      note = string.format("… %d more lines, v shows all", more)
    end
    lines[#lines + 1] = { { note, DIM } }
  end
  return lines
end

function M.compact_height(line_count, term_rows)
  local room = term_rows - M.PROMPT_ROWS
  return math.max(M.MIN_HEIGHT, math.min(line_count + M.CHROME, room))
end

local function source(content)
  return content.formatted and "shfmt" or "as written"
end

function M.compact_title(content)
  return string.format(" bash · %d lines · %s ", content.total, source(content))
end

-- The header stays put in the full view and the code scrolls under it.
function M.visible_rows(content, height)
  return math.max(1, height - M.CHROME - #header(content))
end

function M.clamp_top(top, content, height)
  local max_top = math.max(1, #content.rows - M.visible_rows(content, height) + 1)
  return math.max(1, math.min(top, max_top))
end

function M.full(content, height, top)
  local lines = header(content)
  local last = math.min(#content.rows, top + M.visible_rows(content, height) - 1)
  for i = top, last do
    lines[#lines + 1] = code_line(content, i)
  end
  return lines
end

function M.full_title(content, top, height)
  local last = math.min(#content.rows, top + M.visible_rows(content, height) - 1)
  return string.format(
    " bash · %s · rows %d-%d of %d ",
    source(content),
    top,
    last,
    #content.rows
  )
end

function M.footer(state)
  local keys = {}
  if state.can_answer then
    keys[#keys + 1] = { "y", "allow" }
    keys[#keys + 1] = { "n", "deny" }
  end
  if state.mode == "full" then
    keys[#keys + 1] = { "j/k", "scroll" }
    keys[#keys + 1] = { "v", "back" }
  else
    keys[#keys + 1] = { "v", "full view" }
  end
  keys[#keys + 1] = { "Tab", "more answers" }
  return keys
end

-- "allow", "deny" or "hand_off" for the panel to act on, "redraw" after the
-- view changed, or nil for a key that does nothing here. {content} is nil
-- while the panel has nothing drawn for the current call.
function M.handle_key(state, key, content, height)
  if key == "<Tab>" or key == "<C-c>" then
    return "hand_off"
  end
  -- Nothing is drawn yet, or only a call the panel has moved off: an answer
  -- now could settle a call the user never saw, but the way out always works.
  if content == nil then
    return nil
  end
  if key == "y" or key == "n" then
    if not state.can_answer then
      return nil
    end
    return key == "y" and "allow" or "deny"
  end
  if state.mode == "compact" then
    if key == "v" then
      state.mode, state.top = "full", 1
      return "redraw"
    end
    return nil
  end
  if key == "v" or key == "<Esc>" then
    state.mode = "compact"
    return "redraw"
  end
  local page = M.visible_rows(content, height)
  local top = state.top
  if SCROLL[key] then
    top = top + SCROLL[key]
  elseif key == "<PageDown>" or key == "<Space>" then
    top = top + page
  elseif key == "<PageUp>" then
    top = top - page
  elseif key == "g" then
    top = 1
  elseif key == "G" then
    top = #content.rows
  else
    return nil
  end
  top = M.clamp_top(top, content, height)
  if top == state.top then
    return nil
  end
  state.top = top
  return "redraw"
end

return M
