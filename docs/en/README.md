# Developer documentation (English)

> Last updated against git commit: `f81dcadc8`
> (`f81dcadc82ea2afdcf2dc92929037701122f05b5`, 2026-08-14)
> How to check: `git log -1 --format='%H %h %ad %s'`

These documents are for **people working in this repository**, coding agents
included. They are not an end-user manual; the user-facing configuration
reference lives on the upstream Ghostty site.

**The code is always the authority.** Documentation lags behind it and can
point at the wrong line number after a refactor. Where a document and the
source disagree, the source wins — and while you are there, update the commit
stamp at the top of the document.

## Most of `docs/` is in Chinese

38 of the 39 files under `docs/` were written in Chinese — the exception is
[`../tools.md`](../tools.md), which was written in English and has a Chinese
translation beside it as `tools_CN.md`. The gap matters for exactly two files,
because [`CONTRIBUTING.md`](../../CONTRIBUTING.md) names those two as the
authority on how to build and how the pieces fit together. Both are translated
here:

| English                                  | Chinese original                               | What it is                                                                                       |
| ---------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| [`preview-manual.md`](preview-manual.md) | [`../preview-manual.md`](../preview-manual.md) | How to build, run, iterate, read the logs and debug. **The single authority on build commands.** |
| [`architecture.md`](architecture.md)     | [`../architecture.md`](../architecture.md)     | The module map, the startup chain, the per-surface thread model and the mailboxes.               |
| [`GLOSSARY.md`](GLOSSARY.md)             | no counterpart                                 | The English spelling of every term both halves of the tree have to agree on, with its source.    |

The Chinese file is the original in each case. If the two disagree, the Chinese
one is right and the translation is stale — say so in an issue, or fix it.

## Everything else is Chinese only

These have no English version yet — with the one exception noted above,
[`../tools.md`](../tools.md), which is **written for users rather than
developers**: the complete reference for Polter's forty MCP tools, what each
one does, what it refuses, and which are the supervisor's alone. It is already
in English and needs no translation.

Links to the Chinese files from the translated documents point at them
deliberately, so that nothing dead-ends; they are listed here so a reader knows
what they are about to open.

- [`../terminal-core.md`](../terminal-core.md) — `src/terminal`: VT parsing,
  the `Screen`/`PageList`/`Page` storage, OSC/DCS/APC and the kitty protocols,
  and the libghostty-vt C API.
- [`../rendering-and-font.md`](../rendering-and-font.md) — the Metal/OpenGL/WebGL
  backends in `src/renderer` and their shaders; font discovery, faces, shapers
  and the atlas in `src/font`.
- [`../platform-and-config.md`](../platform-and-config.md) — the `src/apprt`
  application runtime abstraction, the Swift app under `macos/`, the
  `src/config` configuration system, and `src/input` keybindings and key
  encoding.
- [`../poltergeist/README.md`](../poltergeist/README.md) — the design of the
  Poltergeist capability layer, which is what lets one supervisor terminal mind
  several agent terminals. The other chapters in that directory answer to this
  one, and [`../poltergeist/gaps.md`](../poltergeist/gaps.md) is what is still
  missing.
- [`../windows/design.md`](../windows/design.md),
  [`../windows/development.md`](../windows/development.md),
  [`../windows/status.md`](../windows/status.md) — the Windows port: why it is
  shaped this way, how to work on it, and how far it has got.
- [`../readme-reviews/README.md`](../readme-reviews/README.md) — the record of
  stranger-reads-the-README reviews, including the feedback that was **not**
  acted on and why.
- [`../_conventions.md`](../_conventions.md) — the writing rules every file
  under `docs/` follows: citation format, the anti-hallucination rule, and how
  to mark something unverified. Read it before adding or changing anything in
  `docs/`; [`GLOSSARY.md`](GLOSSARY.md) is its English-side companion.

The index to all of it, also in Chinese, is [`../README.md`](../README.md).

## Where to start

- First time here, want to get it running → [`preview-manual.md`](preview-manual.md)
- Want to understand how a keypress becomes a character on screen →
  [`architecture.md`](architecture.md)
- Working on escape-sequence parsing, screen data structures or libghostty-vt →
  [`../terminal-core.md`](../terminal-core.md) (Chinese)
- Working on drawing, shaders, fonts or glyphs →
  [`../rendering-and-font.md`](../rendering-and-font.md) (Chinese)
- Working on the macOS or GTK side, configuration or keybindings →
  [`../platform-and-config.md`](../platform-and-config.md) (Chinese)
- Working on Poltergeist, the multi-agent supervision layer →
  [`../poltergeist/README.md`](../poltergeist/README.md) (Chinese)

## Relationship to the rest of the repository

- The root [`AGENTS.md`](../../AGENTS.md) (`CLAUDE.md` is a symlink to it) is
  the entry index for agents. It carries only the shortest path and points at
  `docs/` for everything else. It is in English.
- [`CONTRIBUTING.md`](../../CONTRIBUTING.md) says which half of this tree is
  this fork's and which half is upstream Ghostty's, and states the one design
  rule. English.
- Subdirectories carry their own `AGENTS.md`, whose rules apply to that subtree:
  [`macos/AGENTS.md`](../../macos/AGENTS.md),
  [`example/AGENTS.md`](../../example/AGENTS.md),
  [`src/benchmark/AGENTS.md`](../../src/benchmark/AGENTS.md),
  [`src/inspector/AGENTS.md`](../../src/inspector/AGENTS.md),
  [`src/terminal/c/AGENTS.md`](../../src/terminal/c/AGENTS.md),
  [`src/terminal/snapshot/AGENTS.md`](../../src/terminal/snapshot/AGENTS.md),
  [`src/terminal/compress/AGENTS.md`](../../src/terminal/compress/AGENTS.md),
  [`src/terminal/apc/glyph/AGENTS.md`](../../src/terminal/apc/glyph/AGENTS.md),
  [`test/fuzz-libghostty/AGENTS.md`](../../test/fuzz-libghostty/AGENTS.md).
  Read the nearest one before editing.
