#!/usr/bin/env python3
"""The software-rendering retry (#18) must name an error the renderer returns.

The Windows host starts itself again with `GALLIUM_DRIVER=llvmpipe` when the
first tab fails because the driver refused the OpenGL version. It can only
tell that failure from the others by the error's name at the start of
`ghostty_app_last_error` -- a string, written by the core in Zig and compared
by the host in Rust. **Rename the error in `wgl.zig` and the retry is simply
never taken**: every test on both sides stays green, and a machine with a
virtual display adapter goes back to showing a box and closing.

So: the name in `software_render.rs`'s `REFUSED` must be returned, as
`error.<name>`, by `src/renderer/opengl/wgl.zig`.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "windows" / "host" / "src" / "software_render.rs"
WGL = ROOT / "src" / "renderer" / "opengl" / "wgl.zig"

REFUSED = re.compile(r'const REFUSED:\s*&str\s*=\s*"([A-Za-z0-9_]+)"')


def returned(zig: str, name: str) -> bool:
    return re.search(r"return\s+error\.%s\s*;" % re.escape(name), zig) is not None


def main() -> int:
    probe_ok = returned("        return error.Abc;\n", "Abc") and not returned("// error.Abc\n", "Abc")
    print(
        "probe self-test:",
        "OK (a returned error and a mentioned one are told apart)"
        if probe_ok
        else "FAILED -- the reader is broken, so nothing below means anything",
    )
    if not probe_ok:
        return 2

    if not HOST.is_file() or not WGL.is_file():
        print(f"FAIL: {HOST.relative_to(ROOT)} or {WGL.relative_to(ROOT)} is not there -- "
              "this checker is looking in the wrong place")
        return 1

    m = REFUSED.search(HOST.read_text(encoding="utf-8"))
    if not m:
        print(f"FAIL: no `const REFUSED: &str = \"...\"` in {HOST.relative_to(ROOT)}. "
              "Either the retry has gone or this reader has")
        return 1
    name = m.group(1)
    if not returned(WGL.read_text(encoding="utf-8"), name):
        print(f"FAIL: the host retries with software rendering on `{name}`, and "
              f"{WGL.relative_to(ROOT)} never returns `error.{name}`. The retry would "
              "never be taken, and nothing else would say so")
        return 1
    print(f"1 name read: the host's `{name}` is returned by wgl.zig.")
    print("NOT CHECKED: that it is returned on the path where the driver refused the "
          "version, and that the retry starts on a real machine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
