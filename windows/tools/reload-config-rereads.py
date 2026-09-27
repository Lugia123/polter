#!/usr/bin/env python3
"""«重载配置» has to re-read the file and hand the result to the core.

**The defect this is here to stop, as it actually stands today.** `menu.rs`
has a `重载配置` row, `keys.rs` binds `ctrl+shift+,` to `reload_config`, and
the core duly performs the binding and hands
`GHOSTTY_ACTION_RELOAD_CONFIG` to the host. The arm answers `true` -- so the
core believes the host reloaded -- and all it does is ask the settings window
to refresh its error list. **Nothing re-reads the file and nothing tells the
core.** Editing the config and pressing the key changes nothing, with a log
line saying it happened.

`ghostty_app_update_config` is the only way in. It appears **zero times** in
`windows/host/src`, which is why the seven things `App.updateConfig` sets --
the agent socket, the notice interval, the stand-down rule, the three
Poltergeist timers and the compaction threshold -- sit at their struct
defaults for the whole life of a Windows process. Four of those defaults are
`0`, which means *off*.

# What this asserts, and in which direction each one fails

  1. `ffi.rs` declares an `app_update_config` entry point and `main.rs`
     resolves the symbol. Without both there is no way to tell the core
     anything, and every other check below would be describing a call that
     cannot happen.
  2. The `ACTION_RELOAD_CONFIG` arm reaches `app_update_config`. **Reaching
     is measured per file, not per call**, and that is deliberate: the work
     cannot be done in the arm, because `cb_action` arrives on whichever
     thread the core is on and a config swap has to happen on the thread that
     owns windows. The real shape is therefore `arm -> module::request()`,
     a `PostMessage`, and `module::perform()` running later from a window
     procedure -- **there is no call edge between the two halves**, so a
     call-graph walk would report the correct shape as a failure and this
     gate would be edited away within a day. So: the arm must hand off to a
     host module, and that module's file must contain the work.
  3. The same file re-reads from disk, through `load_config` -- the one
     load sequence, the call `main` makes at startup. Handing the core back
     **the config it already has** is a soft update; it is a legitimate thing
     to do (macOS's `reloadConfig(soft:)` does exactly that) and it is *not*
     what a person pressing «重载配置» after editing the file means.
     This used to ask for `config_new`, `config_load_default_files` and
     `config_finalize` by name, which is how it stayed green on a reload
     that had its own copy of the sequence without the command line (#21).
  4. `ACTION_RELOAD_CONFIG` and `ACTION_CONFIG_CHANGE` are **not the same
     arm**. This is not tidiness. `App.updateConfig` ends by performing
     `.config_change` back at the apprt at the end of itself, so an arm that
     re-reads on both tags feeds itself: reload -> update_config ->
     config_change -> reload. The two tags say opposite things -- one asks
     the host to go and read, the other tells the host what was read -- and
     one arm cannot mean both.
  5. Each of the five symbols that make a config -- `ghostty_config_new`,
     `_load_default_files`, `_load_cli_args`, `_load_recursive_files`,
     `_finalize` -- is resolved exactly once in the host, in `main.rs`. The
     fields of `ffi::ConfigLoader` are private, so a second copy of the
     sequence through `api()` does not compile; what the type cannot see is
     a second `GetProcAddress` of the same name, and that is this check.
     Missing counts too: a symbol nobody resolves is a step nobody runs.

**NOT CHECKED, and each of these can be true while this gate is green:**

  * that the reload reaches the core at runtime. This reads text; a
    `PostMessage` to a window nobody pumps looks exactly like a working one.
  * that the two halves of the module are wired to each other. Check 2 asks
    that the file contains the work, not that the arm's half calls the
    other -- that edge is a message, and there is nothing textual to follow.
  * that the config handle stays alive for whoever else holds it.

Those need the test machine. Said out loud rather than letting a green here
be read as a working menu item.

Run:  python3 windows/tools/reload-config-rereads.py
Exit: 0 when all five hold.
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host", "src")

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import cb_action as cb  # noqa: E402


def strip_noise(text: str) -> str:
    """Comments and string bodies out.

    The same reason `action-arms-act.py` does it: this file's own prose names
    `ghostty_app_update_config` a dozen times, and a checker that counted a
    comment would pass on a tree where the call exists only in a sentence
    explaining that it does not.
    """
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r'"(\\.|[^"\\])*"', '""', text)
    return text


def declares(src: str) -> set:
    """Every `fn` name a file defines."""
    return set(re.findall(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*[(<]", src))


QUALIFIED = re.compile(r"\b(?:crate::)?([a-z_][a-z0-9_]*)::[A-Za-z_][A-Za-z0-9_]*\s*\(")
CALL = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def reachable(arm_body: str, files: dict) -> str:
    """The arm plus the whole text of every host file it hands off to.

    A file rather than a function, for the reason set out at the top: the two
    halves of the reload live either side of a `PostMessage` and no call edge
    joins them. `settings_ui::request_errors()` therefore pulls in
    `settings_ui.rs` and nothing else, which is exactly the answer wanted --
    that file does not re-read the config, and today's arm is red on it.
    """
    clean = strip_noise(arm_body)
    # **Stripped per file, then joined.** Stripping the joined text instead
    # let one unbalanced quote -- a Rust `'"'` char literal, a `"` inside a
    # doc comment -- pair with a quote in the *next* file and swallow
    # everything between them. That is how this gate reported a write it was
    # holding in its own hand: the text was there and the span containing it
    # had been eaten. A checker whose subject can silently shrink is the
    # family of defect this directory exists for.
    text = strip_noise(arm_body)
    wanted = set()
    for mod in QUALIFIED.findall(clean):
        wanted.add(mod + ".rs")
    bare = set(CALL.findall(clean))
    for name, src in files.items():
        if name == "main.rs":
            continue
        if bare & declares(src):
            wanted.add(name)
    for name in sorted(wanted):
        if name in files:
            text += "\n" + strip_noise(files[name])
    return text


def analyse(files: dict):
    """`[failure, ...]`. Empty means the reload path is real."""
    bad = []
    main_src = files.get("main.rs", "")
    ffi_src = files.get("ffi.rs", "")

    if not re.search(r"^\s*pub app_update_config\s*:", ffi_src, re.M):
        bad.append("ffi.rs declares no `app_update_config` entry point, so the "
                   "host has no way to hand the core a config at all.")
    if "ghostty_app_update_config" not in main_src:
        bad.append("main.rs resolves no `ghostty_app_update_config` symbol.")

    arms = [(cb.tags_of(p), b, ln) for p, b, ln in cb.arms(main_src)]
    reload_arms = [(t, b, ln) for t, b, ln in arms if "ACTION_RELOAD_CONFIG" in t]

    if not reload_arms:
        bad.append("`cb_action` has no arm for ACTION_RELOAD_CONFIG at all: the "
                   "menu row and ctrl+shift+, fall through to `_ => false`.")
        return bad

    for tags, body, line in reload_arms:
        if "ACTION_CONFIG_CHANGE" in tags:
            bad.append(
                f"main.rs:{line}: ACTION_RELOAD_CONFIG and ACTION_CONFIG_CHANGE "
                "share one arm. They say opposite things -- go and read, versus "
                "here is what was read -- and `App.updateConfig` performs "
                "`.config_change` when it finishes, so one arm that re-reads on "
                "both feeds itself.")
        text = reachable(body, files)
        if "app_update_config" not in text:
            bad.append(
                f"main.rs:{line}: the ACTION_RELOAD_CONFIG arm never reaches "
                "`app_update_config`. It may log, it may refresh the error "
                "list; the core is never told, so nothing the config says takes "
                "effect and the arm's `true` is a claim it did not meet.")
        if not re.search(r"\.load_config\s*\(", text):
            bad.append(
                f"main.rs:{line}: the ACTION_RELOAD_CONFIG arm never reaches "
                "`load_config` -- it does not re-read the file, so a config the "
                "user just edited is not what the core would be handed.")

    # 5 reads the raw text: the names are string literals, which is exactly
    # what `strip_noise` removes.
    for sym in LOAD_SYMBOLS:
        quoted = '"%s"' % sym
        where = {name: src.count(quoted) for name, src in files.items() if quoted in src}
        total = sum(where.values())
        if total != 1 or "main.rs" not in where:
            seen = ", ".join("%s x%d" % kv for kv in sorted(where.items())) or "nowhere"
            bad.append(
                f"`{sym}` is resolved {total} time(s) ({seen}); it must be "
                "resolved once, in main.rs, into `ConfigLoader::resolve`. A "
                "second resolution is a second load sequence the type cannot "
                "see; none is a step of the sequence that never runs.")
    return bad


LOAD_SYMBOLS = (
    "ghostty_config_new",
    "ghostty_config_load_default_files",
    "ghostty_config_load_cli_args",
    "ghostty_config_load_recursive_files",
    "ghostty_config_finalize",
)
_RESOLVE = "".join('sym!(internal, "%s"), ' % s for s in LOAD_SYMBOLS)


# -- self-test ---------------------------------------------------------------
#
# **A gate that has never been red and a gate that does not exist look the
# same when green.** Both directions are pinned here, and they run before the
# tree is read so a broken probe cannot report a clean tree.

GOOD = {
    "main.rs": '''
        extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
            match action.tag {
                ACTION_CONFIG_CHANGE => { reload::adopt(); true }
                ACTION_RELOAD_CONFIG => { reload::request(); true }
                _ => false,
            }
        }
        fn resolve() { app_update_config: sym!(internal, "ghostty_app_update_config"), }
    ''' + "fn load_api() { ConfigLoader::resolve(" + _RESOLVE + ") }\n",
    "ffi.rs": "pub struct Api {\n    pub app_update_config: unsafe extern \"C\" fn(App, Config),\n}\n",
    "reload.rs": '''
        pub fn request() { let _ = PostMessageW(hwnd(), WM_POLTER_RELOAD, w, l); }
        extern "system" fn wndproc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
            if m == WM_POLTER_RELOAD { perform(); }
            LRESULT(0)
        }
        fn perform() {
            let c = unsafe { api().config_loader.load_config() };
            (api().app_update_config)(app, c);
        }
    ''',
}

# #21 as it stood: the reload had its own copy of the sequence, without the
# command line, and nothing resolved `load_recursive_files` at all.
DRIFTED = dict(GOOD)
DRIFTED["main.rs"] = GOOD["main.rs"].replace(
    '"ghostty_config_load_recursive_files"', '"ghostty_config_get"')
DRIFTED["reload.rs"] = GOOD["reload.rs"].replace(
    "let c = unsafe { api().config_loader.load_config() };",
    "let c = (api().config_new)(); (api().config_load_default_files)(c); "
    "(api().config_finalize)(c);")

# A second resolution in another file: compiles, and is a second sequence.
RESOLVED_TWICE = dict(GOOD)
RESOLVED_TWICE["reload.rs"] = GOOD["reload.rs"] + \
    'fn again() { GetProcAddress(lib, s!("ghostty_config_new")); }\n'

TODAY = {
    "main.rs": '''
        extern "C" fn cb_action(_app: App, target: Target, action: Action) -> bool {
            match action.tag {
                ACTION_CONFIG_CHANGE | ACTION_RELOAD_CONFIG => {
                    settings_ui::request_errors();
                    alogf!(origin, "[action] config_change/reload_config");
                    true
                }
                _ => false,
            }
        }
    ''',
    "ffi.rs": "pub struct Api { pub config_new: unsafe extern \"C\" fn() -> Config, }\n",
    "settings_ui.rs": "pub fn request_errors() { let _ = post(); }\n",
}

if analyse(GOOD):
    print("FAIL: the probe rejects a reload path that does everything asked of "
          "it -- it would be edited away within a day.")
    for line in analyse(GOOD):
        print("  " + line)
    sys.exit(1)

for name, case, want in (
        ("DRIFTED", DRIFTED, "does not re-read"),
        ("DRIFTED", DRIFTED, "`ghostty_config_load_recursive_files` is resolved 0 time(s)"),
        ("RESOLVED_TWICE", RESOLVED_TWICE, "`ghostty_config_new` is resolved 2 time(s)")):
    if not any(want in line for line in analyse(case)):
        print(f"FAIL: the probe cannot see {want!r} in {name}.")
        sys.exit(1)

_today = analyse(TODAY)
for want in ("share one arm", "never reaches `app_update_config`", "does not re-read"):
    if not any(want in line for line in _today):
        print(f"FAIL: the probe cannot see {want!r} in the arm as it stands today.")
        sys.exit(1)

# -- the tree ----------------------------------------------------------------

files = {}
if os.path.isdir(ROOT):
    for name in sorted(os.listdir(ROOT)):
        if name.endswith(".rs"):
            with open(os.path.join(ROOT, name), encoding="utf-8") as fh:
                files[name] = fh.read()

# **Subject-set guard.** A gate that read nothing prints its all-clear and
# exits 0, which is indistinguishable from one that read the tree and found
# nothing wrong. Four gates in this directory were in exactly that state.
print(f"read {len(files)} file(s) from windows/host/src")
if "main.rs" not in files or "ffi.rs" not in files:
    print()
    print("FAIL: main.rs or ffi.rs is missing, so there was nothing to check. "
          "Not a pass.")
    sys.exit(1)

problems = analyse(files)
if not problems:
    print("OK: «重载配置» re-reads the config file and hands it to the core.")
    print("NOT CHECKED: that the reload reaches the core at runtime -- a post to "
          "a window nobody pumps reads the same as this. That needs the machine.")
    sys.exit(0)

print()
for line in problems:
    print("  " + line)
print()
print(f"FAIL: {len(problems)} problem(s) on the reload path.")
sys.exit(1)
