#!/usr/bin/env python3
"""PostToolUse (Write/Edit): warn when new app text sounds medical.

The contest disqualifies medical-advice AI, and CLAUDE.md forbids medical or diagnostic wording.
The app helps people recall things themselves; it does not treat or improve memory.
Only the newly written text in App/ and DowasureCore/Sources/ is checked.
Exit code 2 after the edit shows the message to Claude so it can rewrite the words.
"""
import json
import re
import sys

MEDICAL = re.compile(r"認知症|認知機能|脳トレ|治療|予防|診察|処方|記憶力(が|を)?(改善|向上|回復)")
ALLOWED = re.compile(r"行いません|しません|ではありません")
CHECKED = ("/App/", "/DowasureCore/Sources/")


def main():
    data = json.load(sys.stdin)
    tool_input = data.get("tool_input", {}) or {}
    path = "/" + str(tool_input.get("file_path", "")).lstrip("/")
    if not any(d in path for d in CHECKED):
        sys.exit(0)
    new = [tool_input.get("content") or "", tool_input.get("new_string") or ""]
    new += [e.get("new_string", "") for e in tool_input.get("edits", []) or [] if isinstance(e, dict)]
    hits = []
    for text in new:
        for line in text.splitlines():
            if MEDICAL.search(line) and not ALLOWED.search(line):
                hits.append(line.strip())
    if hits:
        print("医療めいた言葉が入りました（大会の失格例・CLAUDE.md の禁止事項）。"
              "「自分で思い出す手伝い」の言い方に直してください：\n" + "\n".join(hits[:5]), file=sys.stderr)
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
