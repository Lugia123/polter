#!/usr/bin/env python3
"""An undocumented COM call is only allowed here because something catches it.

# What is being guarded, and why prose cannot guard it

`windows/host/src/osk.rs` reaches the Windows touch keyboard through
`ITipInvocation`, a class that appears in **no header in this tree and no
public SDK**. Its CLSID and IID could not be verified on the machine this port
is written on. Shipping constants like that is defensible for exactly one
reason, written in that file: **being wrong about them costs a fallback and
nothing else** -- `CoCreateInstance` fails, `QueryInterface` fails, or the
machine has no touch keyboard, and all three end at `osk.exe`.

That reason is load-bearing and it is held up by a branch in one function. If
somebody later tidies the fallback away, the argument becomes false and
nothing says so: the code still compiles, the happy path still works on a
machine where the class happens to be registered, and the day Microsoft
renumbers it the action goes silent. **A claim that rests on a branch needs
something that notices the branch leaving.**

# The three checks

  1. **The touch-keyboard attempt is there.** Without it this file is guarding
     a fallback with nothing to fall back from, and should be deleted.
  2. **The fallback is there, after it.** `shellopen::detached` must still be
     reached in the same function, below the attempt.

     ⚠️ **This pins a name, and the name has already moved once.** It read
     `ShellExecuteW` until task 324 took that call off the window thread, and
     this checker went red on a healthy tree the moment the fix landed --
     correctly, in the sense that it noticed, and wrongly, in the sense that
     nothing about the fallback had changed. What check 2 means is *is there
     a fallback*; what it asks is *is the fallback still spelled this way*.
     Owed: ask the first question instead.
  3. **Each GUID is written once.** Two copies of an unverified constant is
     two places to correct when the machine finally says what it really is --
     and the second copy is always the one nobody finds.

The values themselves are **not** written here. Copying them into the checker
would create the second copy check 3 exists to forbid.

# NOT CHECKED

  * **Whether the constants are right.** Nothing on this machine can say. The
    file records how to give them a provenance on a machine that has one.
  * **Whether the call raises a keyboard.** `Toggle` returning `S_OK` is all
    the process can see; the keyboard is a fact about a screen.
  * **Whether the fallback works**, only that it is still reached.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OSK = os.path.join(HERE, "..", "host", "src", "osk.rs")


def strip_comments(src):
    return "\n".join(re.sub(r"//.*", "", ln) for ln in src.split("\n"))


def findings(src):
    out = []
    code = strip_comments(src)

    guids = re.findall(r"GUID::from_u128\(\s*(0x[0-9a-fA-F_]+)\s*\)", code)
    for g in set(guids):
        if guids.count(g) != 1:
            out.append(
                f"the constant {g} is written {guids.count(g)} times. An unverified GUID "
                "must have exactly one place to correct; the second copy is the one nobody "
                "finds when the machine finally says what it really is"
            )
    if len(set(guids)) < 2:
        out.append(
            f"only {len(set(guids))} GUID constant(s) found, expected the class and the "
            "interface. Either the touch-keyboard path is gone -- in which case this "
            "checker is guarding nothing and should go with it -- or this scan stopped "
            "matching"
        )
        return out

    body = None
    at = code.find("pub fn show(")
    if at >= 0:
        depth, i = 0, code.index("{", at)
        start = i
        while i < len(code):
            if code[i] == "{":
                depth += 1
            elif code[i] == "}":
                depth -= 1
                if depth == 0:
                    body = code[start : i + 1]
                    break
            i += 1
    if body is None:
        out.append("`pub fn show(` was not found; this checker is looking at nothing")
        return out

    attempt = body.find("touch_keyboard(")
    fallback = body.find("shellopen::detached")
    if attempt < 0:
        out.append(
            "`show` no longer tries the touch keyboard. If that path is gone this file "
            "is guarding a fallback with nothing to fall back from and should be deleted "
            "in the same edit"
        )
    if fallback < 0:
        out.append(
            "`show` no longer reaches `shellopen::detached`. **That branch is the entire reason "
            "an unverified, undocumented CLSID is allowed in this tree**: without it, a "
            "class Microsoft renumbers takes the action silent instead of taking it to "
            "`osk.exe`"
        )
    elif attempt >= 0 and fallback < attempt:
        out.append(
            "`shellopen::detached` is reached before the touch-keyboard attempt. The order is "
            "the design: the touch keyboard is what this action is for, and `osk.exe` is "
            "what is left when it cannot be had"
        )
    return out


GOOD = '''
const A: GUID = GUID::from_u128(0x1111);
const B: GUID = GUID::from_u128(0x2222);
pub fn show(frame: HWND) -> bool {
    match touch_keyboard(frame) { Ok(()) => return true, Err(_) => {} }
    let r = unsafe { shellopen::detached(None) };
    r
}
'''


def self_test():
    cases = [
        ("the shape today", GOOD, 0),
        ("the fallback tidied away",
         GOOD.replace("    let r = unsafe { shellopen::detached(None) };\n    r\n", "    false\n"), 1),
        ("the touch attempt removed",
         GOOD.replace("    match touch_keyboard(frame) { Ok(()) => return true, Err(_) => {} }\n", ""), 1),
        ("a second copy of one constant",
         GOOD.replace("const B: GUID = GUID::from_u128(0x2222);",
                      "const B: GUID = GUID::from_u128(0x1111);"), 2),
        ("the two in the wrong order",
         GOOD.replace("    match touch_keyboard(frame) { Ok(()) => return true, Err(_) => {} }\n"
                      "    let r = unsafe { shellopen::detached(None) };\n    r\n",
                      "    let r = unsafe { shellopen::detached(None) };\n"
                      "    match touch_keyboard(frame) { Ok(()) => return true, Err(_) => {} }\n    r\n"), 1),
        # **Built so that it can tell the two answers apart.** Two distinct
        # constants and both call names, all inside comments: with the
        # stripping the scan finds no constants and stops at one finding;
        # without it, it finds two and goes on to report the missing attempt
        # and the missing fallback, which is two. **A probe whose expected
        # number is the same either way proves nothing** -- the first version
        # of this case was exactly that.
        ("both constants and both calls, in comments only",
         "// GUID::from_u128(0x1111) and GUID::from_u128(0x2222)\n"
         "// touch_keyboard( and shellopen::detached\n"
         "pub fn show(f: HWND) -> bool { false }\n", 1),
    ]
    for what, src, want in cases:
        got = len(findings(src))
        if got != want:
            print(f"probe self-test FAILED: {what} gave {got} finding(s), expected {want}:")
            for f in findings(src):
                print(f"    {f}")
            return False
    print("probe self-test: OK (fallback removed, attempt removed, duplicated constant, "
          "wrong order, comments only)")
    return True


def main():
    if not self_test():
        return 1
    try:
        with open(OSK, encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        print(f"cannot read windows/host/src/osk.rs: {e}")
        return 1
    found = findings(src)
    n = len(set(re.findall(r"GUID::from_u128\(\s*(0x[0-9a-fA-F_]+)\s*\)", strip_comments(src))))
    print(f"osk.rs: {n} unverified GUID constant(s), each written once; "
          "the touch-keyboard attempt and its fallback are both in `show`")
    for f in found:
        print(f"HIT    osk.rs {f}")
    if found:
        print(f"\n{len(found)} problem(s): the reason an undocumented CLSID is allowed here "
              "no longer holds.")
        return 1
    print("OK: an undocumented call with something underneath it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
