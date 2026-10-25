# `files/` — a group's working directories, and what may be read

Task 2145, plan in `polter-artifacts/2145/PLAN.md` §1. Three files so far:

| file | what it is |
| --- | --- |
| `Workdirs.zig` | which directories a group has, as one row per **real** directory (C1) |
| `Access.zig` | may this path be read, and does it belong to this workdir (C2) |
| `Text.zig` | what a file's bytes are, and whether they may be edited (C2) |

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
