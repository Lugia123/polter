#!/bin/sh
# Check a tag before the release goes out.
#
# This is where the tag/version agreement lives, and the reason it is here
# rather than in `build.zig` is the whole point of the file. As a build-time
# check it fired for exactly the wrong person: the artefacts of a release are
# built before the tag exists, so whoever tags never saw it, while whoever
# cloned the repository and checked the tag out got a panic about a tag they
# did not choose and a version they do not set. The only thing that error
# could ask of them was to give up.
#
# "The tag names the version" is a precondition of an action. It belongs
# where the action happens, run by the person who can still change the answer.
#
#   usage: tools/release-check.sh <tag> <branch>
#     e.g. tools/release-check.sh v0.4.452 feature/v0.4
#
# Exits non-zero on the first cell that fails, and says which.

set -eu

# ---------------------------------------------------------------------------
# ⚠️ The range of this check, which is not a footnote.
#
# **The expected version is computed from git, never read back out of an
# artefact.** Release artefacts are built from an isolated worktree
# (`git worktree add --detach`), and that is deliberate -- it is what keeps
# one build from picking up another's half-finished files. But a detached
# worktree has no branch name: `git rev-parse --abbrev-ref HEAD` answers
# literally `HEAD` there, measured, not assumed. So every artefact we have
# ever shipped carries `1.3.2-HEAD-+<commit>` in its version string, and
# `PolterVersion` computes `0.1.<n>` in that state rather than `0.4.<n>`,
# because its branch lookup returns nothing and it falls back.
#
# **An assertion about the branch segment of an artefact's version would
# therefore go red on a perfectly ordinary release.** That is not a caveat to
# be worked around; it is the boundary of what an artefact can be asked. The
# commit is in there and is worth comparing. The branch is not.
# ---------------------------------------------------------------------------

# Run with no arguments this explains itself, because nothing else will.
#
# The step-by-step for cutting a release lives outside the repository -- it is
# in a `.claude/` directory that `.gitignore` excludes, deliberately -- so a
# reader who finds this file has only this file. Printing a usage line and
# exiting would tell them how to type it and nothing about when to.
if [ $# -eq 0 ]; then
    cat <<'WHAT'
tools/release-check.sh <tag> <branch>     e.g.  v0.4.452 feature/v0.4

WHEN
  Before a release goes out, by the person cutting it, while they are still
  on the branch and can still change the answer. Nothing runs it for you.

WHY IT IS NOT IN THE BUILD
  This used to be a check inside `build.zig`, and it fired for the wrong
  person. A release's artefacts are built before the tag exists, so whoever
  tags never saw it; whoever cloned the repository and checked the tag out
  got a panic about a tag they did not choose and a version they do not set,
  and the only thing it could ask of them was to give up. "The tag names the
  version" is a precondition of an action, not an invariant of a build.

WHAT IT CHECKS
  name        the tag equals v<major>.<minor>.<commits since the fork>
  provenance  the tagged commit is on the branch being released
  buildable   a fresh clone, checked out at the tag (detached, which is what
              `git checkout <tag>` does to anyone), builds

WHAT IT DOES NOT CHECK
  **It does not say the version number is right.** It says the tag name and
  the derived value agree -- if the branch is misnamed, or the fork point in
  `PolterVersion.zig` is wrong, both sides move together and this stays
  green. It is an agreement check, not a correctness one.

  It says nothing about the artefacts: not that they were built from this
  commit, not that they are signed, not that they were uploaded. It never
  reads a version back out of a binary, and that is deliberate -- see the
  note above about detached worktrees.

  It does not tag anything, push anything, or change any file.
WHAT
    exit 64
fi

if [ $# -ne 2 ]; then
    echo "usage: $0 <tag> <branch>   (run with no arguments for the long form)" >&2
    exit 64
fi
tag=$1
branch=$2

repo=$(git rev-parse --show-toplevel)
cd "$repo"

# One source for the fork point: read it out of the file that defines it
# rather than writing the hash down a second time. Two copies of a constant
# is how the two halves come apart without anybody editing either.
fork=$(sed -n 's/^const fork_point = "\([0-9a-f]*\)";$/\1/p' src/build/PolterVersion.zig)
if [ -z "$fork" ]; then
    echo "FAIL: could not read fork_point out of src/build/PolterVersion.zig" >&2
    exit 1
fi

commit=$(git rev-parse --verify "${tag}^{commit}" 2>/dev/null) || {
    echo "FAIL: no such tag: $tag" >&2
    exit 1
}

fail() { echo "FAIL[$1]: $2" >&2; exit 1; }
pass() { echo "ok[$1]: $2"; }

# --- 1. name ---------------------------------------------------------------
#
# `feature/vX.Y` gives major.minor and the commits since the fork give the
# patch, the same rule `PolterVersion.zig` uses -- and computed here from the
# branch the releaser names, because the tagged commit itself cannot say which
# branch it was made on.
case $branch in
    feature/v*.*) ;;
    *) fail name "branch $branch is not of the form feature/vX.Y, so it names no version" ;;
esac
mm=${branch#feature/v}
count=$(git rev-list --count "${fork}..${commit}")
expected="v${mm}.${count}"
[ "$tag" = "$expected" ] || fail name "tag $tag, but $branch at $(git rev-parse --short "$commit") is $expected"
pass name "$tag matches $branch at $(git rev-parse --short "$commit")"

# --- 2. provenance ---------------------------------------------------------
#
# A tag on a commit that is not on the branch being released is a tag on
# something nobody is shipping.
git merge-base --is-ancestor "$commit" "$branch" 2>/dev/null ||
    fail provenance "$tag points at $(git rev-parse --short "$commit"), which is not on $branch"
pass provenance "$(git rev-parse --short "$commit") is on $branch"

# --- 3. buildable ----------------------------------------------------------
#
# **In the state the downloader is actually in.** Checking out a tag detaches
# HEAD, and that is the state the old build-time check got wrong: verifying on
# a branch with the tag on HEAD passes while the same commit checked out by
# tag does not. So this clones and checks the tag out, rather than building
# where the releaser happens to be standing.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
git clone --quiet --no-local --shared "$repo" "$work/src" 2>/dev/null ||
    fail buildable "could not clone the repository"
git -C "$work/src" checkout --quiet --detach "$tag" 2>/dev/null ||
    fail buildable "could not check out $tag in a fresh clone"
( cd "$work/src" && zig build -Demit-macos-app=false -Demit-xcframework=false ) >"$work/build.log" 2>&1 ||
    fail buildable "$tag does not build from a fresh detached checkout; see below
$(tail -n 20 "$work/build.log")"
pass buildable "$tag builds from a fresh detached checkout"

echo "all three cells pass for $tag"
