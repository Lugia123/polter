# Contributing to Polter

Polter is a fork of [Ghostty](https://github.com/ghostty-org/ghostty). Before
anything else, the split, because it decides where your change should go:

| | |
| --- | --- |
| The terminal itself — rendering, fonts, escape sequences, keybindings, configuration, `libghostty` | **Upstream Ghostty's.** Send it [there](https://github.com/ghostty-org/ghostty); it will reach the people who wrote it, and Polter will get it when upstream is merged in. |
| Supervising — `src/poltergeist/`, the MCP tools, the group chat TUI (`src/cli/chat.zig`), the task panel, the terminal transcript, the plugin host, `plugins/`, `windows/` | **This fork's.** Here. |

If you are not sure, open an issue and ask. Guessing wrong costs you a rebase.

## Getting set up

```sh
zig build                     # Zig 0.16
zig build -Demit-macos-app=false     # skip the app bundle; much faster
zig build test -Dtest-filter=<name>  # the full suite is slow
zig fmt .
```

[`docs/preview-manual.md`](docs/preview-manual.md) is the authority on
building, running and debugging. [`docs/architecture.md`](docs/architecture.md)
is how the pieces fit. [`AGENTS.md`](AGENTS.md) is the short version, and there
are nested `AGENTS.md` files with rules for their own subtrees — read the
nearest one before editing.

On macOS, `zig build test` without `-Demit-xcframework=false` starts seven
`xcodebuild` steps to run the macOS test host. It works, but it takes over the
machine.

## What a good change looks like here

This codebase has an unusual amount of prose in it, and that is deliberate.

**Say why, not just what.** A comment that repeats the code earns nothing. A
comment that says what was tried first and why it did not work stops the next
person from putting it back. Most of the comments here are of the second kind;
please write that kind.

**A claim needs a reading behind it.** "This is faster" wants a number. "This
fixes the race" wants the failure it now survives. If you could not verify
something, write that down — an honest "not tested: this only shows itself
when the machine sleeps" is worth more than silence, and it is a normal thing
for a patch to contain.

**Show that a new test can fail.** A test that has only ever been seen to pass
has not been shown to test anything. The cheapest version: break the thing on
purpose, watch the test go red, put it back. Say in the commit message that you
did.

## Understanding your own code

The one rule inherited from upstream that matters most here, because this
project is itself written with a lot of AI assistance:

**You must be able to explain what your change does, and how it interacts with
the rest of the system, without an AI tool in front of you.** Using AI to write
code is fine — interrogate an agent about the codebase until you understand the
edge cases. Submitting code you cannot explain is not fine, and it is visible
almost immediately in review.

[`AI_POLICY.md`](AI_POLICY.md) has the full policy, inherited from Ghostty and
applying here unchanged. Its first rule is disclosure: say which tool you used
and how much of the work was AI-assisted.

## Commits

Look at `git log` before writing one. The style is a sentence that says what
happened — `A click in the group list chose the group above the one under it` —
followed by prose explaining why the old way was wrong. Not `fix: off-by-one`.

The reason is that a fix removes its own evidence: six months later the code
looks obviously correct, and the only record of why it is written that way is
the message. Reverted reasoning has to be written down or it comes back.

## The one design rule

**Polter measures. It does not judge.**

It reports how long a terminal's screen has been unchanged. It does not decide
that this means the agent is stuck — because a still screen also means
thinking, waiting for a build, or waiting for a person, and answering that
question wrong is worse than not answering it. The call belongs to whoever is
reading.

This is not a preference. It is the reason several things here are shaped the
way they are, and a change that quietly crosses the line — a tool that reports
a conclusion instead of a measurement, a threshold that decides something on
the user's behalf — will be asked to move the judgement back out to the
caller. There is a worked example in the history: `UserPresent measured a
keystroke and reported a person`.

## Pull requests

Open an issue first for anything large; it is cheaper than finding out after
you have written it. Small fixes can go straight to a PR.

Fill in the template. "What was run" is the part people actually read.

## Licence

Polter is MIT, the same as upstream. By contributing you agree your work is
released under it. Keep the existing copyright lines in `LICENSE` as they are
and do not add per-file copyright headers — this tree does not use them.
