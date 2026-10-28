// Polter's hooks for opencode: tell the terminal opencode runs in what it is
// doing (tasks 1777 and 1806, dev-docs/poltergeist/adapters.md part ten).
//
// opencode has no command hooks. What it has is a plugin -- a package run
// inside its server process -- that can subscribe to every event on its bus
// and hook the tools (`packages/plugin/src` at v2.0.32). So this package is
// the hook: for each event Polter cares about it runs
//
//     <polter> +hook --cli opencode-v2 <type>
//
// with one JSON object on stdin, `{"type", "data", "polter"}`: `type` and
// `data` are opencode's own, passed through as they came, and `polter` is
// what this file adds -- the only thing it adds. The translation into
// Polter's words is `opencode()` in src/poltergeist/agent_event.zig, where it
// is tested; nothing here decides what an event means.
//
// **`opencode-v2`, not `opencode`** (task 2237): the name a hook reports is
// the key of the plugin that started the session, so that a session is never
// counted under the plugin for the other major version. This plugin's key is
// `opencode-v2` (`plugin.json`), and both keys reach the same table in the
// core (`AgentEvent.isOpencode`). The 1.x plugin beside this one reports
// `opencode`, and that is the only thing that differs between the two files.
//
// **A directory, not a file.** opencode 2.0 drops a configured plugin path
// that is a file ("configured plugin path must be a directory") and loads a
// directory's `index.js`, whose default export is `{id, setup}`. There is no
// loader for the 1.x shape, so this works on 2.0 and later only (the
// adapter's `MIN_VERSION`).
//
// **Loaded only where Polter started opencode.** The role's launch hands it
// in through `OPENCODE_CONFIG_CONTENT` ("plugin": ["file:///…/polter-hooks"])
// and names the Polter to run in `POLTER_HOOK_EXE`, on an opencode started
// `--standalone`: a server of its own, with that launch's environment. (The
// shared background service would be someone else's, started with somebody
// else's environment -- adapter.py says how that was measured.) Without that
// variable -- a copy loaded some other way -- it subscribes to nothing.
// Nothing of the person's configuration is written for it, and nothing is
// written into this directory: it is part of a signed app.
//
// **One terminal, one session** (task 2414). A `--standalone` TUI's server
// carries every tab of that TUI on one bus: a `/new` in the same TUI is a
// second session on this server. Another TUI's sessions do not come here at
// all (measured; see dev-docs/poltergeist/adapters.md, the opencode part,
// "哪个会话是终端的会话"). So the terminal's session is the one that started
// its turn last: each non-subagent `session.execution.started` makes its
// session the terminal's, so a `/new` and a switch of tab followed by a
// message both carry the terminal over, the way claude-code's `/new` does.
// `session.created` only sets it while nothing has yet (the first session).
// Events of any other session -- a tab that is running in the background
// after the terminal moved on -- and of their subagents are not said.
//
// **It never holds opencode up and never throws.** The tool hooks are
// awaited by opencode before it goes on, so each handler only queues its
// event and returns; the queue runs one `+hook` at a time, which also keeps
// them in the order opencode said them. A `+hook` that fails, or a Polter
// that is not there, is dropped silently: `+hook` itself always exits 0 and
// writes nothing to stdout.

import { spawn } from "node:child_process"

const EXE = process.env.POLTER_HOOK_EXE || ""

// The events passed on, by their opencode names. Everything else on the bus
// -- every streamed part of every message among them -- is dropped before
// anything is done with it. `session.text.ended` is read here (`answers`)
// and not passed on.
const BUS_EVENTS = new Set([
  "session.created",
  "session.execution.started",
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
  "session.retry.scheduled",
  "permission.asked",
  "permission.replied",
  "form.created",
  "form.replied",
  "form.cancelled",
])

// An approval or a question is said for an agent under the terminal's current
// session at any depth, because the terminal is waiting on it whichever agent
// asked. The rest of a subagent's events are not said. Under a background
// session (not the current one) it is not said either: see `owner` above.
const ASKS = /^(permission|form)\./

// Most of an answer handed to `+hook`. It cuts to its own limit
// (`AgentEvent.max_text_bytes`); this only bounds the pipe.
const MAX_ANSWER = 64 * 1024

const sessionOf = (data) => (data && (data.sessionID || (data.form && data.form.sessionID))) || null

export default {
  id: "polter-hooks",
  setup: async (ctx) => {
    if (!EXE) return

    // Sessions a subagent tool started under another one (`parentID` on
    // their `session.created`), with that parent. Their turns are not the
    // terminal's turns: a subagent finishing is not the agent finishing.
    const children = new Map()

    // The terminal's session: the one whose turn started last (see the top of
    // this file). Null until the first session, and other sessions are dropped.
    let owner = null

    // What each session's turn has said so far: the text of its last
    // assistant message, kept from `session.text.ended` -- a message says
    // its text in pieces (`ordinal`), and a turn that used a tool has said
    // other messages before it. The answer a turn ended on is the last one.
    const answers = new Map()

    let queue = Promise.resolve()
    const send = (type, data, polter) => {
      queue = queue
        .then(
          () =>
            new Promise((resolve) => {
              const payload = JSON.stringify({ type, data, polter: polter || {} })
              const proc = spawn(EXE, ["+hook", "--cli", "opencode-v2", type], { stdio: ["pipe", "ignore", "ignore"] })
              proc.on("error", resolve)
              proc.on("close", resolve)
              proc.stdin.on("error", () => {})
              proc.stdin.end(payload)
            }),
        )
        .catch(() => {})
    }

    // The session at the top of a subagent's chain of parents (a session
    // that is not a subagent is its own root). A depth bound keeps a bad
    // chain from looping.
    const rootOf = (sid) => {
      let s = sid
      for (let i = 0; i < 64 && children.has(s); i++) s = children.get(s)
      return s
    }

    const answerOf = (sid) => {
      const a = answers.get(sid)
      if (!a) return null
      const text = a.parts.join("")
      return text.length > MAX_ANSWER ? text.slice(0, MAX_ANSWER) : text
    }

    const onEvent = (event) => {
      if (!event || typeof event.type !== "string") return
      const data = event.data || {}
      const sid = sessionOf(data)

      if (event.type === "session.text.ended") {
        if (!sid || children.has(sid) || sid !== owner) return
        let a = answers.get(sid)
        if (!a || a.message !== data.assistantMessageID) {
          a = { message: data.assistantMessageID, parts: [] }
          answers.set(sid, a)
        }
        if (typeof data.text === "string") a.parts.push(data.text)
        return
      }
      if (!BUS_EVENTS.has(event.type)) return

      if (event.type === "session.created" && data.parentID) {
        children.set(sid, data.parentID)
        return
      }
      const child = sid !== null && children.has(sid)
      if (!child && sid !== null) {
        if (event.type === "session.execution.started") owner = sid
        else if (event.type === "session.created" && owner === null) owner = sid
      }
      // A subagent belongs to the terminal's session through its parents, at
      // any depth: a grandchild's approval is the terminal's when its root is.
      if (child ? rootOf(sid) !== owner : sid !== owner) return
      if (child && !ASKS.test(event.type)) return

      if (event.type === "session.execution.started") answers.delete(sid)
      if (event.type === "session.execution.succeeded") {
        send(event.type, data, { answer: answerOf(sid) })
        answers.delete(sid)
        return
      }
      send(event.type, data, child ? { child: true } : {})
    }

    ;(async () => {
      try {
        for await (const event of ctx.event.subscribe()) {
          try {
            onEvent(event)
          } catch {}
        }
      } catch {}
    })()

    for (const name of ["execute.before", "execute.after"]) {
      try {
        await ctx.tool.hook(name, async (input) => {
          try {
            if (!input || input.sessionID !== owner || children.has(input.sessionID)) return
            send("tool." + name, { sessionID: input.sessionID, tool: input.tool, id: input.id })
          } catch {}
        })
      } catch {}
    }
  },
}
