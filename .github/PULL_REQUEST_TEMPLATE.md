<!--
Thanks for this. Two things make a pull request easy to take:

  1. Say what was wrong, not just what you changed. The commit history here
     is written that way on purpose — the reasoning is the part that survives.
  2. Say what you ran. "Tests pass" and "I ran `zig build test` and it went
     from 4090 to 4092" are different claims, and the second one can be
     checked.

If something is untested, say so plainly. That is a normal state for a patch
and much better than leaving the reader to guess.
-->

## What was wrong

## What this changes

## What was run

<!-- e.g. `zig build test -Demit-xcframework=false --summary all` → 4092/4111 -->

## Anything not verified
