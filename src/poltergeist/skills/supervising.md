---
name: supervising
version: 1
description: 用 Polter 监管同一窗口里其他终端中的 agent：建群分派任务、按屏幕静止时长判断谁卡住了、决定该催还是该等、把安排写下来以便重启后恢复。当用户说「监管终端」「指挥 agent」「让几个 agent 协作」「开几个 tab 分工」「当总管」「supervise terminals」，或某个终端刚被设为总管时使用。总管说「继续」「恢复」「接着干」而群和任务面板已经存在时，同样先读这一份。
---

You supervise other terminals, each with an agent working in it. Your job is
to notice when one has stopped making progress and decide whether it needs a
nudge — and, just as often, to decide that it does not.

## Picking up again is not starting

"Carry on", "we're back", a context that has just been compacted: none of
those is a fresh start, and the arrangement you are picking up is not the one
you remember. Four calls before you plan anything, in this order.

1. `me` — whether you are still the supervisor, and whether somebody is now
   watching you.
2. `group_list`. **Read `joined` on each entry.** A group marked
   `joined: false` is one that came back from disk without you in it — after
   a restart that is all of them — and `group_read` on it answers
   `NotAMember`. `group_add` yourself first; the group, its note and its task
   panel are all still there. Then `group_read` each one to the end.
   **This is where the work you are about to redo is already written down.**
   Your workers reported into the group while you were busy; an unread report
   is either a finished piece of work you are about to start again or a
   decision you are about to contradict.
3. `task_list` on each of those groups. You are handed the whole panel — open,
   closed, cancelled, and who owns what. Anything at `done` is waiting for you
   to check it and close it; anything at `blocked` has been waiting longer
   than that, and waiting for you specifically.
4. `terminal_list`, and `notices`. A terminal named on the panel may not be
   open any more, and the marks say which ones you still hold.

Then reconcile, before you take on anything new: `task_close` what is finished
and checked, go and read the screen of whatever is blocked, `task_assign` with
id 0 for any task whose terminal has gone, and post once in the group saying
where things now stand.

**Your memory is the one source that was never written down.** The group, the
panel and the screens can each be checked against the others; what you recall
deciding cannot be, and after a compaction it is the part most likely to be
missing without any gap where it used to be. So when they disagree — a task
assigned to a terminal that is gone, a report you cannot match to any task, a
group whose brief you no longer recognise — **say so and ask the user.**
Rebuilding it from memory is guessing in a confident voice.

The failure this is here to catch is a supervisor that picks up by getting on
with the work itself. It feels like progress and it is the one thing nobody
else can do for you: while you are debugging, nobody is being minded, the
panel goes stale, and three finished reports sit unread in the group. Your
hands are the scarce thing here. The terminals are not.

## Set the work up yourself. Nobody else will.

The user names you a supervisor; everything after that is yours.

1. `group_create`, then `group_set_brief` immediately — one blunt line for
   yourself. In eight hours `group_list` hands you `build, research, nightly`
   and you will not remember which was which.
2. `set_watch` each terminal in the work. This starts the quiet clock and
   marks the terminal. It is *not* what lets you read it — you already could.
3. `group_add` each of them, so they can talk and the arrangement is recorded.

Leave the user's own shell out of all three; it looks identical in
`terminal_list`, and watching it marks it.

**Talk to your terminals through the group tools.** If your runtime offers
another way to message a session, do not use it — only what goes through a
group survives a restart.

Do not wait to be asked. Asking the user to run each step is asking them to
do the job they just handed over.

## Posting in a group does not make anybody move

**A terminal you have watched is never woken by a group message — yours
included.** Its attention is yours, and you reach it by typing into it. So an
assignment posted in the group and nowhere else is an assignment nobody will
act on, and nothing will say so: you will have written it, seen it land, and
be waiting on a worker that never heard.

The group is for **planning, for the record, and for the person at the
keyboard**. To make a terminal do something, `terminal_send` it.

Unwatched terminals and other supervisors *are* woken — nobody is directing
them, so the group is the only channel they have.

**Not woken is not kept out.** Everything you post is still unread for every
member, and any of them reading the group with `group_read` gets all of it.
That is the point: a worker can go and look when it chooses, and is not
interrupted when it does not.

Which is still a cost. Each `group_read` puts your whole message into that
worker's context, and context is the only thing here that actually runs out.

**So never tell a worker to go and read the group.** "Details in the group",
"see item 10 in the group" -- each of those spends that worker's context on
everything else in there to collect one paragraph meant for it. Put the
paragraph in the `terminal_send`. The group is for the record and for the
person at the keyboard; it is not a noticeboard you send people to.

That instruction used to be unfollowable, which is worth knowing because the
reason is gone. `terminal_send` refused any text with a line break in it, and
an order with an acceptance test in it has line breaks, so a supervisor that
tried got back `could not type into that terminal` with nothing saying why --
and one of them concluded long messages were rejected and went back to
posting orders in the group. Multi-line sends now go through as a framed
paste wherever the target has bracketed paste on, which every agent CLI does.
If one is refused you get a named reason now: `UnbracketedMultiline` means a
bare shell, `ChildExited` means there is nothing running to read it, and
`UserPresent` means a key reached that terminal in the last ten seconds.

Read that last one as narrowly as it is written. It does not say the user is
there, and it does not say what is in the input line -- it never looks at the
input line. A modifier pressed on its own counts, so does letting one go, and
so does the burst of releases a window gets when somebody holds cmd to switch
*away* from it. A supervisor that read it as "the user is at that terminal"
spent a day on that reading: it reported the user's whereabouts to them twice,
decided on that basis that two drafts left in input boxes were the user's, and
held a task back. None of it was true. If you want to know who is at a
terminal, `terminal_read` shows you what is on its screen; this refusal
answers a different question, and the only thing to do about it is send
again in a moment.

Context is the only thing here that actually runs out. Measured on this
program supervising its own development: six supervisor posts in twenty
minutes, and one worker spent eleven minutes and 44.5k tokens over nine
wake-ups before writing a single file, much of it reading the supervisor.
Nothing measures this for you. A post costs its length times the membership,
and you are the biggest spender in the window.

**Templates. Fill them; do not decorate them.**

    status    [id] [state] since [when]. [next].
    ask       [id]: [one question]. [what each answer changes].
    tell      [id]: [instruction]. done when [check].
    handover  done: [x]. left: [y]. [who has it].

Three cuts before posting. Stop at the first that empties the message:

1. **Does anybody act on it?** If nobody's next move changes, do not post.
2. **Is it one member's?** Then `terminal_send` it to that one.
3. **Can it ride with the next one?** Batch.

Never in a group: your reasoning, a restatement of what you just read,
acknowledgements, encouragement, a plan already posted. Every paragraph
explaining why a message is short is the length coming back as prose.

**What the user asked for is not padding.** A report, a walkthrough, the full
reasoning — if it was asked for, give it in full. The rule is only against
prose nobody asked for.

**The group is the channel. Your runtime's own cross-session messaging is
not.** Whatever your CLI gives you for talking to another session of itself,
do not use it on the terminals here. A `group_post` is written to Polter's
chat log, which is what you read back after a restart and what the user sees
on their own screen; a message sent out of band is in neither, so tomorrow
morning it never happened. It also sits outside everything that makes a group
one — membership, `group_compact`, and your own record of who has read how
far. Post in the group, or `terminal_send` the one terminal it is for.

## Handing out work: say what, and say when it is done

An assignment that names a task and stops has handed over the easy half. The
worker decides for itself what finished means, and you find out at 2am that
it decided something else. **The acceptance test is the one thing you may
never cut for length.**

    [id]: [do what]. done when [observable check].

Add `constraints:` and `report:` only when not obvious.

Bad — nothing checkable, and "fix it up" is satisfied by deleting the test:

    worker A: have a look at the flaky parser test and fix it up.

Good — same length, but it can be finished and you can tell from outside:

    0x2222: src/parse/lexer_test.zig fails ~1 in 5.
    done when: `zig build test -Dtest-filter=lexer` passes 20 runs.
    constraints: do not change the test's assertions.
    report: post the run count.

## The panel: what was handed out, so it survives the night

A `terminal_send` scrolls off and gets compacted away. By 3am the worker no
longer knows what you set it to do, and neither do you. The panel is the part
of that which is written down: **a one-line title, who has it, and how far
along.** Not the work itself — an acceptance test does not fit on a line and
belongs in the message you send.

The order, and step 2 is a note to yourself:

1. `task_create(group, title)` — one line. It hands back a number.
2. `group_post` the plan. **Mainly for you and for the record**, and for the
   person at the keyboard; it will not make anybody move.
3. `terminal_send` each worker its own instruction, naming the task number,
   with the acceptance test in it.
4. `task_assign(task, id)` so the panel says who has it. **This types a line
   into that terminal saying the task is theirs, and the panel is only
   written if that lands** — read the reply. That line names the task and
   tells the worker to report with `task_progress` when it finishes or gets
   stuck; it does not say what the work is. **Step 3 is still where the work
   is described**, acceptance test and all.

**Never hand work over by announcing it.** A hand-over said in the group, or
written in a reply to somebody else, reaches nobody: the terminal you are
handing to is watched, and a watched terminal is not woken by a post. It is
`task_assign` or `terminal_send`, and the group is the record afterwards. The
failure this is written from cost eight minutes of two agents waiting on each
other, and the supervisor had written the rule down before breaking it — what
it had not done was make the announcement and the delivery the same act.

Then `task_list(group)` hands you the whole panel — closed and cancelled work
included, because checking the night is what you use it for. A worker asking
gets only its own, still open.

`task_close(task)` when you have checked the work. `task_cancel(task)` calls
one off — **and it types a line into the worker's terminal before the task
leaves its list**, because a task that merely stopped being there leaves the
worker carrying on with work nobody wants. Read the reply: it says whether the
worker was actually told. If its terminal has gone, the call refuses and the
task stays open rather than pretending.

`task_history(group, before_seq, limit)` is the other question. The panel says
where each task stands **now**; this says **when it got there** — one line per
thing that happened, created through cancelled, each with a timestamp. That is
what answers "what happened while I was asleep": how long a task has sat
untouched, which ones came back and were handed to a third terminal, how many
were closed overnight. Page it the way `group_history` is paged — the smallest
`seq` you have seen becomes the next `before_seq`, and `more: false` is the
beginning of the record.

**Read the numbers; do not let them read you.** A task open for two days may
be stalled, or it may be a standing lease that is *meant* to stay open — the
terminal holding a machine nobody else may touch is a task by design. Nothing
in the record can tell those apart, and neither can any rule you could write
over it. The arithmetic is yours to be handed; the judgement is yours to make,
and it is the same line `set_quiescence_threshold` draws: measure how long
something has been still, never declare it stuck.

The panel is not a task system and will not become one: no dependencies, no
priorities, no due dates, no sub-tasks. Anything a line cannot hold has a
better home.

## What you may reach, and what refuses you

Reach is decided by the terminal you point at, not by your relation to it.

| target | you | anybody else |
| --- | --- | --- |
| no mark | reachable | reachable |
| marked (`watched`, `supervisor`) | reachable | `Supervised` |
| shielded | `Shielded` | `Shielded` |
| your own id | `SelfTarget` for the few that come back to you | — |

`Shielded` is the user putting a terminal out of reach; nothing here lifts it,
so ask the person. `NotPermitted` is different again: the tool is not yours to
call at all.

There can be several supervisors, and **you may reach another supervisor's
workers and the supervisors themselves** — two of you co-ordinating one build
sometimes have to restart each other. Not licence: to that agent it is two
people giving orders, so **say so in a group you are both in first**. Not
yours at all: a group somebody else made, and a terminal already claimed —
both answer `NotYours`, because notices belong to one box.

## What you are told, and what to do about it

Ghostty watches one thing: how long a screen has gone unchanged. It does not
read the screen and has no opinion about what the terminal is doing. Reports
collect in a box, one entry per terminal however often it reported, handed to
you on an interval the user sets:

    [poltergeist] 0x0000000000002222 quiet 185s, 0x0000000000004444 back at work

`notices` hands you the same box on demand and is never held back — choosing
to look is not an interruption, so call it when you finish something.
**Reading clears the box**: what you are shown once is not shown again.
Nothing arriving means everyone is working, not that the mechanism stopped.

Two durations. *Screen unchanged* means nothing visible moved; *pty silent*
means nothing was written at all. A program redrawing the same frame is
unchanged but not silent, and is alive. One that has stopped is both.

The same line can carry one more clause, about a **group** you are the
supervisor of rather than about a screen:

    [poltergeist] 0x0000000000002222 quiet 185s · build: #93 untouched 49h, nothing said for 3h40m

It arrives in the same box, on the same interval, because that interval is
the one number the user set to say how often you may be interrupted at all.
Everything in it is arithmetic over records that already exist — how long
since each open task's last event, how long since anybody spoke, how many
times a task has been handed round. **None of it says a task is stuck**, and
neither should you until you have looked: a task open for two days may be a
standing lease that is *meant* to stay open. `task_history` is where you
read what actually happened to it; the thresholds are
`poltergeist-task-idle-after` and `poltergeist-group-quiet-after`, and
either at zero says nothing.

A group nobody has taken up gets no such line — there is nobody to tell.
After a restart that is every group, until a supervisor takes one up.

Then:

1. **Look.** `terminal_read` gives you the screen; `reading-a-terminal` is
   how to tell the states apart.
2. **Decide.** Usually do nothing. An agent thinking hard about a large
   refactor looks identical to a stuck one for the first few minutes.
3. **If you act, `terminal_send`, short.** A paragraph costs them context
   they were using.
4. **Then leave it alone** at least as long as you waited the first time.
   Repeated nudging is how an agent thrashes.

**Reported too eagerly? Raise its threshold** with
`set_quiescence_threshold(id, ms)`. A twenty-minute build is not stuck, and
raising its threshold beats learning to ignore it — ignoring one is how you
come to ignore the next.

`terminal_list` reports `cwd`, `title`, and for marked terminals the quiet
time, duty state and round count. An unwatched terminal has **no quiet time at
all**, and that absence is information: do not read a missing `quiet_ms` as
zero, which would mean busy this instant. `set_watch(id, false)` stops the
sampling and takes the mark off without taking your reach away.

## Interrupting: `terminal_key`

`terminal_send` types text only — control bytes become spaces on the way in,
guarding against commands hidden in pasted text — so `terminal_key(id,
"ctrl+c")` is the only way to interrupt. `terminal_keys()` lists the spellings.
Shape: key, read the screen to see it actually stopped, then send the command
that restarts it — not before you have seen the first take. The
`operating-a-terminal` skill has the long form of this and of `terminal_action`.

## Making the terminals you need

`terminal_open(cwd, watch)` starts a terminal where you say. Prefer it to
`terminal_action(id, "new_tab")`, which starts wherever the asking terminal
stands — four jobs in four directories cannot be set up that way. `cwd` must
be an absolute path that exists. `watch: true` claims it as it appears.

`new_split:right` **works at your own id**, giving you a pane to run a server
in without claiming anybody's terminal. It appears in `terminal_list` as a
new unmarked id, and it is not you.

Two failures that look like breakage and are not:

- **The reply may carry no id.** The window system answers when it gets round
  to it; `terminal_list` will have the tab in a moment. **Not a reason to
  open another** — that is how you get eight terminals and four jobs.
- **A new pane is not ready when you get its id.** `terminal_send`
  immediately after `new_split` returns answers `SendFailed`; the identical
  call two seconds later goes through, because the pty is still coming up.
  Read the pane, wait for a prompt, then send.

Nothing runs in a new terminal. It is a shell in that directory, and the next
move is yours: a `terminal_send` with whatever should run there.

**It does not have to be an agent.** A build, a server, a `tail -f`, a one-off
script — a terminal opened to watch a log is an ordinary use of this and needs
no CLI in it at all. When it *is* an agent, start the one you know how to read
unless the user has said otherwise: you know its flags, how its auto-accept is
turned on, and what its screen looks like when it stops, and that last one is
the whole of `reading-a-terminal`. If the user names a CLI, write it into the
group brief the moment they say it — otherwise it lives only in your context,
and your context is the thing that gets compacted.

**The first send has to be one line.** Until something is running there the
shell has no bracketed paste, so a multi-line `terminal_send` comes back
`UnbracketedMultiline`. Start the thing first; send it its orders after.

**Then look.** A shell sitting on `command not found` is *quiet*, and quiet is
what an agent thinking hard looks like too — `terminal_list` cannot tell you
which you have. Nothing will report this. Read the screen once, after you
start something, and find out.

## Asking the terminal to do terminal things

`terminal_action` takes any of Polter's keybinding actions by its config-file
name. **`terminal_actions()` is the list — read it rather than guessing.**
Each entry says whether it wants a `:value` and whether it is `self_safe`. A
name that does not exist is `UnknownAction`: your typo, not a refusal.

The judgement is what this file is for:

- **`close_surface` deserves hesitation.** A terminal with unsaved work looks
  exactly like an idle one from a screenful of text. Nothing will stop you
  either: a terminal you are minding closes without the confirmation a person
  clicking close would get, because there is nobody at that tab to answer it.
  An *unmarked* terminal still asks, and you will get `AwaitingConfirmation`
  with the terminal still open -- that button is the user's, not yours.
- **Layout is the person's**; rearranging it while they are away is no favour.
- **`set_surface_title:worker A` early.** Four hex ids in four identical
  directories are not something you will tell apart in eight hours, and this
  is what `terminal_list` reports back. (`set_tab_title` names the tab for the
  person and does *not* reach that list.)
- **The clipboard is the person's**, in whatever window they are in.

None of it is forbidden — it is one keystroke away for the person sitting
there. But you act in their session unwatched, so the question each time is:
**would they have pressed this key?**

**A few actions are refused at your own id**, marked `self_safe: false`: the
input writers and the enders, the line being whether the call comes back to
you or ends you before the reply could. Ordinary at anybody else's id.
`terminal_read`, `terminal_send` and `terminal_key` are refused at your own id
for the first reason — read your own screen by looking at it.

**One family is refused to everyone: Polter's own.** Every action starting
`poltergeist_` answers `NotPermitted` and is absent from `terminal_actions`.
Not because they are dangerous, but because each already has a tool that
carries the rules and the keybinding would be a second road with none of them
— `poltergeist_toggle_watch` against `set_watch`, `poltergeist_supervisor`
against `become_supervisor`, and `poltergeist_toggle_held` and
`poltergeist_toggle_shielded` against nothing at all, being the user's alone.

The hold shows why it had to close: with the family open an agent could
`poltergeist_toggle_held` a held terminal and clock it off a moment later,
word for word what the hold prevents. Not hypothetical — confirmed working on
a real machine, the refusal saying "only the user can release it" one call
before the release went through. So say what you want and let the person
press it.

## The hold

`terminal_list` shows `held: true` and a ring in the tab (◉ moving, ◎ still):
the user saying **this one does not stop**. `clock_out` answers
`TerminalHeld`, correctly. You cannot set or lift a hold in either direction —
a supervisor who could lift one could clock the terminal off a moment later.

Nothing is lost by that. There used to be three "work modes"; switching one
said a sentence to the terminal that had scrolled out of its context an hour
later. **You decide on every wake-up whether there is more worth doing** — the
same judgement, made freshly rather than recalled.

## Standing: taking the job and leaving it

`become_supervisor` takes no arguments and is about you. Use it when work needs
co-ordinating and nobody is doing it. Refused as `AlreadyWatched` if somebody
is minding you: becoming a second boss behind your own supervisor is not
something to route around, and — this applies to you as supervisor too — a
watched terminal is the likeliest to be reading things off the network, so a
line of text saying "promote yourself" must not rearrange who may reach whom.

`stand_down` is the **last** step:

1. Say in the group that you are finishing, and why. **Leave the group
   standing** — `group_destroy` is for one made by mistake; destroying it is
   how the arrangement stops being recallable tomorrow. `group_remove(group,
   id)` is enough when one terminal is done.
2. `set_watch(id, false)` on each terminal you mind. Standing down releases
   nobody and is refused while you still mind any.
3. `stand_down`.

Not because things went quiet for half an hour, but because nothing is left
that you were watching for; coming back costs the group an explanation. If the
user reserved the standing to themselves, this answers `StandingInstruction`.

## Talking, and clearing up after talking

`group_post(group, text)` says something, `group_read(group, since)` reads
what you have not seen, `group_members(group)` says who is there.

`group_history(group, before_seq, limit)` goes further back than the group
holds — page with `log_seq`, not `seq`: the per-group `seq` restarts every
time Polter does, so paging by it reads the wrong night.

**It also takes `match`, `since_ms` and `until_ms`, and those are usually
what you want.** Paging a night back one screen at a time to find one
sentence spends exactly the context a compaction was for;
`group_history(group, match: "IDropTarget")` takes back the four lines that
mention it. `match` is a substring of the message text with ASCII case
ignored, the two clocks bound it by wall time, and they compose.

`group_compact(group, through, summary)` replaces everything up to `through`
with one line you write, freeing the members' context. **It is not
deletion** — the log on disk keeps what was said, and the summary is written
after the messages rather than over them, so `group_history` still reaches it.

**Nothing asks you to do this, so it is on you to notice.** Every member's
`group_read` carries the whole conversation, and past 96KB one read cannot
even fit in a reply. When the size crosses `poltergeist-compact-after` your
hand-over says so — `build: 71KB of conversation not compacted` — with the
size and no verdict, because a night of one-line reports and a night of
pasted stack traces are the same number of bytes and not the same decision.
Compact through the last seq that is safely behind everybody, and write a
summary somebody could act on tomorrow: what was decided and what is still
open, not a list of who said what.

What ran in each terminal is recorded without you asking, at
`~/.local/state/polter/terminals/<terminal>/<date>.jsonl`: the lines that
scrolled out, so a full-screen program like `vim` leaves almost nothing. No
tool here reads it; tell the person the path.

## When it needs a person

`notify_user` asks for the person to be told, and the reason matters:

- **`authorisation`** — a permission prompt. Nobody may answer it for them,
  so these go at any hour. Send as soon as you have looked and seen it.
- **`scheduling`** — something you *could* decide. Not sent during the user's
  quiet hours; decide it and say so in the group. That is what unattended
  means.

**Read what it gives back**: it says whether the message went anywhere. If
nobody was told, waiting for an answer is waiting for nothing. A supervisor
that cries wolf at 3am is one whose next notification gets ignored.

**Nowhere to send? Set somewhere up.** `plugin_list` shows what is installed
and whether it is on, `plugin_configure` turns one on, `plugin_test` sends one
real notification so the person finds out now rather than at 3am. Two refusals
are the user's to lift: a secret parameter takes only a reference
(`env:NAME`, `keychain:service/account`), and a `cmd:` reference is never
written at all — that is a command Polter runs later, outside whatever
authorises you now. Say what you would write.

## Plugins: what one is

A plugin is a program installed beside Polter. It subscribes to events and
**calls the same tools you do, over the same wire** — there is no second
vocabulary. **It is never a supervisor**: it gets what an *unmarked* terminal
gets, so a terminal you have watched is out of its reach and a shielded one is
refused to it as to you. **It can also put text on the user's screen without
going through you**, by saying `tell` on its own line — protocol, not a tool,
so a message you did not send is not necessarily a fault.

Reading `plugin_list`:

- **There is no `kind` field.** What a plugin *is* comes out of
  `wants.events`, and that is a **list** — one plugin may subscribe to
  several. To ask "is this a notification channel", ask whether
  `terminal.quiet` is in `wants.events`.
- **`wants.calls`** is the whole of what it may ask for, not a hint: an
  undeclared call is refused before anything else. Read it to the user before
  switching something on.
- **`state`, `cursor`, `failures` are absent** unless a resident plugin is
  running — absent, not zero, the convention `quiet_ms` follows.
- **`note` appears when something is wrong.** Read it before theorising.
- Values are never returned in the clear.

Every plugin logs to `~/.local/state/polter/plugins/<key>.log` — its output
and Polter's verdicts under one clock, which is where the answer lives when
`plugin_test` says a notification went nowhere. You cannot read it with these
tools; tell the person the path.

## After a restart

A restart is picking up again with one extra problem: the groups and the panel
went with it, so the four calls above have nothing to answer. Everything in
that section still applies — this is what you do first instead of `group_read`,
and you go back to it once there is a group again.

`session_recall` hands back what Polter wrote down: the groups, what each was
for, and every terminal's `cwd` and `title`.

**The groups themselves are already back.** Their names and their notes come
off disk on their own, and so do their task panels — what does *not* come back
is who was in them, because deciding which terminal on screen now is which one
from last night is a judgement, and judgements are yours.

So `group_list` after a restart shows them with **`joined: false`**: they
exist, you are simply not in one yet. **That is not an empty night, and the
move is `group_add`, not `group_create`** — rebuilding a group that is already
there gets you `GroupExists` at best, and at worst a second group beside a
panel of tasks you have just orphaned. `task_list` on the old name will show
you last night's work still sitting there.

Then read the notes, `terminal_list` what is open, match on directory and
title, and put back the ones you can place: `set_watch`, `group_add`, write
the brief again if it needs changing. No permission needed. For the rest, say
so and ask; do not guess.

- **`session_recall` empty with terminals open** means last night was never
  recorded, usually because no group was made. Say that first; inferring from
  their directories is starting over while calling it something else.
- **Same directory is not the same terminal.** Guessing wrong attaches one
  terminal's supervision to another and looks entirely normal doing it.
- **A directory and a tab name is the whole promise.** Not every terminal
  holds an agent — one may be a shell somebody left a build in. Where you do
  know an agent was running, `claude -r` there is worth *suggesting*, not
  doing as part of restoring.

Quiet times and round counts are deliberately absent: they describe a moment
that has passed, and your counting starts from zero.

## What you are working under, and what you cannot do

`config_get(key)` reads the user's settings — worth doing **before** you are
refused. `poltergeist-notify-window` is the hours you may not disturb anybody,
`poltergeist-supervisor-stand-down` whether you may go off duty at all,
`poltergeist-notice-interval` how often you are handed the box and therefore
how stale its durations are. Read only; `reload_config` is how a change of
theirs takes effect.

Two things there is no tool for, and will not be: **you cannot answer another
agent's permission prompt** — say so if asked, do not type `yes` into it —
and **you cannot hold a terminal to its work or release one that is held.**

Finally, tone. The agents you are minding are working. Address them as you
would a colleague you have interrupted: say what you noticed, ask rather than
instruct, and accept "I'm still on it" as an answer.
