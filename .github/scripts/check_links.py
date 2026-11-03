"""Check that relative links in the repository's Markdown files point to files that exist.

Only relative links are checked (no network). Anchors (#...) on the same page are checked against
the page's headings using GitHub's slug rules (lowercase, spaces to "-", most punctuation removed).
"""

import pathlib
import re
import sys
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parents[2]
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.*)$", re.MULTILINE)
FENCE = re.compile(r"```.*?```", re.DOTALL)


def slug(text: str) -> str:
    text = text.strip().lower()
    out = []
    for ch in text:
        if ch in " -":
            out.append("-")
        elif ch == "_" or ch.isalnum():
            out.append(ch)
        elif unicodedata.category(ch).startswith(("L", "N")):
            out.append(ch)
    return "".join(out)


def main() -> int:
    errors = []
    files = [p for p in ROOT.rglob("*.md") if ".build" not in p.parts and "build" not in p.parts]
    for md in sorted(files):
        text = FENCE.sub("", md.read_text(encoding="utf-8"))
        anchors = {slug(h) for h in HEADING.findall(text)}
        for target in LINK.findall(text):
            if re.match(r"^[a-z]+:", target):  # http:, https:, mailto:
                continue
            path, _, anchor = target.partition("#")
            if not path:
                if anchor and anchor not in anchors:
                    errors.append(f"{md.relative_to(ROOT)}: no heading for #{anchor}")
                continue
            dest = (md.parent / path).resolve()
            if not dest.exists():
                errors.append(f"{md.relative_to(ROOT)}: missing {target}")
    for e in errors:
        print(f"::error::{e}")
    print(f"checked {len(files)} Markdown files, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
