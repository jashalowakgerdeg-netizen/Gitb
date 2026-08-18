#!/usr/bin/env python3
"""Collapse top-level `local function` declarations in a Lua chunk into a single
`fn` table so the file stays under LuaJIT's 200-local-per-scope limit.

The transform:
  1. finds every top-level `local function NAME(` (column 0),
  2. rewrites the definition to `function fn.NAME(`,
  3. rewrites every reference to NAME (call sites and value-passing) to `fn.NAME`,
     skipping string literals and comments so no text data is corrupted.

Only whole-identifier references not already preceded by `.`/`:`/word chars are
rewritten, so field and method accesses (`ui.get`, `ent:get_anim_overlay`) and
longer identifiers (`set_int`, `resolver`) are left untouched.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


def split_code_and_noncode(src: str):
    """Yield (is_code, text) segments, treating Lua strings and comments as
    non-code so replacements never touch their contents."""
    i, n = 0, len(src)
    out = []
    buf = []

    def flush_code():
        if buf:
            out.append((True, "".join(buf)))
            buf.clear()

    while i < n:
        ch = src[i]
        two = src[i:i + 2]
        # long bracket string or comment: [[ ]], [=[ ]=], --[[ ]], --[=[ ]=]
        long_open = None
        if two == "--":
            m = re.match(r"--(\[=*\[)", src[i:])
            if m:
                long_open = m.group(1)
                start = i + 2
            else:
                flush_code()
                end = src.find("\n", i)
                end = n if end == -1 else end
                out.append((False, src[i:end]))
                i = end
                continue
        elif ch == "[":
            m = re.match(r"\[=*\[", src[i:])
            if m:
                long_open = m.group(0)
                start = i
        if long_open is not None:
            level = long_open.count("=")
            close = "]" + "=" * level + "]"
            end = src.find(close, i + len(long_open) + (2 if two == "--" else 0))
            end = n if end == -1 else end + len(close)
            flush_code()
            out.append((False, src[i:end]))
            i = end
            continue
        if ch in ("'", '"'):
            flush_code()
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == ch:
                    j += 1
                    break
                j += 1
            out.append((False, src[i:j]))
            i = j
            continue
        buf.append(ch)
        i += 1
    flush_code()
    return out


def transform(src: str) -> tuple[str, int]:
    names = sorted(set(re.findall(r"^local function (\w+)\(", src, re.M)), key=len, reverse=True)
    if not names:
        return src, 0

    alt = "|".join(re.escape(name) for name in names)
    def_re = re.compile(r"^local function (" + alt + r")\(", re.M)
    # A top-level function is only ever referenced as a call `NAME(` or as a
    # passed value; a bareword `NAME =` is always a table-constructor key or an
    # assignment (never a function reference), so the trailing `=` lookahead keeps
    # UI field keys like `jump_scout =` and `ms =` from being rewritten.
    ref_re = re.compile(r"(?<![\w.:])(" + alt + r")(?![\w])(?!\s*=(?!=))")

    segments = split_code_and_noncode(src)
    rebuilt = []
    for is_code, text in segments:
        if is_code:
            text = def_re.sub(lambda m: "function fn." + m.group(1) + "(", text)
            text = ref_re.sub(lambda m: "fn." + m.group(1), text)
        rebuilt.append(text)
    result = "".join(rebuilt)

    # declare the namespace table once, right after the tick-interval constants
    anchor = "local TICK_INV = 1 / TICK_IV\n"
    if "local fn = {}" not in result:
        result = result.replace(anchor, anchor + "\n-- cold/whole-script namespace: keeps the chunk under LuaJIT's 200-local cap\nlocal fn = {}\n", 1)
    return result, len(names)


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "cocoyaw.lua")
    src = path.read_text(encoding="utf-8")
    result, count = transform(src)
    path.write_text(result, encoding="utf-8")
    print(f"namespaced {count} functions into fn.* in {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
