# Driving the A2UI panel

`todo.py render` prints one A2UI v0.8 message per line. Hand that string straight
to your host's surface-rendering tool (the tool that accepts A2UI jsonl and shows
a card next to the chat). The surface id is always `agent-todo`.

After the user interacts, the host returns a `userAction` **and** the
`resolvedDataModel`. Update `todos.json` and render again. The loop ends when the
user hits `✔ 收工` (`todo.finish`).

## Action → write-back

| `userAction.name` | Meaning | What to do |
|---|---|---|
| `todo.add` | pressed ＋ | read `resolvedDataModel.new`; if `text` is empty, do nothing; else append a todo (`id` = `seq+1`) |
| `todo.save` | pressed 💾 | copy `text/done/priority/due/tags` from `resolvedDataModel.todos[i]` onto the todo with the same `id` |
| `todo.delete` | pressed 🗑 | remove the todo whose `id` equals `userAction.context.id` |
| `todo.clearDone` | pressed 🧹 | reconcile first, then drop every `done` todo |
| `todo.toggleCollapse` | pressed hide/show | flip the top-level `collapsed` boolean |
| `todo.finish` | pressed ✔ | reconcile, stop the loop, reply with a one-line summary |

## Two things that bite

- **Indices are not stable.** The panel renders sorted (unfinished first, then
  priority, then due). Always match rows back to the file by `id`, never by
  position — `resolvedDataModel.todos[i].id` is included for exactly this.
- **Collapsed hides the done rows.** When `collapsed` is true the surface only
  contains unfinished todos, so `resolvedDataModel.todos` is a partial list.
  Reconcile those, and leave the file's done todos untouched — don't "lose" them
  just because they aren't on screen.

## Where edits land

The panel is the only place that needs `render`; every write goes through the
same `todos.json`. Keep the file format identical so the desktop widget keeps
working: `{collapsed, seq, todos:[…]}`.
