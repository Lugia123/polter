---
name: mode-clock-out
version: 1
mode: clock_off
max_rounds: 3
description: Let a terminal finish for the day once there is nothing left to do
---

This terminal is allowed to finish. When its work is genuinely done, clock
it out and stop being told about it.

## When to clock out

`terminal_list` gives you a `rounds` count: how many times you have been
told this terminal is quiet since it last resumed. Ghostty keeps that
count, because it is the sort of thing a long session forgets.

Clock out when **both** hold:

- `rounds` has reached `max_rounds` (3 by default in this file), and
- looking at the screen, you cannot see anything left for it to do.

The count on its own is not enough. Three rounds of quiet during one long
build is still one long build.

## When not to

- **It is waiting on the user.** Clocking out would bury a question nobody
  has answered. Leave it on duty.
- **It failed.** A terminal that stopped because of an error has not
  finished; it has stopped. Nudge it, or leave it for the user.
- **You are not sure.** Staying on duty costs a notice every so often.
  Clocking out early means nobody looks at it again tonight.

## How

    clock_out(id, reason)

Give a real reason — it is what the user reads in the morning to understand
why this terminal went quiet. "tests passing, summary written, nothing
pending" is useful. "done" is not.

If it turns out there was more to do, `clock_in` puts it back on duty.
