#!/usr/bin/env python3
"""PreToolUse (Bash): making the repository public, or force-pushing, always asks 藤川さん first.

Turning the repository public cannot be undone once it is seen, so the pre-publish-check
skill must run and 藤川さん must say yes. This hook turns such a command into a confirmation
prompt instead of letting it run silently.
"""
import json
import re
import sys

RISKY = [
    (re.compile(r"gh\s+repo\s+edit\b.*--visibility"), "リポジトリの公開・非公開の切り替え"),
    (re.compile(r"git\s+push\b.*(--force\b|-f\b)(?!-with-lease)"), "強制 push（履歴の書き換え）"),
]


def main():
    data = json.load(sys.stdin)
    command = (data.get("tool_input", {}) or {}).get("command", "")
    for pattern, label in RISKY:
        if pattern.search(command):
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "ask",
                    "permissionDecisionReason": f"{label}は取り消せません。pre-publish-check の点検を終え、藤川さんの了承をもらってから実行してください。",
                }
            }, ensure_ascii=False))
            sys.exit(0)
    sys.exit(0)


if __name__ == "__main__":
    main()
