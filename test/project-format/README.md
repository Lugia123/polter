# The project file, as all three implementations must write it

A project file is read and written in three places that no compiler sees
together:

| | |
| --- | --- |
| Zig | `src/Project.zig` |
| Swift (macOS) | `macos/Sources/Features/Projects/ProjectDocument.swift` |
| Rust (Windows) | `windows/projectfile/src/lib.rs` |

The format itself is written down once, in the module comment of
`src/Project.zig`. The files here are what holds the three to it: **they
have to write the same bytes**, not merely files the others can read.

## What is here

`index.txt` names every file, one `kind<TAB>stem` per line:

- `same` -- `<stem>.json` is a format 3 file, the format that is written.
  Read and written back, it is the same bytes.
- `from` -- `<stem>.in.json` is something else that has to be read: a format
  1 or 2 file, or a file a read puts right. Read and written, it is the bytes of
  `<stem>.json`.
- `refused` -- `<stem>.in.json` is from a later format and must not be read.

## Who makes them

**`src/Project.zig` makes every `<stem>.json`, and nothing else does.** Each
is what its writer gives for a value spelled out in that file's tests, and
its reader is checked against the same value. So a file here is not one that
happened to survive a round trip: a round trip is green for a writer and a
reader that agree on a mistake.

The Swift and Rust tests only read. Each takes every row of `index.txt`,
reads the file, writes it, and compares bytes. Neither can regenerate
anything.

The `.in.json` files are written by hand, since no build writes them.

## Changing the format

**Once a build that writes format 2 has been released, a new kind of node --
or anything else an older reader would stumble on rather than skip -- means
a new format number.** `stack` and `by_supervisor` were both added to format
2 without one, which was sound only because no release had format 2 in it
(measured when `stack` went in: no tag held the commit that brought format
2, and the newest release read format 1 only, which a format 2 file already
turns away). A released build that meets a kind it does not know says
"damaged", which is the wrong word for "newer than me"; the reader's
too-new refusal exists to say the right one, and can only say it when the
number went up. Before adding to the format, run
`git tag --contains <the commit that introduced the current format>`: an
empty answer is what makes "no new number" allowed.

1. Change the values in `src/Project.zig` (`Shared.all`), and the module
   comment if a rule changed.
2. Create an empty file `test/project-format/REGENERATE` and run
   `zig build test -Dtest-filter="test/project-format"`. It rewrites every
   `<stem>.json` and `index.txt`, then **fails** so the run is not taken for
   a pass.
3. Delete `REGENERATE`, run it again, and read the diff of this directory.
4. The Swift test (`tools/mac-logic-tests`) and the Rust one
   (`cargo test -p polter-projectfile`, from `windows/`) are now red until
   they write the new bytes.
