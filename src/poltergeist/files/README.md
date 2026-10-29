# `files/` — a group's working directories, and what may be read

Task 2145, plan in `polter-artifacts/2145/PLAN.md` §1. Six files so far:

| file | what it is |
| --- | --- |
| `Workdirs.zig` | which directories a group has, as one row per **real** directory (C1) |
| `Access.zig` | may this path be read, and does it belong to this workdir (C2) |
| `Text.zig` | what a file's bytes are, and whether they may be edited (C2) |
| `Diff.zig` | a line diff (Myers), hunks between two lists of lines (C4) |
| `Merge.zig` | three-way merge (diff3) into a segment table, and the choices put back into a text (C4) |
| `Write.zig` | the one way a file is written: begin, propose, commit (C3) |

Pure, and tested off the hosts: nothing here opens a window or talks to the
app. The app gathers (`App.renderWorkdirs`) and the hosts draw.

## What this slice does not do

**1. There is no fallback to the directory the terminal was started in.**
PLAN §1.1 says the directory of a terminal is the one the shell reports
(OSC 7, `Surface.pwd`), and *failing that* the cwd the terminal was launched
with. Only the first half is here: `App.terminalCwd` returns `Surface.pwd`,
and a terminal whose shell has not reported anything is a terminal with no
directory — it is simply not a row. A terminal in a directory whose shell
never says so (a CLI that clears OSC 7, an app-mode full-screen program) is
therefore missing from the page rather than shown at its launch directory.
Closing that needs the launch cwd kept per terminal, which this slice does
not touch.

**2. Every ask makes one `realpath` per terminal and per worktree, on the
app thread.** `Workdirs.compute` is worked out afresh on every request, which
is the point (a directory that has gone is gone, with nothing kept between
two asks) — but the `realpath` calls are syscalls on the same thread that
draws. A terminal standing in a directory on a network mount, or on a volume
that has been unmounted, can block that thread for as long as the filesystem
takes to answer. The page is asked for when the control room redraws, so the
whole interface waits. Not fixed here; the shape of the fix is a cache with
the terminal's generation as its key, which belongs with `files/Watch.zig`
(C5) rather than ahead of it.

**3. `Access.Request.too_wide` has no default, and nothing fills it in yet.**
`Workdirs.Dir.readable` / `.why` say which directories may only be listed
(`/`, the home directory, anything above it), and `Access.Request.too_wide` is
where a caller passes that on. **The two are not joined up**, because this
slice has no preview and therefore no caller: `too_wide` is a hole a caller
has yet to fill. What is done about that is the only thing that can be done
from here — the field **has no default**, so a caller that forgets it does not
silently get the permissive answer (`false`, "read all of it"); the call does
not compile, and the compiler names the field. That is the same shape as
`Dir.why`, which cannot be left out either. Whether the caller that eventually
exists actually passes `Dir.readable` in is not something these two files can
say, and no test here would notice if it did not.

## What is not settled, and who it is left to

**The check and the read are two moments, and the file can change between
them.** `Access.resolve` answers about a path; the read that follows opens it
again by name. A link swapped in between the two, or a directory replaced by
one pointing elsewhere, is then read as if it had been the path that was
checked. Closing it means the read itself holding something that cannot be
re-pointed — an fd with `O_NOFOLLOW` on the last component, or a walk that
opens each part with it — which belongs to the piece that does the reading,
**M1/W1**, not here. This package decides, and says what it decided; it does
not hand out a handle.

**On Windows a junction, and a link to a UNC path, are followed during
`realpath`.** `std.fs.path.resolve` settles the spelling, and `realpath` is
where the filesystem is asked — so a junction inside a workdir is walked
through, and a link to `\\server\share` reaches the server as part of the same
call (SMB authentication included) before anything here gets to answer. The
refusals still hold — a link out is `outside` — but the call that answers has
already made the trip. What to do about that is not decided.

## Merging and writing (task 2562, C4 and C3)

**Not wired to anything yet.** No MCP tool, no host and no `App` code calls
these; `files_propose` / `files_commit` are `Write.propose` / `Write.commit`
with a token registry in front, which is a later slice.

**A text is cut at `\n` only**, so a trailing newline is a last empty line
and `Diff.join` inverts `Diff.lines` exactly. `Write` takes one trailing
newline off before merging and puts it back from the file's habit.

**Segments**: `same` (includes "both made the identical change"),
`mine_only`, `theirs_only`, `conflict`. Hunks that touch are one place, as in
diff3. More than 5000 segments, or a diff past `Diff.max_edits` (3000 edited
lines) makes the whole file one conflict, `Merged.whole_file`.

**What is not closed.**

1. The version check and the rename are two moments. They are closer than
   they were (size and mtime are looked at once more just before the rename,
   and a change there comes back as a new `Proposal`), but no lock is taken
   here (that is C-locks): an agent that writes inside what is left loses its
   write.
2. A file with mixed LF/CRLF line ends is not editable (`Failure.mixed_eol`);
   a file that *becomes* mixed while it is open cannot be saved either, and
   the answer is the same failure.
3. A file with several hard links is replaced, not edited in place.
4. Only the final newline *state* is kept: an editor that adds a trailing
   newline to a file that had none does not get it. A file whose text is
   deleted entirely becomes empty, not a lone `\n`.
5. `Options.restore_gone` writes with the default permissions and the habits
   of the text editing began on, ignores `choices`, and never overwrites: a
   file that appeared at the path meanwhile comes back as a new `Proposal`.
6. **The directories above the file are not pinned.** `Access` checks the
   path, and `writeAtomic` then opens its directory by that path again. If
   someone replaces a directory *in the middle* of the path with a link out of
   the workdir between the two, the temporary file and the rename land
   outside. (A link in the last component is harmless: the rename replaces
   the link itself, and the next `Access` sees it.) Closing it means taking
   the real path of the opened directory handle and comparing it with what
   `Access` gave; not done here.
7. **The temporary file has a name** (16 hex digits, in the file's own
   directory). A process that dies between making it and the rename leaves it
   behind, and the file watch (C5) will see it.
8. Owner, ACLs and extended attributes (Finder tags, quarantine) are not
   carried over to the new file; the permission bits are.
9. On Windows a target another program holds open makes the rename fail with
   AccessDenied; the answer is `write_failed` and the file is as it was.
10. A merge over a large file can take long and a lot of memory (`Diff`'s
    header has the numbers: ~72 MB, hundreds of millions of comparisons at
    the limit). It must not run on the app thread when it is wired up.
11. A big edit that moves *both* sides far from `base` (or leaves more than
    5000 segments) is one conflict for the whole file; a big edit where only
    one side moved is not (`Merged.whole_file` is set either way).

**Floors.** `2562 C4: both sides making the identical change is not a
conflict` goes red (expected `.same`, found `.conflict`) when that case is
judged a conflict; `2562 C3: the disk changing between propose and commit`
goes red at `TestWroteOverAChangedFile` when `commit` does not look at the
disk again; `2562 C4: a diff the search gives up on` goes red at the
`Kind.mine_only` check when the whole-file case does not look at which side
is `base`; `2562 C3: the link-into-place write refuses a name that is taken`
goes red when `writeAtomic` is
given `.replace` for a restore, and so does `2562 C3: restore, reached after
the file was found gone, does not overwrite one made since` (at
`TestRestoreOverwroteANewFile`), which is the one that checks `restore` itself
chooses `.create_new`.

## The edit lock and `+hook-guard` (C6a): what it does not stop

The guard lets a write through whenever it is unsure; these are the writes it
does not hold back. None is a refusal of something that should pass.

**1. A payload over 16 MB** (a `Write` of a huge file) is not read to the end,
so it is let through.

**2. A path spelled through a link from outside the workdir** (macOS
`/tmp/…` against `/private/tmp/…`) is judged by `Access` on its spelling
first, and can come out "outside" although it names a file of the workdir.

**3. A terminal that is in no group is never held back.** PLAN §1.5 speaks of
the terminals whose directory contains the file; the code asks the groups the
control room shows the terminal in, and a terminal in none has no workdir.

**4. `sub/../x.md` where `sub` is a link** is normalised by its spelling
before the real path is taken (`pathOf` and `Access.resolve` both do). The
operating system would write to the link's target's parent, the guard asks
about `cwd/x.md`: it can refuse a write to a different, locked file's
namesake, or miss one. Rare; closing it means handing Polter the unnormalised
path and letting `realpath` resolve it.

**5. Only `Write`, `Edit`, `MultiEdit` and `NotebookEdit` are asked about**
(`hook_guard.writing_tools`). A file changed through `Bash` is not seen.

**6. Nothing registers the hook yet** (C6b), and nothing takes a lock, so no
write is held back in the app today.
