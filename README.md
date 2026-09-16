# maki-plugins

Personal [maki](https://maki.sh) plugin package: review UI, context panel, goal
mode, an automatic permission reviewer, and a few smaller quality-of-life
plugins.

## Install

```lua
-- ~/.config/maki/init.lua
maki.pack.add({ "https://github.com/Firaenix/maki-plugins" })
```

Maki prompts once to install and once to approve the permissions in
`plugin.toml`, pins the commit in `~/.config/maki/pack-lock.json`, and loads
every file in `plugin/` at startup. Update with `/packupdate maki-plugins`,
remove with `/packdel maki-plugins` after dropping the `pack.add` entry.

## What is in here

| Entry | Surface | What it does |
| --- | --- | --- |
| `plugin/automode.lua` | `/automode` | Reviewer models classify tool calls that would otherwise prompt, via `maki.api.register_reviewer`. Toggle, status, model chain, and a verdict log showing the exact request each reviewer saw. |
| `plugin/context.lua` | `/context` | Context-window usage panel: window and pricing from `maki.model.info`, with a `/v1/models` discovery fallback on older binaries. |
| `plugin/goal.lua` | `/goal`, `goal_complete` tool | Keeps the agent working across turns until the goal is met, the budget or round cap is hit, or you intervene. |
| `plugin/pr_mention.lua` | `#` completer | Completes a PR/MR link from the repo in cwd via `gh` or `glab`. |
| `plugin/rv.lua` | `/rv` | In-maki review UI over the [`rv`](https://github.com/Firaenix/rv) CLI: file tree, diff pane, anchored comments, reply/resolve/abandon. |
| `plugin/skills.lua` | `/skills` | Lists every skill the bundled `skill` tool would discover, without asking the model. |
| `plugin/tool-alias.lua` | tool hook | Strips CLIProxyAPI's MCP alias decoration from tool names inside string payloads (`code_execution.code`, `batch.tool_calls[].tool`). |
| `lua/model_select.lua` | module | Shared model catalog + picker used by `automode` and `context`. |

## Requirements

- maki 0.5.0+. Several plugins use APIs that only exist on the
  [Firaenix/maki](https://github.com/Firaenix/maki) fork
  (`register_reviewer`, `register_input_completer`, `maki.ui.picker`,
  `maki.model.info`). Each one feature-detects and degrades instead of
  failing to load.
- `rv` on `PATH` for `/rv`; `gh` or `glab` for `#` completion.

## Automode policy

`automode.lua` reads its allow/deny policy from
`<maki-config>/automode-policy.md`, plus `<cwd>/.maki/automode.md` for
per-project rules. Neither is shipped here — copy
`automode-policy.example.md` to `~/.config/maki/automode-policy.md` and edit.

## Development

```bash
stylua .          # config in .stylua.toml
```

Point maki at a local checkout instead of the pinned revision by cloning into
`<maki-data>/site/pack/<group>/start/maki-plugins/`; see
[Lua packages](https://maki.sh/docs/packages/).
