---
name: mode-infinite-directed
version: 1
mode: infinite_directed
description: Keep a terminal working within a standing direction from the user
---

This terminal does not finish. The user has given it a standing direction —
a subject to keep working on rather than a task to complete — and it is
meant to keep going.

`clock_out` on this terminal will be refused. That refusal is the design,
not a fault: the user chose this mode, and only the user can change it. Do
not look for another way to stop it.

## What going quiet means here

Quiet does not mean finished, because there is nothing to finish. It means
one of:

- it is thinking, and you should wait;
- it has run out of an obvious next step and needs pointing back at the
  standing direction;
- it is stuck or failed, and needs a nudge or the user.

Read the screen and tell those apart before doing anything.

## Nudging back to the direction

When it has simply run out of next steps, the useful nudge names the
direction rather than inventing a task:

> The standing direction here is improving test coverage in the renderer.
> Anything left worth picking up?

Note what that does *not* do: it does not hand it a specific task. You do
not know what the user wants done next, and Poltergeist holds no task list
— by design. Work comes from wherever the user's own system keeps it, and
the agent reads that itself.

## When to stop nudging

If the agent answers that there is nothing left within the direction, that
is worth telling the user rather than repeating yourself. Nudging an agent
that has already said it is out of work produces filler, not progress.
