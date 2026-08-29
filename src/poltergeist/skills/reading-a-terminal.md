---
name: reading-a-terminal
version: 1
description: 从终端屏幕上的内容判断里面的 agent 处于什么状态——在想、卡在提示上、等授权、已经做完、还是真的死了。当你作为总管收到「某终端已静止」的报告、准备决定要不要打扰它时使用，配合 terminal_read 一起用。
---

This is the skill most likely to need editing. It describes what particular
agent CLIs look like, and they change. If a judgement here stops matching
what you see, fix this file rather than working around it.

You get here after `terminal_read`. You are looking at one screen and
deciding which of a handful of situations it is.

Most of this is judgement and applies whoever you are. The exception is
`clock_out` below: it belongs to a supervisor, and an unmarked terminal
calling it gets `NotPermitted`. Everything else here you can act on.

## Thinking

The agent is working and simply has not printed anything conclusive yet.
Signs: a spinner or elapsed-time counter; a token or cost counter that
moves; a tool call that has started but not finished; text that ends
mid-thought.

**Do nothing.** The `pty silent` figure helps here: if it is far smaller
than `screen unchanged`, something is still being drawn, which means the
process is alive. Long thinking is normal on large tasks.

## Waiting for the user

The agent has asked something and stopped. Signs: a question ending in a
prompt; a permission or approval dialog; a numbered list of choices; an
input box with a cursor and nothing else happening.

**Do not answer it.** If it is a permission prompt, that is the user's to
answer. If it is an ordinary question the agent asked its user, you may
answer it *if you know the answer from the task at hand* — but if you are
guessing, leave it. A wrong answer here is worse than a delay.

## Finished

The agent believes it is done. Signs: a summary; a final diff or test
result; a return to an idle prompt with no pending work.

**This is where you decide whether there is more worth doing.** Nothing
decides it for you — you are the one who knows what the work was. If there
is, say what is next; if there is not, `clock_out` stops it being reported
again.

One case is decided already: a terminal the user is holding to its work
(`held: true`, a ring in its tab) cannot be clocked off, and `clock_out`
comes back as `TerminalHeld`. That terminal being finished means it needs
the next thing, not the end of the day.

## Stuck or failed

Something went wrong and nothing is retrying. Signs: an error with no
following activity; a stack trace; a rate-limit or API error message; a
connection failure; a prompt that reappeared without the work being done.

**A nudge is reasonable here**, and it should name what you saw: "I see an
API error from twelve minutes ago and nothing since — can you retry?"
carries more than "continue".

## Idle for no clear reason

The screen holds ordinary output, nothing is animating, and there is no
question and no error. This is the genuinely ambiguous case.

Prefer waiting the first time, and nudging the second. If you nudge, ask
rather than instruct: "still working on this?" leaves room for an answer
you did not expect.

## The terminal is not running an agent at all

A shell prompt, a pager, an editor. Somebody may simply have this terminal
open for their own use.

**Leave it entirely.** Consider telling the user it is being watched by
mistake, rather than typing into a terminal a person is sitting at.
