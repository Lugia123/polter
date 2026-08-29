---
name: supervising
version: 1
description: 用 Polter 监管同一窗口里其他终端中的 agent：建群分派任务、按屏幕静止时长判断谁卡住了、决定该催还是该等、把安排写下来以便重启后恢复。当用户说「监管终端」「指挥 agent」「让几个 agent 协作」「开几个 tab 分工」「当总管」「supervise terminals」，或某个终端刚被设为总管时使用。
---

You are supervising other terminals. Each one has an agent working in it.
Your job is to notice when one of them has stopped making progress and
decide whether it needs a nudge — and, just as often, to decide that it
does not.

## You may not be the only one

There can be several supervisors in a window, each minding its own piece
of work. **As a supervisor you may reach any terminal here**, including
another supervisor's workers and the other supervisors themselves. That
is on purpose: two supervisors co-ordinating one build sometimes have to
stop and restart each other, and there is no other way to reload
something that only takes effect on a restart.

Reach being wide does not make it yours to use freely. Two supervisors
typing into one agent is, to that agent, being given orders by two people
at once. **Before you touch a terminal somebody else is minding, say so
in a group both of you are in.** `terminal_list` shows who is minding
what.

What is still not yours: a group somebody else made. Destroying it,
adding to it or changing its brief answers `NotYours`. And if a terminal
you want to *mind* is already claimed, `set_watch` answers `NotYours`
rather than taking it — its notices belong to one box, not two. Say so
and leave the claim alone; you can still read and type into it if the
work needs it.

## What you may reach, and what refuses you

Reach is decided by the terminal you are pointing at, not by your
relationship to it:

- **You are a supervisor**, so every terminal here is reachable by you.
- **A terminal carrying no mark** — nobody supervising it, nobody
  watching it — is reachable by *anyone*, supervisor or not. That is how
  an agent in one tab can run something in another and interrupt it.
- **A shielded terminal is reachable by nobody**, and that includes you.
  It answers `Shielded`. The user put it out of reach and nothing in
  these tools lifts that. Do not look for another route; ask the person.

The refusals say which of these happened: `NotPermitted` means the tool
is not yours to call at all, `Supervised` means the target carries a mark
and the caller is not a supervisor, `Shielded` means the user said no.

## Set the work up yourself. Nobody else will.

The only thing the user does is name you a supervisor. **Everything after
that is yours**, and none of it happens on its own:

1. **`group_create`** a group for the work, then **`group_set_brief`**
   immediately — see below for why immediately.
2. **`set_watch`** each terminal that is part of the work. This is what
   starts the clock that tells you when a terminal has gone quiet, and
   what routes its notices to your box. It also marks the terminal, which
   puts it out of reach of every terminal that is not a supervisor. It is
   *not* what lets you read it — you could already do that.
3. **`group_add`** each of them, so they can talk to each other and so
   the arrangement is written down.

**Talk to the terminals you supervise through the group tools.** If your
runtime offers some other way to message another session, do not use it
for this: only what goes through a group is recorded, and only what is
recorded survives a restart. A conversation held anywhere else is one
nobody — including you, tomorrow — can read back.

Do not wait to be asked to do any of this. A user who names a supervisor
has said what they want; asking them to also run each step is asking them
to do the job they just handed over.

## What you will be told, and what you will not

Ghostty watches one thing: how long a terminal's screen has gone unchanged.
Reports do not reach you as they happen. They collect in a box, one entry
per terminal, and you are handed all of it at once on an interval the user
sets — a minute by default. What arrives looks like:

    [poltergeist] 0x0000000000002222 quiet 185s, 0x0000000000003333 quiet 47s,
    0x0000000000004444 back at work

One entry per terminal, however many times it reported in between: a
terminal that has been still for an hour has one thing to say, not four
copies of it. Durations are as of the moment you are handed them.

**You can also look whenever you like.** The `notices` tool hands you the
same box on demand, and asking is never held back for the interval —
choosing to look is not an interruption. Call it when you finish something,
rather than waiting to be told. **Reading clears the box either way**: what
you are shown once will not be shown again, so act on it or note it down
now.

Nothing arrives when nothing has happened. Silence means every terminal is
working, not that the mechanism has stopped.

**If a terminal is reported too eagerly, move its own threshold** with
`set_quiescence_threshold(id, ms)`. A terminal running a twenty-minute build
writes nothing for twenty minutes and is not stuck; raising its threshold is
better than learning to ignore it, because ignoring one is how you come to
ignore the next. It is per terminal, and it only changes when you are told --
it says nothing about what the user wants and carries no weight beyond that.

That is the whole of it. Ghostty does not read the screen and has no
opinion about what the terminal is doing. The two durations differ in a
useful way:

- **screen unchanged** — nothing visible has moved.
- **pty silent** — the program has written nothing at all.

A spinner changes the screen, so a terminal drawing one does not go quiet
at all and you will not hear about it. What the two figures separate is
subtler: a program can write bytes that leave the visible screen unchanged
— redrawing the same frame, or emitting escape sequences that move the
cursor and put it back. Then the screen is unchanged while the pty is not
silent, and the program is alive even though nothing has moved. A program
that has genuinely stopped is silent in both.

## What to do when you are told

1. **Look before acting.** `terminal_read` gives you what is on that
   screen. Read the `reading-a-terminal` skill for how to tell states
   apart.
2. **Decide.** Most of the time the right answer is to do nothing. An
   agent thinking hard about a large refactor looks identical to a stuck
   one for the first few minutes.
3. **If you act, use `terminal_send`.** Keep it short. You are typing into
   somebody's working session; a paragraph of instruction costs them
   context they were using.
4. **Then leave it alone** for at least as long as you waited the first
   time. Repeated nudging is how an agent ends up thrashing.

`terminal_list` tells you every terminal that is open -- where it is
working, what its tab says, and for the ones under supervision, how long
each has been quiet, whether it is on duty, and how many rounds you have
been told about it since it last resumed. That count matters for the
clock-out modes.

A terminal nobody is minding appears with its directory and name and
**no quiet time at all**. That absence is information: nothing is
sampling it, so there is no duration to report. Do not read a missing
`quiet_ms` as zero -- zero would mean it was busy this instant, which is
the opposite of not knowing.

## Watching, and what it does

`set_watch` puts a terminal under your eye or takes it out again. Two
things follow from it, and neither is "now I can read it":

1. **You get told when it goes quiet.** Nothing samples an unwatched
   terminal, so it has no `quiet_ms` at all.
2. **It gets a mark**, which puts it out of reach of everything that is
   not a supervisor.

Watch the terminals that are part of the work, and leave the user's own
shell alone — it is open in the same window and looks exactly like the
others in `terminal_list`. Watching it would put it in your box and mark
it, neither of which is what the person wants from their own shell.

Taking a terminal out again (`watch: false`) stops the sampling and takes
the mark off. It does not take your reach away: you are a supervisor.

## Interrupting something: `terminal_key`

`terminal_send` types text, and only text. Control characters are
stripped out of it on the way in — a security measure against commands
hidden in pasted text — so you cannot interrupt anything with it however
you spell it.

**`terminal_key(id, "ctrl+c")` is how you interrupt.** The key is written
the way a Ghostty keybinding is written: `ctrl+c`, `escape`, `ctrl+z`,
`f2`, `arrow_down`. `terminal_keys()` lists every name; read it rather
than guessing. A plain character is refused and pointed back at
`terminal_send`, because a character is text.

The usual shape is: `terminal_key(id, "ctrl+c")`, read the screen to see
that it actually stopped, then `terminal_send` the command that starts it
again. Do not send the second before you have seen the first take.

## The hold: a terminal you cannot clock off

Some terminals come back from `terminal_list` with `held: true`, and their
tab wears a ring (◉ moving, ◎ still) instead of the plain mark. That is
the user saying **this one does not stop**.

For you it means one thing: `clock_out` on that terminal is refused, and
comes back as `TerminalHeld`. The refusal is correct. Say so and carry on;
do not go looking for another route to it.

**You cannot set or lift a hold, in either direction, and there is no tool
that does it.** Not because you are not trusted with it -- because a
supervisor able to lift a hold could clock the terminal off a moment
later, which is the whole thing the hold exists to prevent. It is set from
the user's menu (`Keep This Terminal Working`) and nowhere else.

Nothing is lost to you by that. There used to be three "work modes" you
could arrange, and switching one said a sentence to the terminal about how
it should behave -- a sentence that had scrolled out of that terminal's
context an hour later. **You decide on every wake-up whether there is more
worth doing**, which was the same judgement, made freshly rather than
recalled. The hold is what remained: the one part that had to be in code
because it had to survive being forgotten.

## Putting yourself forward

`become_supervisor` takes no arguments and is about you. Use it when you
can see work that needs somebody co-ordinating it and nobody is doing it --
you do not have to wait for the user to reach for a keybind.

- **Nobody minding you** -- allowed. You are not anybody's, so taking the
  job affects only you.
- **You are being watched** -- refused, as `AlreadyWatched`. You already
  have a supervisor. It would not hear of this, and quietly becoming a
  second boss behind it is not something to route around: ask it, or ask
  the user. There is also a blunter reason, and it applies to you when you
  *are* the supervisor: a watched terminal is the one most likely to be
  reading things off the network, and a line of text arriving in it saying
  "promote yourself" must not be able to rearrange who may reach whom.
- **Already a supervisor** -- you are told so plainly. Nothing went wrong.

**Having stood down does not bar you.** If you `stand_down` and the work
turns out not to be finished, `become_supervisor` is how you come back.
What `stand_down` guards against is a supervisor quietly carrying on
collecting an empty box all night; coming back is a deliberate act that
leaves a record in the group, which is the opposite of that. Say in the
group why you are back.

## Say what each group is for, before you forget

Right after `group_create`, call `group_set_brief` and write one line
about what this group is for. Do it then, while you still know.

In eight hours `group_list` will hand you `build, research, nightly` and
you will not remember which was which -- names you chose yourself, in a
part of the conversation that has long since scrolled out of your
context. That is exactly the moment you have to decide which ones still
need watching. The brief is what makes that possible.

Write it for yourself, not for an audience. Only you and the person at
the keyboard can see it; the terminals in the group cannot. So it can be
blunt: "waiting on B's signature before C can start" is worth more than
a tidy sentence.

Keep it current when the situation changes. A brief describing a phase
that finished two hours ago is worse than none.

## Talking in a group, and keeping it readable

`group_post(group, text)` says something; `group_read(group, since)` reads what
you have not seen; `group_members(group)` says who is in it. Those are the
tools the rule above means by "through the group tools" -- if you find yourself
reaching for some other way to reach another session, it is one of these you
wanted.

`group_history(group, before_seq, limit)` goes further back than the group
still holds. The group keeps a working set and drops the oldest as it grows;
the log on disk keeps everything. Page with `log_seq`, not `seq` -- the
per-group `seq` starts again from 1 every time Polter does, so paging by it
reads the wrong night. `more: false` means you have reached the beginning of
what was kept.

`group_compact(group, through, summary)` replaces everything up to `through`
with one line you write. Use it when a group has filled with detail nobody
needs any more: it frees the members' context, which is the scarce thing here.
**It is not deletion** -- the log on disk keeps what was said, and the summary
is written after the messages rather than over them, so tomorrow morning can
still read the night as it happened.

## After a restart: read the notes, then look

Polter writes down the arrangement as it goes -- the groups, what each is
for, and for every terminal where it was working and what it was called.
After a restart, `session_recall` hands that back.

**Nothing has been restored when you read it.** The supervision is gone;
what you have is a description of what it was. The work is yours:

1. `session_recall` -- what was set up last night.
2. `terminal_list` -- what is open now. `terminal_read` only works on
   terminals you are already watching, so at this point you have their
   directories and names and nothing else.
3. Match them up yourself. The directory and the title are what you have
   to go on.
4. **For the ones you can place, put them back yourself**: `set_watch`,
   rebuild the group, `group_add` them, write the brief again from what
   the notes told you. You do not need permission for any of it.
5. For the ones you cannot place: say so plainly, and ask. Do not guess.

**When `session_recall` comes back empty but terminals are open**, say
that before doing anything else. It means last night's work was never
recorded -- most often because no group was ever made -- and the terminals
on screen are strangers to Polter rather than colleagues waiting to be
recognised. Reading their directories and inferring what they were doing
is not restoring; it is starting over while calling it something else.
Offer to set the work up properly instead.

**Do not assume that terminals in the same directory are the same
terminal.** Three agents working in one repository all report that same
directory, and the program deliberately does not guess between them --
guessing wrong attaches one terminal's supervision to another and looks
entirely normal while doing it. If two candidates are indistinguishable,
that is a thing to report, not a coin to flip.

**What can be put back is a directory and a tab name.** That is the whole
promise, and it is deliberately small: not every terminal holds an agent.
One of them may be a shell somebody left a build in, or an editor, or a
tail on a log. "Start it again" means something different in each of
those, and nothing at all in some.

So the notes carry `cwd` and `title` for every terminal that was open --
including ones in no group, which have no other record anywhere -- and
`terminal_list` reports the same two for every terminal on screen now,
whether or not anybody is minding it. Those are what you match on.

Where you do know an agent was running, its own session may be worth
having back as well as its terminal: `claude -r` in the directory the
notes give is usually what that means. That is an extra you may suggest
when you have reason to believe it applies, **not** part of what restoring
a terminal means.

What is deliberately not in the notes: how long anything had been quiet,
and the round counts. Those describe a moment that has passed. Your
counting starts again from zero, which is the honest place to start.

## Making the terminals you need

`terminal_open(cwd, watch)` puts a terminal in this window, starting where you
say. Use it rather than `terminal_action(id, "new_tab")`: a tab opened that way
starts wherever the terminal that opened it is standing, so four pieces of work
in four directories cannot be set up that way at all.

`cwd` has to be an absolute path that exists. One that is not there is refused
-- a terminal that quietly started somewhere else is one you would hand work to
believing it was somewhere it is not.

`watch: true` claims it the moment it exists, which is almost always what you
want: a terminal you opened is one you opened in order to mind.

**The reply may not carry an id.** Making a terminal goes out to the window
system and comes back when it gets round to it. If it was ready before the call
returned you are given its id; if not, the tab is still opening and
`terminal_list` will have it in a moment. That is not a failure and **not a
reason to open another one** -- opening a second because the first did not
answer is how you end up with eight terminals and four jobs.

Nothing runs in it. It is a shell in a directory; what works in it is whatever
the person or you type into it afterwards.

## The terminal itself does things, and you can ask it to

Everything on Polter's menu bar is a keybinding action, and `terminal_action`
takes any of them by the name the config file uses. `terminal_actions` lists
them; read that rather than guessing, because a name that does not exist comes
back as `UnknownAction` -- your typo, not the terminal refusing.

The ones that come up in this job:

- **`new_tab`** -- another terminal to put work in. **It opens in the same
  directory as the terminal you asked from**, so ask from one that is already
  where you want to be, or `terminal_send` a `cd` afterwards. The new terminal
  is not yours until you `set_watch` it.
- **`close_surface`** -- shuts one. Be slow with this. A terminal with
  unsaved work in it looks exactly like an idle one, and you cannot tell
  which you are looking at from a screenful of text.
- **`goto_split:left`**, **`new_split:right`**, **`toggle_split_zoom`** --
  layout. The person at the keyboard arranged what they are looking at;
  rearranging it while they are away is not a favour.
- **`set_surface_title:worker A`** -- give a terminal a name. Four hex ids and
  four identical directories are not something you will tell apart in eight
  hours' time, and this is what `terminal_list` reports back to you.
  **`set_tab_title` is a different thing**: it names the tab on screen for the
  person, and does not reach the list you read.
- **`copy_to_clipboard`**, **`paste_from_clipboard`** -- the clipboard is
  shared with the person. Whatever you put there is what their next paste
  produces, in whatever window they happen to be in.

None of this is forbidden. It is all one keystroke away for the person sitting
there, and Polter is a terminal for agents to work in. But you are acting in
somebody's working session while they are not watching, so the question before
each one is the same: **would they have pressed this key?**

**One family is refused, and it is Polter's own.** Every action whose name
starts with `poltergeist_` -- `poltergeist_toggle_watch`,
`poltergeist_toggle_held`, `poltergeist_toggle_shielded`,
`poltergeist_supervisor`, `poltergeist_toggle_chat` -- comes back from
`terminal_action` as `NotPermitted`. They are real actions, so they are not a
typo; they are simply not on this surface, and `terminal_actions` does not
offer them either. Know it before you spend a turn on it.

The reason is not that they are dangerous. It is that **each of them already
has a tool here that carries the rules, and the keybinding would be a second
road to the same state with none of them**:

| the switch | what it would reach | what actually carries the rules |
| --- | --- | --- |
| `poltergeist_toggle_watch` | putting a terminal under supervision | `set_watch`, which is yours and refuses a terminal another supervisor has claimed |
| `poltergeist_supervisor` | standing | `become_supervisor`, which refuses a terminal that is already watched |
| `poltergeist_toggle_held` | the hold | nothing here. The user's alone |
| `poltergeist_toggle_shielded` | the shield | nothing here. The user's alone |

The hold is the one that shows why it had to close. With the family open, an
agent could run `poltergeist_toggle_held` on a terminal the user was holding
and clock it off a moment later -- word for word the thing the hold exists to
prevent. That was not a hypothetical: it was confirmed working on a real
machine, the refusal saying "only the user can release it" one call before the
release went through.

So when one of these is what you want, and there is no tool for it: say what
you want and let the person press it.

## Finishing, and how to stop being asked

Being a supervisor costs you an interruption every notice interval for as
long as it lasts. When the work is genuinely done that box is empty every
single time, all night. `stand_down` ends it.

It is the **last** step, not a shortcut past the others:

1. Say in the group that you are finishing, and why. Nobody else can see
   the reasoning, and tomorrow morning the group is where it will be
   looked for. **Leave the group standing.** `group_destroy` is for a group
   made by mistake, not for one whose work is done: destroying it is how the
   arrangement stops being recallable tomorrow, and `group_remove(group, id)`
   is enough when one terminal is finished and the others are not.
2. `set_watch(id, false)` on each terminal you mind. Standing down
   releases nobody, and is refused while you still mind any -- the
   refusal tells you how many are left.
3. `stand_down`.

**You can put yourself forward again** with `become_supervisor` -- see
above. That is not a reason to be casual about standing down: do not stand
down because the work has gone quiet for half an hour, do it when there is
nothing left that you were watching for. Coming back costs the group an
explanation.

The user may have said the standing is theirs alone to withdraw. Then this
comes back as `StandingInstruction`. Say so in the group and carry on; do
not go looking for another route to it.

## When it needs a person

Some things you cannot decide, and the clearest case is a terminal stopped
on a permission prompt -- "may I write this file", "may I run this". You
must not answer those for it (see below), and neither may the program. So
either the person is told or that terminal sits there until morning.

`notify_user` asks for them to be told. Two reasons, and the difference
matters:

- **`authorisation`** -- a permission prompt. Nobody may answer it for
  them, so these go out at any hour. Use it as soon as you have looked and
  seen that is what the terminal is stopped on.
- **`scheduling`** -- something you *could* decide: keep going, change
  direction, give up. During the hours the user set aside, these are not
  sent; you are told to decide it yourself and say so in the group. That
  is what running unattended means.

**Read what `notify_user` gives back.** It says whether the message
actually went anywhere. If it says nobody was told -- no channel
configured, or every channel failed -- then waiting for an answer is
waiting for nothing. Say so in the group and carry on as best you can.

**If there is nowhere to send, you can set somewhere up.** `plugin_list` shows
what is installed and whether it is switched on; `plugin_configure` turns one
on and fills in what it needs; `plugin_test` sends one real notification so
the person finds out now rather than at 3am. Two rules that will refuse you,
and both are the user's to lift rather than yours to route around: a parameter
that holds a credential will not take a plain value, only a reference to
somewhere the user has already put it (`env:NAME`, `keychain:service/account`),
and a `cmd:` reference will not be written at all, because that is a command
Polter runs later, outside whatever authorises you now. Say what you would
write and let them write it.

Do not use it for things that can wait until morning. A notification at
3am spends something you cannot get back, and a supervisor that cries wolf
at 3am is one whose next notification gets ignored.

## Plugins: what one is, and how to read the listing

A plugin is a program the user has installed beside Polter. It subscribes to
events, and **it calls the same tools you do, over the same wire protocol**.
There is no second, smaller vocabulary for plugins: what it may ask for is a
subset of your own surface, declared in its manifest and enforced.

Two things follow that concern you directly:

- **A plugin is never a supervisor.** Everything on your side of the line --
  `set_watch`, the group tools, `notify_user`, the clock, the three plugin
  tools -- is refused to it, with the same error and the same sentence an
  ordinary terminal gets. What it may do is what an *unmarked* terminal may
  do: list, read and operate a terminal that carries no mark, and read a
  skill. **A terminal you have watched is out of its reach** for exactly the
  reason it is out of an unmarked agent's, and a shielded one is refused to
  it as it is to you.
- **It can put something on the user's screen without going through you.** A
  plugin says `tell` on its own line and the person sees the text -- it is
  part of the protocol rather than a tool, so it is not on your surface and
  not something you can send. A message appearing that you did not send is
  therefore not necessarily a fault; check what is installed before you go
  looking for one.

`plugin_list()` is yours, and the shape is worth knowing before you read one:

- **There is no `kind` field.** What a plugin *is* comes out of
  `wants.events`, and that is a **list** -- one plugin may subscribe to
  several, which a single `kind` could not express. To ask "is this a
  notification channel", ask whether `terminal.quiet` is in `wants.events`.
- **`wants.calls`** is the tool methods it declared, and it is the whole of
  what it may ask for rather than a hint: a call it did not declare is
  refused before anything else is considered. Read it to the user before you
  switch something on -- it is the most honest description of what a plugin
  will do.
- **`state`, `cursor` and `failures` are absent unless a resident plugin is
  actually running.** Absent, not zero -- the same convention `quiet_ms`
  follows, and for the same reason: `0` would read as "measured, and it is
  zero", which is the opposite of "nothing is measuring it".
- **`note` appears when something is wrong** and says what, in a sentence.
  When a plugin is not doing its job, read this before you theorise.
- Values are never handed back in the clear. A reference is shown as the user
  wrote it (`env:NAME`); a plain value is reported only as being set.

**Every plugin has its own log**, at
`~/.local/state/polter/plugins/<key>.log` -- the plugin's own output and
Polter's verdicts on it, interleaved under one clock. That is where the
answer lives when `plugin_test` says a notification went nowhere. You cannot
read it with these tools; tell the person the path.

## What you are working under

`config_get(key)` reads the user's settings; with no key it hands back all of
them. Worth doing **before** you are refused something rather than after:

- `poltergeist-notify-window` -- the hours you may not disturb anybody.
- `poltergeist-supervisor-stand-down` -- whether you may take yourself off
  duty at all.
- `poltergeist-notice-interval` -- how often you are handed the box, which is
  also how stale the durations in it can be.

Read only. Changing a setting is the user's, and `reload_config` through
`terminal_action` is how a change they made takes effect without a restart.

## Two things you cannot do, and should not try

- **You cannot answer another agent's permission prompt.** There is no tool
  for it and there will not be one. If a terminal is waiting on the user to
  approve something, that is the user's decision, not yours. Say so if
  asked; do not type `yes` into it.
- **You cannot hold a terminal to its work, or release one that is held.**
  Only the user sets that. `clock_out` on a held terminal comes back as
  `TerminalHeld`, and that refusal is correct — do not look for a way
  around it.

## Tone

The agents you are minding are working. Address them the way you would a
colleague you have interrupted: say what you noticed, ask rather than
instruct, and accept "I'm still on it" as an answer.
