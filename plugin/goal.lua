-- Goal mode: /goal <text> keeps the agent working across turns until it
-- calls the goal_complete tool, the budget or round cap is hit, or the
-- human intervenes. Built on the fork's turn-boundary autocmds,
-- session.queue introspection, and dynamic prompt hints.

local BUDGET_USD = 2.00
local MAX_ROUNDS = 12
local CONTINUE_PROMPT = "Continue working toward the active goal. Do not ask me questions; "
  .. "decide and proceed. If the goal is fully achieved, call the goal_complete tool "
  .. "with a one-line summary instead of replying."

local ListPicker = require("maki.list_picker")
local Toast = require("maki.toast")

local goal = nil -- { text, session, rounds, spent, paused }
local settings = { block_questions = true }
local statePath = maki.fs.joinpath(maki.env.state_dir(), "goal.json")
local restored = false

local function save()
  maki.fs.write(statePath, maki.json.encode({ goal = goal, settings = settings }))
end

-- A restart never resumes spending on its own: the goal comes back paused.
local function restore()
  if restored then
    return
  end
  restored = true
  local raw = maki.fs.read(statePath)
  if not raw then
    return
  end
  local ok, decoded = pcall(maki.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return
  end
  if type(decoded.settings) == "table" then
    for key, value in pairs(decoded.settings) do
      settings[key] = value
    end
  end
  if type(decoded.goal) == "table" and decoded.goal.text then
    goal = decoded.goal
    goal.paused = true
    -- The saved session is gone after a restart; resume rebinds to the
    -- session that asks.
    goal.session = nil
  end
end

local function hint()
  if not goal then
    maki.ui.set_status_hint(nil)
    return
  end
  local mark = goal.paused and "◌ paused" or "◎"
  maki.ui.set_status_hint({
    { string.format("%s %d/%d $%.2f", mark, goal.rounds, MAX_ROUNDS, goal.spent), "automode" },
  })
end

local function pause(reason)
  if not goal or goal.paused then
    return
  end
  goal.paused = true
  save()
  hint()
  Toast.show(reason .. " — /goal resume to keep going", { title = "goal paused" })
end

local function mine(ev)
  return goal and (ev.data or {}).session_id == goal.session
end

-- Registered once; the layer consults live state, so no toggling churn.
-- The question tool needs no permission, so it never reaches the permission
-- prompt, and its input slot is where a call can still be stopped.
maki.api.set_slot("tool.question.input", function(prev, input, ctx)
  if goal and not goal.paused and settings.block_questions then
    return nil,
      "goal mode is active: do not ask the user. Decide autonomously, "
        .. "note the assumption, and call goal_complete when the goal is done"
  end
  return prev(input, ctx)
end)

-- The hint re-enters every system prompt, so the objective survives
-- auto-compaction without any bookkeeping here.
maki.api.register_prompt_hint({
  slot = "after_instructions",
  prompt = "system",
  content = function()
    if not goal or goal.paused then
      return ""
    end
    local text = "## Active goal\n\n"
      .. goal.text
      .. "\n\nWork autonomously toward this goal. The only ways this loop ends "
      .. "are calling the goal_complete tool with a one-line summary (also when "
      .. "the goal turns out impossible — say why) or the user interrupting."
    if settings.block_questions then
      text = text
        .. " Never use the question tool and never end a turn to ask the user "
        .. "anything: when something is ambiguous, pick the most reasonable "
        .. "option, note the assumption, and keep going."
    end
    return text
  end,
})

maki.api.register_tool({
  name = "goal_complete",
  description = "Mark the active goal as achieved (or explain why it cannot be). "
    .. "Call this exactly once, when the goal set by the user is fully done.",
  schema = {
    type = "object",
    properties = {
      summary = {
        type = "string",
        description = "One line: what was achieved, or why it cannot be",
        required = true,
      },
    },
  },
  handler = function(input)
    if not goal then
      return { llm_output = "No goal is active." }
    end
    local done = goal
    goal = nil
    save()
    hint()
    Toast.show(
      string.format("%s\n%d rounds · $%.4f", input.summary or "done", done.rounds, done.spent),
      { title = "goal complete", timeout_secs = 10 }
    )
    return { llm_output = "Goal marked complete. Auto-continue is off; wait for the user." }
  end,
})

maki.api.create_autocmd("TurnComplete", {
  callback = function(ev)
    if mine(ev) then
      goal.spent = goal.spent + (tonumber((ev.data or {}).cost) or 0)
      save()
      hint()
    end
  end,
})

maki.api.create_autocmd("TurnError", {
  callback = function(ev)
    if mine(ev) then
      pause("turn errored")
    end
  end,
})

maki.api.create_autocmd({ "SessionFocusChanged", "TurnStart" }, {
  once = true,
  callback = function()
    restore()
    hint()
    if goal then
      Toast.show("restored paused — /goal resume", { title = "goal" })
    end
  end,
})

maki.api.create_autocmd("TurnEnd", {
  callback = function(ev)
    if not mine(ev) or goal.paused then
      return
    end
    local reason = (ev.data or {}).reason
    if reason == "cancelled" then
      pause("you cancelled")
      return
    end
    if goal.spent >= BUDGET_USD then
      pause(string.format("budget spent ($%.2f)", goal.spent))
      return
    end
    if goal.rounds >= MAX_ROUNDS then
      pause(MAX_ROUNDS .. " rounds without goal_complete")
      return
    end
    maki.async.run(function()
      -- Re-check inside the async hop: the human may have typed meanwhile.
      local q = maki.session.queue()
      if not goal or goal.paused or (q and q.count > 0) then
        return
      end
      goal.rounds = goal.rounds + 1
      save()
      hint()
      maki.session.prompt(CONTINUE_PROMPT, { session = goal.session })
    end)
  end,
})

local function status_lines()
  if not goal then
    return "no active goal — /goal <text>"
  end
  return string.format(
    "%s\n%s · round %d/%d · $%.4f of $%.2f",
    goal.text,
    goal.paused and "paused" or "running",
    goal.rounds,
    MAX_ROUNDS,
    goal.spent,
    BUDGET_USD
  )
end

-- Act-and-reopen so the tick marks reflect each toggle.
local function config_menu()
  while true do
    local res = ListPicker.open({
      {
        label = (settings.block_questions and "[x]" or "[ ]") .. " block questions",
        detail = "veto the question tool while a goal runs",
      },
    }, { title = " Goal Config " })
    if res.type ~= "choice" then
      return
    end
    settings.block_questions = not settings.block_questions
    save()
  end
end

local function menu()
  if not goal then
    config_menu()
    return
  end
  local items = {
    { label = goal.paused and "resume" or "pause", data = "toggle" },
    { label = "clear", detail = "drop the goal without completing it", data = "clear" },
    { label = "status", detail = "show text, rounds, spend", data = "status" },
    { label = "config", detail = "toggle goal constraints", data = "config" },
  }
  local res = ListPicker.open(items, { title = " Goal " })
  if res.type ~= "choice" then
    return
  end
  local pick = items[res.index]
  if pick.data == "toggle" then
    if goal.paused then
      goal.paused = false
      goal.session = goal.session or maki.session.current()
      save()
      hint()
      Toast.show("resumed", { title = "goal" })
      maki.session.prompt(CONTINUE_PROMPT, { session = goal.session })
    else
      pause("paused by you")
    end
  elseif pick.data == "clear" then
    goal = nil
    save()
    hint()
    Toast.show("cleared", { title = "goal" })
  elseif pick.data == "config" then
    config_menu()
  else
    Toast.show(status_lines(), { title = "goal", timeout_secs = 8 })
  end
end

maki.api.register_command({
  name = "/goal",
  description = "Set a goal the agent pursues across turns; bare /goal manages it, 'config' toggles constraints",
  nargs = "*",
  handler = function(cmd)
    local text = (cmd and cmd.args or ""):match("^%s*(.-)%s*$")
    if text == "" then
      menu()
    elseif text == "config" then
      config_menu()
    elseif text == "pause" then
      pause("paused by you")
    elseif text == "clear" then
      goal = nil
      save()
      hint()
      Toast.show("cleared", { title = "goal" })
    elseif text == "status" then
      Toast.show(status_lines(), { title = "goal", timeout_secs = 8 })
    elseif text == "resume" then
      if goal then
        goal.paused = false
        goal.session = goal.session or maki.session.current()
        save()
        hint()
        maki.session.prompt(CONTINUE_PROMPT, { session = goal.session })
      end
    else
      goal = {
        text = text,
        session = maki.session.current(),
        rounds = 0,
        spent = 0,
        paused = false,
      }
      save()
      hint()
      Toast.show(
        string.format("set · budget $%.2f · max %d rounds", BUDGET_USD, MAX_ROUNDS),
        { title = "goal" }
      )
      maki.session.prompt(
        "New goal: "
          .. text
          .. "\n\nStart working toward it now, without asking me questions. "
          .. "Call goal_complete when it is fully achieved."
      )
    end
  end,
})
