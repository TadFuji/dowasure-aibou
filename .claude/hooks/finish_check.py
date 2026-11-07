#!/usr/bin/env python3
"""Stop: before Claude says it is done, check the two standing rules of this project.

1. If the core (DowasureCore/) changed and Swift is available (the Mac), run `swift test`.
2. If code changed but docs/開発記録.md did not, remind Claude to add to the development log
   (藤川さんの常設依頼, see .claude/skills/dev-log/).
Exit code 2 sends the message back to Claude, which then keeps working. When the hook has
already asked once (stop_hook_active), it lets Claude stop, so it never loops.
"""
import json
import os
import shutil
import subprocess
import sys


def changed_files(root):
    out = subprocess.run(["git", "status", "--porcelain"], cwd=root, capture_output=True, text=True)
    return [line[3:].strip('"') for line in out.stdout.splitlines() if len(line) > 3]


def main():
    data = json.load(sys.stdin)
    if data.get("stop_hook_active"):
        sys.exit(0)
    root = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
    files = changed_files(root)
    if not files:
        sys.exit(0)
    problems = []
    core = [f for f in files if f.startswith("DowasureCore/")]
    if core and shutil.which("swift"):
        test = subprocess.run(["swift", "test"], cwd=os.path.join(root, "DowasureCore"),
                              capture_output=True, text=True, timeout=540)
        if test.returncode != 0:
            tail = "\n".join((test.stdout + test.stderr).splitlines()[-25:])
            problems.append("swift test が失敗しています。直してから終えてください：\n" + tail)
    code = [f for f in files if f.startswith(("App/", "DowasureCore/", "UITests/", "project.yml"))]
    if code and not any("開発記録" in f for f in files):
        problems.append("コードを変えましたが docs/開発記録.md に追記がありません。dev-log スキルの形で追記してください。")
    if problems:
        print("\n\n".join(problems), file=sys.stderr)
        sys.exit(2)
    sys.exit(0)


if __name__ == "__main__":
    main()
