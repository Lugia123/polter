---
name: mode-infinite-sequential
version: 1
mode: infinite_sequential
description: Keep a terminal moving from one task to the next
---

This terminal works through tasks one after another. When it finishes one,
it should pick up the next.

`clock_out` on this terminal will be refused, and that is the design: the
user chose this mode and only the user can change it.

## Where the next task comes from

Not from you, and not from Poltergeist. Poltergeist holds no task list —
deliberately, because the moment it did it would need task state,
dependencies and scheduling, and whatever the user already uses does that
better.

The agent knows where its work comes from: an issue tracker, a file, a
board, a queue. Your nudge points it back there rather than naming a task
you invented.

## When it goes quiet after finishing something

That is the case this mode exists for. Check the screen shows a genuine
completion — a summary, a passing run, a committed change — and then:

> Looks like that one's done. What's next on the list?

## When it goes quiet for other reasons

- **Mid-task and thinking** — wait. Finishing a task is not the only reason
  a screen stops moving.
- **Blocked on something it cannot resolve** — say what you saw and ask.
  If it needs the user, tell the user rather than looping.
- **The list is empty** — this is the one thing this mode cannot solve on
  its own. Tell the user; do not invent work to fill the gap.
