#!/usr/bin/env python3
"""PreToolUse (Write/Edit): stop Claude before it writes an API key or touches secrets/ or private-data/.

The git pre-commit hook catches keys at commit time; this catches them one step earlier,
before they ever reach a file in the repository. Exit code 2 blocks the tool call and
shows the message to Claude.
"""
import json
import re
import sys

KEY = re.compile(r"sk-ant-[A-Za-z0-9_-]{10,}|AIza[0-9A-Za-z_-]{35}")
PRIVATE_DIRS = ("/secrets/", "/private-data/")


def texts(tool_input):
    for field in ("content", "new_string"):
        if isinstance(tool_input.get(field), str):
            yield tool_input[field]
    for edit in tool_input.get("edits", []) or []:
        if isinstance(edit, dict) and isinstance(edit.get("new_string"), str):
            yield edit["new_string"]


def main():
    data = json.load(sys.stdin)
    tool_input = data.get("tool_input", {}) or {}
    path = "/" + str(tool_input.get("file_path", "")).lstrip("/")
    if any(d in path for d in PRIVATE_DIRS):
        print("secrets/ と private-data/ は Claude が書き込まない場所です（藤川さんが手で置く）。", file=sys.stderr)
        sys.exit(2)
    if any(KEY.search(t) for t in texts(tool_input)):
        print("API キーらしい文字列を書き込もうとしました。鍵はキーチェーンか secrets/ にだけ置き、リポジトリには書きません。", file=sys.stderr)
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
