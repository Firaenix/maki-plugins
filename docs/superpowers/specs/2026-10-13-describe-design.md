# describe: say what a bash call does before you approve it

## Problem

A bash permission prompt shows the tool name and the command cut into top-level
segments, as plain text. A long script arrives as a run of unformatted lines with
nothing saying what it is for, so approving it means reverse-engineering it on the
spot.

## Goal

When a bash call needs approval:

1. Show a one-sentence explanation (20–30 words) of what the call does and why.
2. Show the script formatted and syntax-highlighted.
3. Offer a full-screen view of the whole script on a keypress, to cross-check the
   explanation against the code.

## Decisions

| Question | Answer |
| --- | --- |
| Who writes the sentence | The agent, in the tool call. No second model. |
| Where the full view goes | Full screen, with line numbers and scrolling. `y`/`n` still answer from it. |
| Plugin or core change | A pure plugin. Core changes only for what a plugin cannot do; none are needed. |
| Keys while the prompt is open | The panel takes focus, answers `y`/`n` itself, and hands off on `Tab`. |

## Constraints found in maki (fork/tip, 0.6.3)

- **Key routing.** While a permission prompt is open it consumes every key. The only
  keys that get past it go to a *focused* plugin window: `dispatch_overlay` in
  `maki-ui/src/app/mod.rs` runs `float_mgr.handle_focused_key` first, then the
  prompt. Plugin keymaps and the `keys` an unfocused window claims run after the
  prompt and never fire while it is up. So the panel must be focused to receive
  `v`.
- **Answering.** `maki.session.answer_permission(request_id, {decision, guidance?})`
  (fork branch `pr/answer-open-prompt`) races the native prompt and returns whether
  this answer won.
  - It needs full trust, which this pack's `plugin.toml` grants.
  - It answers only allow or deny once; the always and session answers write rules
    and stay the native prompt's.
  - A win is reported as `PermissionResolved` with `by = "plugin:describe"`.
- **Events.** `PermissionRequested` carries `tool_id`, `request_id`, `tool`,
  `scopes`, `reason` and `subagent_id`, but no tool input. `PermissionResolved`
  carries `request_id`, `decision` and `by`. Both come from the same fork branch.
- **Input capture.** `tool.bash.input` fires before the input is parsed or checked
  against permission rules, and its `ctx.tool_id` is the id the prompt reports as
  `tool_id`. A layer there sees fields the schema does not declare, and may drop
  them before the bash tool parses the call. `ctx.tool_id` is empty for nested
  calls (`batch`, `code_execution`), so those are not captured.
- **Rendering.**
  - `maki.ui.highlight(code, "bash")` returns styled lines.
  - `maki.ui.open_win` floats can be sized up to `"100%"`, anchored to a corner,
    focused, and given a footer of key hints.
  - `win:recv()` delivers key events to a focused window.
- **Jobs.** `maki.fn.jobstart` has no stdin. The script reaches `shfmt` through an
  environment variable: `{ "sh", "-c", 'printf %s "$CMD" | shfmt -i 2 -ci -bn' }`
  with `env = { CMD = command }`. This writes no temp file and needs no shell
  quoting.

## Design

Files:
- `plugin/describe.lua`: wiring.
- `lua/describe_panel.lua`: panel rendering and key loop.

### 1. The sentence

- `maki.api.register_prompt_hint({ slot = "tool_usage", content = … })` tells the
  agent: for any bash command beyond a single simple command, add an `intent` field
  with one sentence of 20–30 words saying what the command does and why.
- A `tool.bash.input` layer:
  - when `ctx.tool_id` is set, stores `{ intent, description, command, workdir }`
    under it;
  - removes `intent` from the input;
  - passes the call on with `prev`.
- The stored entry is dropped on `ToolDone` for that `tool_id`. The table is capped
  at 64 entries, oldest dropped first, so calls that never finish cannot grow it.
- When `intent` is missing, the panel shows `description`, and when both are
  missing it shows no sentence line.

### 2. The panel

- **When it opens.** On `PermissionRequested` for `tool == "bash"` with a captured
  entry for its `tool_id`. Calls with no entry (other tools, nested calls, calls
  made before a reload) get the native prompt unchanged.
- **Queue.** The native prompt queues requests per session and shows the front one.
  The plugin keeps every open request per session, its own and others', in arrival
  order. The panel shows only when the front request of the *focused* session is a
  captured bash call that was not handed off. That keeps the panel and the native
  prompt on the same request, and stops a prompt in a background session from
  taking the keys of the session you are typing in. Focus starts from
  `maki.session.live()` and follows `SessionFocusChanged`.
- **Compact view.** A focused float docked above the prompt. It shows:
  - the sentence, wrapped to the panel width;
  - the first 8 lines of the formatted, highlighted script, then
    `… N more lines` when it is longer;
  - a footer: `y allow · n deny · v full view · Tab more`.

  Exact anchoring is settled during the build. The panel must leave the prompt's
  `tool` line and hint rows visible.
- **Full view.** The same float resized to the whole screen. It shows the sentence,
  then the whole script with line numbers, and the visible line range in the title.
- **Formatting.** On `PermissionRequested` the plugin starts `shfmt` as a job with a
  1-second timeout, and the panel shows the raw command meanwhile.
  - `jobwait` runs right after `jobstart`: waiting on a live job collects every
    line, while an exited one answers only from a capped tail.
  - The job keeps a 1024-line tail, and a result marked `truncated` is dropped.
  - The formatted text replaces the raw command if `shfmt` exits 0 in time;
    otherwise the raw command stays. A result that arrives after its prompt closed
    is dropped.
  - Both are highlighted, and the title says which one is showing.
- **Closing.** On `PermissionResolved` for a request the plugin holds, whoever
  resolved it (the user, the hub, a cancel), it drops that request. The panel then
  moves to the next request or closes.

### 3. Keys

| Key | Compact view | Full view |
| --- | --- | --- |
| `y` | allow, via `answer_permission` | same |
| `n` | deny, via `answer_permission` | same |
| `v` | open full view | back to compact |
| `Esc` | — | back to compact |
| `j`/`k`, `↓`/`↑` | — | scroll one line |
| `PgDn`/`PgUp`, `Space` | — | scroll one page |
| `g`/`G` | — | top/bottom |
| `Tab`, `Ctrl+C` | hand off: hide the panel for this request | same |

- **Hand-off.** Hiding a focused float lets keys reach the native prompt again: the
  float-over-prompt fix makes a hidden window take nothing. The request stays
  handed off until it resolves. That is how the always and session answers, and
  deny with a note, are reached.
- **A lost race.** If `answer_permission` returns `false` (someone else answered
  first), the panel waits for the `PermissionResolved` that is already on its way.
- **Fallback.** If `answer_permission` errors or is missing, the panel drops `y`
  and `n` from the footer and acts as a display with `v` and `Tab`.

### 4. Outside the plugin

- **dotfiles:** `modules/home/maki.nix` adds `pkgs.shfmt` to the maki wrapper's
  `PATH`.
- **README:** a row for `describe`.

## Error handling

- Every autocmd and slot callback is wrapped so that a failure logs a warning
  through `maki.log.warn` and leaves the native prompt alone. The slot layer always
  reaches `prev`, so a bug in the plugin cannot block a call.
- `PermissionRequested` fires only from the TUI, so `maki -p` never opens a panel.
  The prompt hint and the input layer stay on everywhere; the layer strips
  `intent` either way.

## Testing

The pack has no test harness. Checks:

1. `stylua --check`.
2. **Agent compliance, first.** In a real maki 0.6.3 session on cliproxy Claude,
   ask for a long multi-command script and confirm the call carries `intent`. If
   the agent ignores an off-schema field, stop and revisit before building the
   panel.
3. In tmux, as in the remote end-to-end test:
   - the panel opens with the sentence and the formatted script;
   - `y` runs the call, and `n` denies it;
   - `v` opens and scrolls the full view;
   - `Tab` hands off, and `a` then answers at the native prompt;
   - two queued prompts are shown in turn;
   - an answer from maki-hub while the panel is open closes it;
   - with no `shfmt` on `PATH` the raw command shows;
   - a short single command still prompts normally, with `description` as the
     sentence.

## Out of scope

- Tools other than bash.
- An independent second-model summary.
- Sending `intent` to maki-hub so the phone shows it. That's a follow-up once the
  hub is published.

## Risks

- **The agent may not write `intent`.** Models follow a system-prompt rule to add an
  undeclared field less reliably than a declared one, and a provider that enforces
  tool schemas would reject it. Test 2 checks this before anything else is built.
- **A focused panel on every bash prompt changes the prompt's feel.** `Tab` is the
  escape hatch; if it proves tedious, the one-change core alternative is a PR that
  lets keys the prompt does not bind fall through to plugin windows.
