// Polter's hooks for opencode: tell the terminal opencode runs in what it is
// doing (task 1777, dev-docs/poltergeist/adapters.md part ten).
//
// opencode has no command hooks. What it has is a plugin -- a JS module run
// inside its own process -- that is handed every event on its bus and a few
// hook points around a turn (`packages/plugin/src/index.ts` at v1.2.10). So
// this file is the hook: for each event Polter cares about it runs
//
//     <polter> +hook --cli opencode <name>
//
// with one JSON object on stdin, `{"type", "properties", "polter"}`:
// `type` and `properties` are opencode's own, passed through as they came,
// and `polter` is what this file adds -- the only thing it adds. The
// translation into Polter's words is `opencode()` in
// src/poltergeist/agent_event.zig, where it is tested; nothing here decides
// what an event means.
//
// **Loaded only where Polter started opencode.** The role's launch hands it
// in through `OPENCODE_CONFIG_CONTENT` ("plugin": ["file:///…/polter-hooks.js"])
// and names the Polter to run in `POLTER_HOOK_EXE`. Without that variable --
// a copy loaded some other way -- every handler is a no-op. Nothing of the
// person's configuration is written for it.
//
// **It never holds opencode up and never throws.** `chat.message` and the
// tool hooks are awaited by opencode before it goes on, so each handler only
// queues its event and returns; the queue runs one `+hook` at a time, which
// also keeps them in the order opencode said them. A `+hook` that fails, or
// a Polter that is not there, is dropped silently: `+hook` itself always
// exits 0 and writes nothing to stdout.

const EXE = process.env.POLTER_HOOK_EXE || ""

// The events passed on, by their opencode names. Everything else on the bus
// -- every streamed part of every message among them -- is dropped before
// anything is done with it.
const BUS_EVENTS = new Set([
  "session.created",
  "session.status",
  "session.error",
  "permission.asked",
  "permission.replied",
  "question.asked",
  "question.replied",
  "question.rejected",
])

// Most of an answer handed to `+hook`. It cuts to its own limit
// (`AgentEvent.max_text_bytes`); this only bounds the pipe.
const MAX_ANSWER = 64 * 1024

// How long after an idle the session's last message is read
// (`last` below). Measured on 1.2.10 against a stand-in model: an abort's
// message carried its error by the time this had passed.
const SETTLE_MS = 300

export const PolterHooks = async ({ client }) => {
  if (!EXE) return {}

  // Sessions a task tool started under another one (`parentID`). Their
  // turns are not the terminal's turns: a subagent going idle is not the
  // agent finishing. Only their approvals and questions are passed on,
  // because those stop the terminal whoever asked.
  const children = new Set()

  let queue = Promise.resolve()
  const send = (name, type, properties, extra) => {
    queue = queue
      .then(async () => {
        const polter = { ...(extra ? await extra() : {}) }
        const payload = JSON.stringify({ type, properties, polter })
        const proc = Bun.spawn([EXE, "+hook", "--cli", "opencode", name], {
          stdin: new Blob([payload]),
          stdout: "ignore",
          stderr: "ignore",
        })
        await proc.exited
      })
      .catch(() => {})
  }

  // What the session's last answer was, read when it goes idle: its text,
  // and the error it ended on if it did. **The error is read off the
  // message, not remembered from `session.error`**, because the two do not
  // come in one order (measured on 1.2.10, task 1777): an API error says
  // `session.error` and then goes idle twice; an abort goes idle first and
  // says `session.error` after. Either way the message itself carries the
  // error, and an idle whose last answer failed is not a turn that ended --
  // `session.error` is what says how it ended.
  //
  // ⚠️ An abort's first idle comes before its message has the error on it
  // (opencode's `cancel` sets idle itself, then the turn's own code catches
  // the abort and marks the message): read at once, a stopped turn looked
  // like one that ended with nothing to say. So the message is read
  // `SETTLE_MS` after the idle -- measured, see the constant.
  //
  // And only a message from before the idle counts: the next turn may have
  // begun in that time -- a supervisor's next line, typed the moment this
  // one ended -- and its answer, not written yet, is not this turn's
  // (measured: read without this, the second idle after an API error found
  // the next turn's empty message and no error on it).
  const last = async (sessionID, at) => {
    await Bun.sleep(SETTLE_MS)
    try {
      const res = await client.session.messages({ path: { id: sessionID } })
      const list = (res && res.data) || []
      for (let i = list.length - 1; i >= 0; i--) {
        const m = list[i]
        if (!m || !m.info || m.info.role !== "assistant") continue
        if (m.info.time && m.info.time.created > at) continue
        const text = (m.parts || [])
          .filter((p) => p && p.type === "text" && !p.synthetic && typeof p.text === "string")
          .map((p) => p.text)
          .join("\n")
        const error = (m.info.error && m.info.error.name) || null
        return { answer: text.length > MAX_ANSWER ? text.slice(0, MAX_ANSWER) : text, error }
      }
    } catch {}
    return { answer: null, error: null }
  }

  return {
    event: async ({ event }) => {
      try {
        if (!event || !BUS_EVENTS.has(event.type)) return
        const p = event.properties || {}
        const sid = p.sessionID || (p.info && p.info.id) || null

        if (event.type === "session.created") {
          if (p.info && p.info.parentID) {
            children.add(p.info.id)
            return
          }
          send(event.type, event.type, p)
          return
        }

        const child = sid !== null && children.has(sid)
        const asks = event.type.startsWith("permission.") || event.type.startsWith("question.")
        if (child && !asks) return
        const extra = child ? { child: true } : {}

        if (event.type === "session.status") {
          const kind = p.status && p.status.type
          if (kind === "busy") return
          if (kind === "idle") {
            const at = Date.now()
            send("session.idle", event.type, p, async () => (sid ? await last(sid, at) : { answer: null, error: null }))
            return
          }
          send("session.retry", event.type, p)
          return
        }

        send(event.type, event.type, p, async () => extra)
      } catch {}
    },

    "chat.message": async (input) => {
      try {
        if (input && children.has(input.sessionID)) return
        send("chat.message", "chat.message", { sessionID: input && input.sessionID })
      } catch {}
    },

    "tool.execute.before": async (input) => {
      try {
        if (!input || children.has(input.sessionID)) return
        send("tool.execute.before", "tool.execute.before", {
          sessionID: input.sessionID,
          tool: input.tool,
          callID: input.callID,
        })
      } catch {}
    },

    "tool.execute.after": async (input) => {
      try {
        if (!input || children.has(input.sessionID)) return
        send("tool.execute.after", "tool.execute.after", {
          sessionID: input.sessionID,
          tool: input.tool,
          callID: input.callID,
        })
      } catch {}
    },
  }
}
