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

local HINT = "- For any bash command beyond a single simple command, write `description` as one"
  .. " sentence of 20-30 words saying what the command does and why you are running it,"
  .. " instead of 3-5 words. The user reads it when approving the call."

local calls = Store.calls()

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

-- The layer only reads the call and always reaches `prev`, so nothing here can
-- stop or change a call.
maki.api.set_slot("tool.bash.input", function(prev, input, ctx)
  guard("capture", function()
    calls:remember(ctx.tool_id, input)
  end)()
  return prev(input, ctx)
end)

maki.api.create_autocmd("ToolDone", {
  callback = guard("ToolDone", function(ev)
    calls:forget(data(ev).tool_id)
  end),
})
