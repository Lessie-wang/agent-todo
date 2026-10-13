#!/usr/bin/env python3
"""agent-todo — a plain-text todo list your agent can read and write.

The whole tool is this one file plus a JSON file. No dependencies, no server,
no account: `todos.json` is yours and you can edit it by hand.

Usage:
  python3 todo.py render                 # print an A2UI surface (for hosts that render panels)
  python3 todo.py list                   # plain-text view
  python3 todo.py add "text" [--priority high|mid|low] [--due YYYY-MM-DD] [--tags a,b]
  python3 todo.py done <id> [--undo]     # tick / untick
  python3 todo.py rm <id>                # delete
  python3 todo.py clear-done             # drop everything ticked

Data file: ~/.agent-todo/todos.json  (override the directory with AGENT_TODO_HOME).
"""
import argparse
import datetime
import json
import os
import sys


def _data_path():
    home = os.environ.get("AGENT_TODO_HOME")
    base = os.path.expanduser(home) if home else os.path.expanduser("~/.agent-todo")
    return os.path.join(base, "todos.json")


DATA = _data_path()
SURFACE = "agent-todo"
PRIORITIES = [("高", "high"), ("中", "mid"), ("低", "low")]
PRI_LABEL = {"high": "高", "mid": "中", "low": "低"}
PRI_ORDER = {"high": 0, "mid": 1, "low": 2, "": 3}


# ---------------------------------------------------------------- persistence
def load():
    if not os.path.exists(DATA):
        return {"collapsed": False, "seq": 0, "todos": []}
    with open(DATA, encoding="utf-8") as f:
        d = json.load(f)
    d.setdefault("collapsed", False)
    d.setdefault("todos", [])
    d.setdefault("seq", len(d["todos"]))
    for t in d["todos"]:
        t.setdefault("done", False)
        t.setdefault("priority", "mid")
        t.setdefault("due", "")
        t.setdefault("tags", "")
    return d


def save(d):
    os.makedirs(os.path.dirname(DATA), exist_ok=True)
    tmp = DATA + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    os.replace(tmp, DATA)


def new_id(d):
    d["seq"] = int(d.get("seq", 0)) + 1
    return "t%d" % d["seq"]


def today():
    return datetime.date.today().isoformat()


def is_overdue(t):
    return (not t.get("done")) and bool(t.get("due")) and t["due"] < today()


# ---------------------------------------------------------------------- render
def _opts():
    return [{"label": lbl, "value": val} for lbl, val in PRIORITIES]


def _sort_key(t):
    # unfinished first, then by priority, then due date; file order breaks ties
    return (1 if t.get("done") else 0, PRI_ORDER.get(t.get("priority", ""), 3), t.get("due") or "9999")


def render(d):
    """Print an A2UI v0.8 surface (newline-delimited JSON messages).

    Only useful on hosts that expose a surface-rendering tool; everywhere else
    use `list`. See references/panel.md for how to drive the interaction.
    """
    todos = sorted(d["todos"], key=_sort_key)
    collapsed = d["collapsed"]
    undone = [t for t in todos if not t.get("done")]
    done = [t for t in todos if t.get("done")]
    view = undone if collapsed else (undone + done)

    comps = []
    comps.append({"id": "root", "component": {"Column": {"children": {"explicitList": [
        "hdr", "addRow", "tools", "div1", "items", "div2", "foot"]}}}})

    head = "📋 我的待办　未完成 %d / 共 %d" % (len(undone), len(todos))
    if collapsed and done:
        head += "　（已折叠 %d 条完成项）" % len(done)
    comps.append({"id": "hdr", "component": {"Text": {"text": {"literalString": head}}}})

    comps.append({"id": "addRow", "component": {"Row": {"children": {"explicitList": [
        "tf_new", "new_pri", "tf_new_due", "tf_new_tags", "btn_add", "add_lbl"]}}}})
    comps.append({"id": "tf_new", "component": {"TextField": {"label": {"literalString": "新待办"}, "text": {"path": "/new/text"}}}})
    comps.append({"id": "new_pri", "component": {"Select": {"label": {"literalString": "优先级"}, "value": {"path": "/new/priority"}, "options": _opts()}}})
    comps.append({"id": "tf_new_due", "component": {"TextField": {"label": {"literalString": "截止"}, "text": {"path": "/new/due"}}}})
    comps.append({"id": "tf_new_tags", "component": {"TextField": {"label": {"literalString": "标签"}, "text": {"path": "/new/tags"}}}})
    comps.append({"id": "btn_add", "component": {"Button": {"child": "add_lbl", "action": {"name": "todo.add"}}}})
    comps.append({"id": "add_lbl", "component": {"Text": {"text": {"literalString": "＋ 添加"}}}})

    comps.append({"id": "tools", "component": {"Row": {"children": {"explicitList": ["btn_collapse", "collapse_lbl"]}}}})
    comps.append({"id": "btn_collapse", "component": {"Button": {"child": "collapse_lbl", "action": {"name": "todo.toggleCollapse"}}}})
    comps.append({"id": "collapse_lbl", "component": {"Text": {"text": {"literalString": "显示已完成" if collapsed else "隐藏已完成"}}}})

    comps.append({"id": "div1", "component": {"Divider": {}}})

    if not view:
        comps.append({"id": "items", "component": {"Text": {"text": {"literalString": "还没有待办 —— 在上面输入框写一条，点「＋ 添加」。"}}}})
    else:
        comps.append({"id": "items", "component": {"Column": {"children": {"explicitList": ["r%d" % i for i in range(len(view))]}}}})
        for i, t in enumerate(view):
            comps.append({"id": "r%d" % i, "component": {"Row": {"children": {"explicitList": [
                "cb%d" % i, "tf%d" % i, "pri%d" % i, "due%d" % i, "tag%d" % i,
                "over%d" % i, "del%d" % i]}}}})
            comps.append({"id": "cb%d" % i, "component": {"CheckBox": {"value": {"path": "/todos/%d/done" % i}}}})
            comps.append({"id": "tf%d" % i, "component": {"TextField": {"label": {"literalString": "内容"}, "text": {"path": "/todos/%d/text" % i}}}})
            comps.append({"id": "pri%d" % i, "component": {"Select": {"label": {"literalString": "优先级"}, "value": {"path": "/todos/%d/priority" % i}, "options": _opts()}}})
            comps.append({"id": "due%d" % i, "component": {"TextField": {"label": {"literalString": "截止"}, "text": {"path": "/todos/%d/due" % i}}}})
            comps.append({"id": "tag%d" % i, "component": {"TextField": {"label": {"literalString": "标签"}, "text": {"path": "/todos/%d/tags" % i}}}})
            comps.append({"id": "over%d" % i, "component": {"Text": {"text": {"literalString": "⏰逾期" if is_overdue(t) else ""}}}})
            comps.append({"id": "del%d" % i, "component": {"Button": {"child": "del%d_lbl" % i, "action": {"name": "todo.delete", "context": [
                {"key": "id", "value": {"literalString": t["id"]}}]}}}})
            comps.append({"id": "del%d_lbl" % i, "component": {"Text": {"text": {"literalString": "🗑"}}}})

    comps.append({"id": "div2", "component": {"Divider": {}}})
    comps.append({"id": "foot", "component": {"Row": {"children": {"explicitList": [
        "bsave", "save_lbl", "bclear", "clear_lbl", "bfinish", "finish_lbl"]}}}})
    comps.append({"id": "bsave", "component": {"Button": {"child": "save_lbl", "action": {"name": "todo.save"}}}})
    comps.append({"id": "save_lbl", "component": {"Text": {"text": {"literalString": "💾 保存修改"}}}})
    comps.append({"id": "bclear", "component": {"Button": {"child": "clear_lbl", "action": {"name": "todo.clearDone"}}}})
    comps.append({"id": "clear_lbl", "component": {"Text": {"text": {"literalString": "🧹 清空已完成"}}}})
    comps.append({"id": "bfinish", "component": {"Button": {"child": "finish_lbl", "action": {"name": "todo.finish"}}}})
    comps.append({"id": "finish_lbl", "component": {"Text": {"text": {"literalString": "✔ 收工"}}}})

    lines = [json.dumps({"surfaceUpdate": {"surfaceId": SURFACE, "components": comps}}, ensure_ascii=False)]
    lines.append(json.dumps({"dataModelUpdate": {"surfaceId": SURFACE, "path": "/new", "contents": [
        {"key": "text", "valueString": ""},
        {"key": "due", "valueString": ""},
        {"key": "priority", "valueString": "mid"},
        {"key": "tags", "valueString": ""}]}}, ensure_ascii=False))
    for i, t in enumerate(view):
        lines.append(json.dumps({"dataModelUpdate": {"surfaceId": SURFACE, "path": "/todos/%d" % i, "contents": [
            {"key": "id", "valueString": t["id"]},
            {"key": "text", "valueString": t.get("text", "")},
            {"key": "done", "valueBoolean": bool(t.get("done"))},
            {"key": "priority", "valueString": t.get("priority", "mid")},
            {"key": "due", "valueString": t.get("due", "")},
            {"key": "tags", "valueString": t.get("tags", "")}]}}, ensure_ascii=False))
    lines.append(json.dumps({"beginRendering": {"surfaceId": SURFACE, "root": "root"}}, ensure_ascii=False))
    print("\n".join(lines))


def plain(d):
    if not d["todos"]:
        print("(空)")
        return
    for t in sorted(d["todos"], key=_sort_key):
        mark = "x" if t.get("done") else " "
        extra = []
        if t.get("priority") and t["priority"] != "mid":
            extra.append(PRI_LABEL.get(t["priority"], t["priority"]))
        if t.get("due"):
            extra.append(t["due"])
        if t.get("tags"):
            extra.append("#" + t["tags"])
        if is_overdue(t):
            extra.append("逾期")
        tail = ("  " + " ".join(extra)) if extra else ""
        print("[%s] %s  {%s}%s" % (mark, t.get("text", ""), t["id"], tail))


# ------------------------------------------------------------------------- cli
def main():
    ap = argparse.ArgumentParser(description="agent-todo — plain-text todo list")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("render", help="print an A2UI surface for the panel")
    sub.add_parser("list", help="plain-text view")

    p_add = sub.add_parser("add")
    p_add.add_argument("text")
    p_add.add_argument("--priority", default="mid", choices=["high", "mid", "low"])
    p_add.add_argument("--due", default="")
    p_add.add_argument("--tags", default="")

    p_done = sub.add_parser("done")
    p_done.add_argument("id")
    p_done.add_argument("--undo", action="store_true")

    p_rm = sub.add_parser("rm")
    p_rm.add_argument("id")

    sub.add_parser("clear-done")

    args = ap.parse_args()
    d = load()

    if args.cmd == "render":
        render(d)
    elif args.cmd == "list":
        plain(d)
    elif args.cmd == "add":
        text = args.text.strip()
        if not text:
            print("empty text, nothing added", file=sys.stderr)
            sys.exit(2)
        d["todos"].append({"id": new_id(d), "text": text, "done": False,
                           "priority": args.priority, "due": args.due.strip(),
                           "tags": args.tags.strip(), "createdAt": today()})
        save(d)
        plain(d)
    elif args.cmd == "done":
        hit = [t for t in d["todos"] if t["id"] == args.id]
        if not hit:
            print("no todo with id=%s" % args.id, file=sys.stderr)
            sys.exit(1)
        for t in hit:
            t["done"] = not args.undo
        save(d)
        plain(d)
    elif args.cmd == "rm":
        before = len(d["todos"])
        d["todos"] = [t for t in d["todos"] if t["id"] != args.id]
        if len(d["todos"]) == before:
            print("no todo with id=%s" % args.id, file=sys.stderr)
            sys.exit(1)
        save(d)
        plain(d)
    elif args.cmd == "clear-done":
        d["todos"] = [t for t in d["todos"] if not t.get("done")]
        save(d)
        plain(d)
    else:
        ap.print_help()
        sys.exit(2)


if __name__ == "__main__":
    main()
