-- describe: say what a bash call does before you approve it.
--
-- The agent is asked to write bash's `description` as a full sentence on any
-- call beyond a single simple command. A field of describe's own would be
-- cleaner, but maki sends every tool schema with additionalProperties false, so
-- the agent never writes one. A tool.bash.input layer keeps the sentence and the
-- command under the call's id. When the call raises a permission prompt, a
-- focused panel over the prompt shows the sentence and the script, formatted by
-- shfmt and highlighted. `y` and `n` answer, `v` opens the whole script, and
-- `Tab` hands the keys back to the native prompt for its other answers.
--
-- Answering needs maki.session.answer_permission (fork branch
-- pr/answer-open-prompt) and the full trust this pack's plugin.toml grants.
-- Without it the panel still shows, and `Tab` is the way on.

local Store = require("describe_store")
local Panel = require("describe_panel")

local HINT = "- For any bash command beyond a single simple command, write `description` as one"
  .. " sentence of 20-30 words saying what the command does and why you are running it,"
  .. " instead of 3-5 words. The user reads it when approving the call."

local calls = Store.calls()
local prompts = Store.prompts()
local panel = Panel.new(prompts, maki.session.answer_permission ~= nil)

-- A failure in here must never block a call or a prompt: it is logged, and
-- the native prompt carries on alone.
local function guard(name, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      maki.log.warn("describe: " .. name .. ": " .. tostring(err))
    end
  end
end

local function data(ev)
  return ev.data or {}
end

maki.api.register_prompt_hint({ slot = "tool_usage", content = HINT })

maki.api.set_slot(
  "tool.bash.input",
  Store.layer(calls, function(err)
    maki.log.warn("describe: capture: " .. err)
  end)
)

maki.api.create_autocmd("ToolDone", {
  callback = guard("ToolDone", function(ev)
    calls:forget(data(ev).tool_id)
  end),
})

-- Every prompt is queued, describe's or not, so the panel tracks the request
-- the native prompt is really showing.
maki.api.create_autocmd("PermissionRequested", {
  callback = guard("PermissionRequested", function(ev)
    local d = data(ev)
    local call = d.tool == "bash" and calls:get(d.tool_id) or nil
    -- A JSON null arrives as a sentinel, not nil, so test the types.
    prompts:open(d.session_id, d.request_id, call, {
      scopes = type(d.scopes) == "table" and #d.scopes or 1,
      reason = type(d.reason) == "string",
    })
    if call then
      panel:format(d.request_id, call.command)
    end
    panel:sync()
  end),
})

-- Resolved by anyone: the user, a plugin, maki-hub, or a cancel.
maki.api.create_autocmd("PermissionResolved", {
  callback = guard("PermissionResolved", function(ev)
    prompts:resolve(data(ev).request_id)
    panel:sync()
  end),
})

maki.api.create_autocmd("SessionFocusChanged", {
  callback = guard("SessionFocusChanged", function(ev)
    prompts:focus(data(ev).session_id)
    panel:sync()
  end),
})

maki.async.spawn(function()
  for _, live in ipairs(maki.session.live() or {}) do
    if live.focused then
      prompts:focus(live.id)
    end
  end
  panel:sync()
end)
