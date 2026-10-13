---
name: agent-todo
description: 用自然语言管理的个人待办清单，数据是一份你自己拥有的纯文本 JSON（默认 ~/.agent-todo/todos.json）。当用户说「打开待办 / 我的 todo / todolist / 待办清单 / 任务列表」，或「记一条待办」「把 X 标记完成」「删掉待办 X」「我今天还有哪些没做」时使用本技能。Make sure to use this skill whenever the user talks about their personal to-do list, tasks, or reminders — adding, ticking off, editing, deleting, or reviewing them — even if they never say the word "skill" or "todo". Skip it for project task trackers that belong to a codebase, not the person.
---

# agent-todo

A todo list that lives next to your agent: the data is one plain JSON file, the
agent reads and writes it in plain language, and an optional desktop widget
shows the same file as an always-on-top floating panel.

Everything is in `scripts/todo.py` (Python 3 standard library only — no
dependencies, no server, no account).

## The data

- File: `~/.agent-todo/todos.json` — override the directory with the
  `AGENT_TODO_HOME` env var. It is the single source of truth; the user may edit
  it by hand.
- One todo: `{id, text, done, priority(high|mid|low), due(YYYY-MM-DD|""), tags("a,b"|""), createdAt}`.
- Never store todos anywhere else (not in chat, not in a scratch file) — write
  them here so the widget and the agent always agree.

## Way 1 — one-liners (works everywhere)

Use these for "remember X", "mark X done", "what's left?":

```bash
python3 scripts/todo.py add "买牛奶" --priority high --due 2026-10-20 --tags 生活
python3 scripts/todo.py done t3          # tick (--undo untick)
python3 scripts/todo.py rm t3            # delete
python3 scripts/todo.py clear-done       # drop everything ticked
python3 scripts/todo.py list             # plain-text view
```

Reach for the CLI whenever the user is just recording or changing one thing —
it's faster than opening a panel and leaves a tidy one-line confirmation.

## Way 2 — an interactive panel (only on hosts that render surfaces)

If the host exposes a tool that renders **A2UI v0.8** surfaces (a card with
checkboxes / text fields / buttons), you can show the whole list as an editable
panel instead:

```bash
python3 scripts/todo.py render     # prints the A2UI jsonl, one message per line
```

Feed that output to the surface tool, then follow `references/panel.md` to turn
each user action (`todo.add` / `todo.save` / `todo.delete` / …) back into a
`todos.json` write and re-render. If the host has no such tool, ignore this
section entirely and use the CLI.

## The desktop widget

The repo also ships a small macOS floating window (`app/`) that reads the same
`todos.json`: click the header to expand / collapse, `⌥⌘X` to summon or hide.
It is optional — the skill works fully without it. See the repo README to build
it. Because both sides share one file, a change made on the widget shows up to
the agent (and vice versa) within a second.

## Conventions

- Prefer the CLI for single edits; use the panel when the user wants to see or
  tidy the whole list.
- Deleting and "clear done" are irreversible — if the list is long or the user
  was vague, confirm first.
- Keep ids stable; never renumber existing todos (the widget keys off them).
