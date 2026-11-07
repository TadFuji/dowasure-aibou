"""Check that relative links in the repository's Markdown files point to files that exist.

Only relative links are checked (no network).
- The path part is URL-decoded first, so both `docs/設計.md` and `docs/%E8%A8%AD%E8%A8%88.md` work.
- An anchor (#...) is checked against the headings of the target Markdown file (or of the same page),
  using GitHub's slug rules (lowercase, spaces to "-", punctuation removed, "-1", "-2" for repeats).
- Anchors on non-Markdown files (such as `Services.swift#L73`, a line on GitHub) are not checked,
  but the file itself must exist.
"""

import pathlib
import re
import sys
import unicodedata
from urllib.parse import unquote

ROOT = pathlib.Path(__file__).resolve().parents[2]
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$", re.MULTILINE)
FENCE = re.compile(r"```.*?```", re.DOTALL)
SKIP_DIRS = {".build", "build", ".git", "node_modules"}


def slug(text: str) -> str:
    text = re.sub(r"`([^`]*)`", r"\1", text)          # inline code keeps its text
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # a link keeps its label
    text = text.replace("*", "").strip().lower()
    out = []
    for ch in text:
        if ch == " " or ch == "-":
            out.append("-")
        elif ch == "_" or ch.isalnum() or unicodedata.category(ch).startswith(("L", "N", "M")):
            out.append(ch)
    return "".join(out)


def anchors_of(md: pathlib.Path, cache: dict) -> set:
    if md not in cache:
        text = FENCE.sub("", md.read_text(encoding="utf-8"))
        seen, found = {}, set()
        for heading in HEADING.findall(text):
            base = slug(heading)
            n = seen.get(base, 0)
            found.add(base if n == 0 else f"{base}-{n}")
            seen[base] = n + 1
        cache[md] = found
    return cache[md]


def main() -> int:
    errors = []
    cache: dict = {}
    files = [p for p in ROOT.rglob("*.md") if not SKIP_DIRS.intersection(p.relative_to(ROOT).parts)]
    for md in sorted(files):
        text = FENCE.sub("", md.read_text(encoding="utf-8"))
        for target in LINK.findall(text):
            if re.match(r"^[a-z]+:", target):  # http:, https:, mailto:
                continue
            path, _, anchor = target.partition("#")
            path, anchor = unquote(path), unquote(anchor)
            dest = md if not path else (md.parent / path).resolve()
            if not dest.exists():
                errors.append(f"{md.relative_to(ROOT)}: missing {target}")
                continue
            if anchor and dest.suffix == ".md" and anchor not in anchors_of(dest, cache):
                errors.append(f"{md.relative_to(ROOT)}: no heading for #{anchor} in {dest.relative_to(ROOT)}")
    for e in errors:
        print(f"::error::{e}")
    print(f"checked {len(files)} Markdown files, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
