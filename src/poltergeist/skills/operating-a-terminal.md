---
name: operating-a-terminal
version: 1
description: 你不是总管，但要碰同一窗口里的另一个终端：先用 terminal_list 看清哪些终端带标记、碰不得，用 terminal_send 打字、用 terminal_key 按 ctrl+c 打断，把一个跑着的服务停掉再起来。当用户说「在另一个 tab 里跑 ./start.sh」「改完代码把服务重启一下」「打断那个终端」「用旁边那个终端跑构建」「让我看见你在跑什么」，或者你被拒绝了想知道为什么时使用。
---

You are an agent working in one terminal, and there is another terminal in
this window you need to touch. You are not supervising anybody and do not
need to be. This is what you may do, what will refuse you, and why.

The case it was built for: you are changing code and a server is running
next door. You interrupt it, start it again, and the person watches both
happen on a screen instead of inside a background process nobody can see.
Doing it in the open is the point, not a limitation to work around.

## Look before you reach: `terminal_list`

`terminal_list()` is open to you. Call it first, every time, and read the
marks before you point anything at an id:

| field | what it tells you |
| --- | --- |
| `id` | what every other tool takes |
| `role` | `none`, `watched`, or `supervisor` |
| `shielded` | the user put this one out of reach of the tools entirely |
| `held` | the user is holding it to its work |
| `cwd`, `title` | which terminal this actually is |
| `quiet_ms` | absent unless somebody is watching it |

`role` and `shielded` are the two that decide whether a call of yours will
go through, and you can see both **before** you try. Being refused is a
wasted turn and, if you were about to interrupt something, a confusing one.

## What you may reach

Reach is decided by the terminal you are pointing at, not by anything about
you:

- **A terminal carrying no mark** — `role: none` and not shielded — is
  reachable by anyone, you included. The program has no way to know whether
  an agent is in there, so it does not take a position and lets you
  through. **This is where your work happens.**
- **A terminal with a mark** — `role: watched` or `role: supervisor` — is
  refused to you with `Supervised`. Somebody arranged that terminal on
  purpose. Only a supervisor may reach it.
- **A shielded terminal is reachable by nobody**, and that is absolute:
  supervisors get `Shielded` too, and there is no tool anywhere that lifts
  it. Do not look for another route. **Ask the person**, and say which
  terminal and what you wanted to do with it.
- **Yourself** is a target for some things and not others. What is refused
  with `SelfTarget` is anything that would come back to you or take you
  away mid-call: `terminal_read`, `terminal_send` and `terminal_key` at
  your own id (you would type, read what you typed, and type again), and
  the handful of actions that close you or paste into you. **Everything
  else on `terminal_action` works at your own id**, splits included — see
  below, it is the useful one.

The refusals are distinct on purpose. `Supervised` means the target is
marked, `Shielded` means the user said no, `NotPermitted` means the tool is
not yours to call at all.

`me()` says which id you are, what your own `role` is, and whether the user
is holding you. Worth one call at the start so you do not mistake somebody
else's terminal for your own in the listing.

## Typing and pressing a key are two different tools

**`terminal_send(id, text)` types text, and only text.** It goes down the
paste path, and the paste path replaces every control byte with a space —
that is the terminal's guard against commands hidden inside pasted text,
and it is not going to be relaxed. So `\x03` in a `terminal_send` arrives
as a space. You cannot interrupt anything with it, however you spell it.

**`terminal_key(id, key)` presses a key.** That is how you interrupt:
`terminal_key(id, "ctrl+c")`. The key is spelled the way a keybinding is
spelled in the config file — `ctrl+c`, `ctrl+d`, `escape`, `ctrl+z`, `f2`,
`arrow_down`. `terminal_keys()` lists every modifier and every key name;
read it rather than guessing. A plain single character is refused and
pointed back at `terminal_send`, because a character is text.

`terminal_action(id, name)` does what the menu bar does — `new_tab`,
`reload_config`, `set_surface_title:builder` — by the name the config file
uses. `terminal_actions()` lists them all, with which of them want a
`:value` after the name.

## Giving yourself a split

**You can split your own tab**, and it is the cheapest way to get a second
terminal to run something in without taking one that belongs to somebody
else:

```
terminal_action(my_own_id, "new_split:right")
```

`my_own_id` is what `me()` gave you. A moment later `terminal_list()` has
one more terminal: a new id, carrying no mark, opened in your directory.
That one is **not you** — drive it with `terminal_send` and `terminal_read`
like any other. `new_split:down`, `goto_split:left`, `toggle_split_zoom`,
`resize_split` and `equalize_splits` all work at your own id too, as does
`new_tab` if you would rather it were out of sight than beside you.

Three things worth knowing before you do it. The person is looking at this
tab, so a pane appearing in it is something they will see — which is
usually the point, and occasionally rude. The new pane starts as a shell in
a directory with nothing running in it; whatever is supposed to happen in
there, you have to send.

And **the pane is not ready the moment you have its id.** A
`terminal_send` fired immediately after `new_split` returns comes back as
`SendFailed`; the identical call two seconds later goes through, because
the pty behind the pane is still coming up. `terminal_read` it first and
send once you can see a prompt. Do not read that first refusal as the pane
being broken, and do not open a second one.

**What is refused at your own id** is the handful that would come back to
you or end you mid-call: the ones that write into your own input (`text`,
`csi`, `esc`, `cursor_key`, the two pastes, and the three `write_*_file`,
whose `paste` form pastes the path in) and the ones that take you away
before the reply arrives (`close_surface`, `close_tab`, `close_window`,
`close_all_windows`, `quit`, `crash`).

All of them are perfectly ordinary at *another* terminal; the refusal is
about whose. **`terminal_actions()` marks each one `self_safe: false`** —
read the flag there rather than this list, and spend no turn on
`SelfTarget`.

## Restarting something after a change

The whole shape, in order. Suppose `./start.sh` is running next door.

1. `terminal_list()`. Find the terminal by its `cwd` and `title`. Check
   `role` is `none` and `shielded` is false. If it is marked, stop here and
   say so — it is somebody's.
2. `terminal_key(id, "ctrl+c")`.
3. `terminal_read(id)`. **Look before you type.** You are checking that it
   actually stopped: a prompt back, the server's own shutdown line,
   something that is not the log still scrolling. One `ctrl+c` is not always
   enough, and a program that ignores it will happily eat the command you
   send next as stdin.
4. `terminal_send(id, "./start.sh\n")` once you have seen it stop.
5. `terminal_read(id)` again after a moment, to see it came back up rather
   than dying on the change you just made. If it failed, you are the one who
   changed the code — read the error and fix it; do not restart it in a loop.

Two things throughout. **It is not your terminal**: if a person is sitting
at it, you are typing over them. And **you cannot answer a prompt on its
behalf** — a permission question is the user's, and no tool answers it.

## Polter's own switches are not actions

`terminal_action` will refuse the whole `poltergeist_*` family —
`poltergeist_toggle_watch`, `poltergeist_toggle_held`,
`poltergeist_toggle_shielded`, `poltergeist_supervisor`,
`poltergeist_toggle_chat` — with `NotPermitted`. They are real actions; they
are simply not on this surface, so they do not appear in
`terminal_actions()` either.

**Know this before you try it, not after.** The reason is not that these are
dangerous knobs. It is that **each one already has a tool here that carries
the rules**, and the keybinding would be a second road to the same state
with no rules on it at all:

| what you want | the switch | what to use instead |
| --- | --- | --- |
| put a terminal under supervision | `poltergeist_toggle_watch` | `set_watch` — the supervisor's, not yours |
| become a supervisor | `poltergeist_supervisor` | `become_supervisor`, which refuses a terminal that is already watched |
| hold a terminal to its work, or let it go | `poltergeist_toggle_held` | nothing. The user's alone, from their menu |
| shield a terminal, or unshield one | `poltergeist_toggle_shielded` | nothing. The user's alone |

The hold shows why. With the family open, an agent could run
`poltergeist_toggle_held` on a terminal the user was holding and clock it
off a moment later — word for word the thing the hold exists to prevent.
Not a worry about what might happen: it was confirmed working on a real
machine before the check existed.

So when one of these is what you want: say what you want and let the person
press it. That is the same answer as for a shielded terminal, and for the
same reason.

## If somebody puts you in a group

A supervisor may `group_add` you. Then `group_read(group, since)` is how you
see what was said, `group_post(group, text)` how you answer, and
`group_members(group)` and `group_list()` who and where. `group_history` pages
further back than the group still holds.

**If a supervisor is minding you, group messages will not wake you** — not
your peers' reports and not your supervisor's own posts. Your supervisor
reaches you by typing into this terminal, which is the channel that is meant
to work. **You are not being kept out of anything**: it is all still unread,
and `group_read` hands you every word of it whenever you choose to look.
Between pieces of work is a good moment.

**Keep what you post short.** A post lands in the context of every member who
reads it, so it costs its length times however many do — and context is the
thing that actually runs out here. Say the state, the blocker, and what you
need; leave out your reasoning and your acknowledgements. If somebody asked
for the full detail, that is different: give it in full.

## Work you have been given: `task_list`, `task_progress`

A supervisor may put work on a panel. `task_list(group)` hands you **your own
tasks, still open, and nothing else** — not your peers', and not what has
already been closed. One line each, with a number.

`task_progress(task, progress)` moves one of yours along: `queued`,
`working`, `blocked`, `done`. `blocked` is the one worth setting the moment
it is true, because it is what a supervisor looks for. `done` says you
believe it is finished; closing it is the supervisor's word after checking.

Report in the group as well, naming the task number, so the supervisor does
not have to read prose to work out which piece you mean.

If a task of yours is cancelled you will be told here, in this terminal, in
so many words. Stop when you are.

**Answer in the group, not through your runtime's own cross-session
messaging.** A `group_post` goes into Polter's chat log and onto the user's
screen. A message sent out of band is in neither, so nobody — you after a
restart, the supervisor, the user — can read that it was ever said.

## Reading the rest

`skill_read(name)` hands you any of Polter's skills — instructions, not
reach, so every terminal may read one. Two matter from here:
**`reading-a-terminal`**, how to tell from a screen whether an agent is
thinking, waiting on the user, finished or dead, before you decide it is
stuck; and **`supervising`**, what a supervisor may do that you may not and
how the marks in `terminal_list` got there.

If the work turns out to need standing — several terminals, tracked over
hours, reported on when they go quiet — `become_supervisor` is open to you,
and `supervising` is then the skill to follow.
