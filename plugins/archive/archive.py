#!/usr/bin/env python3
"""Keep an extra copy of the chat, one file per day, all groups in one timeline.

This is the reference `archive` plugin: the smallest thing that honours the
whole resident contract. One line of JSON in, one line of JSON out -- the host
greets us once with `{"hello":1,...,"params":{...}}` and then hands us batches,
and **every line it writes gets exactly one acknowledgement, the handshake
included**. That last clause is not a detail: the host arms a deadline before
it writes the greeting and waits for a line back (`Archive.zig`, around the
`allow(timeout_ms)` before `renderHello`). A plugin that reads the greeting and
then sits waiting for a batch is killed on `timeout_ms`, restarted, and killed
again -- a restart loop that looks, from the plugin's side, exactly like idling.
This file did that for one revision; the regression test that would have caught
it is in `Archive.zig` and it runs this very script against the bytes
`renderHello` really produces.

**What it is not.** It is not where Polter's records live. The core writes its
own stream and its own per-group record on the way past, and neither of those
depends on this plugin being installed, switched on, or working; this plugin is
never handed a file to follow, only the live events. So the copy here is an
extra one, and the point of it is that you can put it somewhere the core would
never write: a synced folder, an external disk, a NAS. See
docs/poltergeist/boundary.md section 1.

**Why a day and not a group.** The core's record is `<group>/<date>.jsonl`,
which is the shape for "what did that Kairos job say". This one is the other
cut: everything that happened on one evening, in the order it happened, in one
file you can `tail -f`. A second copy of the first shape at a second path would
add nothing, and that objection is on the record (docs/poltergeist/gaps.md).

An acknowledgement that names a cursor is a promise that everything at or below
it is on disk, so nothing here ever names a seq that did not come out of the
batch in hand -- a number the host cannot have sent us is the silent hole the
whole design exists to prevent.

Design: docs/poltergeist/storage.md. The host side is src/poltergeist/Archive.zig.

**Only acknowledgements may go to stdout.** Anything else is judged misconduct
and the process is killed. Diagnostics go to stderr, which is Polter's log.

Python 3.8, standard library only. Under a Polter launched from the Dock
`/usr/bin/env python3` resolves to the system interpreter -- 3.9 on a stock
macOS -- and not to whatever is on a developer's PATH, so nothing newer is used.
"""

import hashlib
import hmac
import json
import os
import sys
import time

# Where the copy goes when nobody says. Not a fallback for the record --
# Polter keeps that itself -- but a place to start from that is easy to
# repoint, which is the whole use of this plugin.
DEFAULT_DIR = "~/.local/state/polter/archive"

# The fields of a message, in the order the host sends them. `summary` is
# carried only when it is true, the same as on the wire.
FIELDS = ("seq", "at_ms", "group", "author", "text")


def canonical(record):
    """The bytes a line is signed over: sorted keys, no incidental spacing.

    Signing the file's own bytes would tie the signature to how this file
    happens to be written; signing a canonical form means a verifier only has
    to parse the line, drop `hmac`, and render it the same way.
    """
    return json.dumps(
        record,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


class Journal:
    """The half that touches the disk. One file per local day."""

    def __init__(self, directory, sign_key=""):
        self.directory = directory
        self.sign_key = sign_key.encode("utf-8") if sign_key else b""
        self.handles = {}
        os.makedirs(directory, mode=0o700, exist_ok=True)

    def path_for(self, at_ms):
        """`<dir>/YYYY-MM-DD.jsonl`, by the local day.

        Local rather than UTC because the core's own record is by local day
        (src/poltergeist/daylog.zig), and two records of the same evening that
        disagree about which evening it was are worse than either.
        """
        day = time.strftime("%Y-%m-%d", time.localtime(at_ms / 1000.0))
        return os.path.join(self.directory, day + ".jsonl")

    def handle_for(self, path):
        existing = self.handles.get(path)
        if existing is not None:
            return existing
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        opened = os.fdopen(fd, "a", encoding="utf-8")
        self.handles[path] = opened
        return opened

    def line_for(self, message):
        record = {}
        for name in FIELDS:
            if name in message:
                record[name] = message[name]
        if message.get("summary"):
            record["summary"] = True

        if self.sign_key:
            record["hmac"] = hmac.new(
                self.sign_key, canonical(record), hashlib.sha256
            ).hexdigest()

        return canonical(record).decode("utf-8")

    def write(self, message):
        at_ms = message.get("at_ms")
        if not isinstance(at_ms, int):
            at_ms = int(time.time() * 1000)
        handle = self.handle_for(self.path_for(at_ms))
        handle.write(self.line_for(message) + "\n")

    def commit(self):
        """Make the batch durable before it is acknowledged.

        An acknowledgement is a promise, and a promise about bytes sitting in
        a buffer is one this process can break by exiting.
        """
        for handle in self.handles.values():
            handle.flush()
            os.fsync(handle.fileno())


class Session:
    """The half that is only logic: batch in, acknowledgement out."""

    def __init__(self, journal, acked=0):
        self.journal = journal
        self.acked = acked

    def handle(self, line):
        try:
            batch = json.loads(line)
        except ValueError as err:
            sys.stderr.write("archive: batch is not JSON: %s\n" % err)
            return {"ok": False}

        if not isinstance(batch, dict):
            sys.stderr.write("archive: batch is not an object\n")
            return {"ok": False}

        through = batch.get("through")
        if not isinstance(through, int):
            through = self.acked
        messages = batch.get("messages")
        if not isinstance(messages, list):
            messages = []

        written = None
        try:
            for message in messages:
                if not isinstance(message, dict):
                    continue
                seq = message.get("seq")
                if not isinstance(seq, int):
                    continue
                # Seen already. The host resends a batch it never heard an
                # acknowledgement for, and this is the whole of the defence
                # against that arriving twice in the file.
                if seq <= self.acked:
                    continue
                self.journal.write(message)
                written = seq
            self.journal.commit()
        except (OSError, ValueError) as err:
            sys.stderr.write("archive: could not write: %s\n" % err)
            if written is None:
                return {"ok": False}
            # Some of it landed. Say how far, and never further: the only
            # seqs in reach came out of this batch, and one above `through`
            # would be claiming to have stored something never sent.
            if written > through:
                sys.stderr.write("archive: refusing to claim past the batch\n")
                return {"ok": False}
            # What is being acknowledged has to be on disk before it is
            # acknowledged, and the write that failed left the rest of the
            # batch in a buffer. A commit that fails too means nothing can be
            # promised at all.
            try:
                self.journal.commit()
            except OSError as commit_err:
                sys.stderr.write("archive: could not commit: %s\n" % commit_err)
                return {"ok": False}
            self.acked = written
            return {"ok": True, "cursor": written}

        # The whole batch, so there is nothing to say beyond yes -- the host
        # takes that as everything through `through`, which is what happened.
        if through > self.acked:
            self.acked = through
        return {"ok": True}


def expand(path):
    return os.path.abspath(os.path.expanduser(path))


def directory_from(params):
    configured = params.get("dir")
    if isinstance(configured, str) and configured.strip():
        return expand(configured.strip())

    state = os.environ.get("XDG_STATE_HOME", "").strip()
    if state:
        return expand(os.path.join(state, "polter", "archive"))
    return expand(DEFAULT_DIR)


def greet(line):
    """Read the handshake and answer it. Returns `(session, reply)`.

    **The greeting is answered like everything else.** The host is holding a
    deadline open while it waits for this line; saying nothing is not "still
    starting up", it is a hung plugin, and it is killed and restarted for as
    long as it keeps doing it.

    `(None, {"ok": False})` is the honest answer when there is nowhere to
    write: the host reads it as "not ready, try later" and backs off patiently
    rather than calling it misconduct. What must never happen is answering yes
    and then not storing anything.
    """
    try:
        hello = json.loads(line)
    except ValueError as err:
        sys.stderr.write("archive: handshake is not JSON: %s\n" % err)
        return None, {"ok": False}

    if not isinstance(hello, dict) or "hello" not in hello:
        sys.stderr.write("archive: first line was not a handshake\n")
        return None, {"ok": False}

    params = hello.get("params")
    if not isinstance(params, dict):
        params = {}

    sign_key = params.get("sign_key")
    if not isinstance(sign_key, str):
        sign_key = ""

    directory = directory_from(params)
    try:
        journal = Journal(directory, sign_key)
    except OSError as err:
        sys.stderr.write("archive: cannot use %s: %s\n" % (directory, err))
        return None, {"ok": False}

    cursor = hello.get("cursor")
    return Session(journal, cursor if isinstance(cursor, int) else 0), {"ok": True}


def answer(reply):
    """One acknowledgement, and nothing else ever goes to stdout."""
    sys.stdout.write(json.dumps(reply, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def run():
    first = sys.stdin.readline()
    if not first:
        # The host closed before saying anything. Nothing was promised, so
        # this is not a failure.
        return 0

    session, reply = greet(first)
    answer(reply)
    if session is None:
        return 2

    for line in sys.stdin:
        if not line.strip():
            continue
        answer(session.handle(line))

    return 0


# ---------------------------------------------------------------------------
# Self-test
#
# Everything it writes is under one mkdtemp made before any file is opened, so
# running it leaves nothing behind. It drives the logic half against a real
# directory rather than a stub: the disk is where this plugin's only interesting
# failure lives, and a stub would agree with whatever it was told.
# ---------------------------------------------------------------------------


def self_test():
    import shutil
    import tempfile

    ok = [True]

    def check(name, got, want):
        if got != want:
            ok[0] = False
            sys.stdout.write("FAIL  %s\n  want %r\n  got  %r\n" % (name, want, got))

    root = tempfile.mkdtemp(prefix="polter-archive-selftest-")
    try:
        def message(seq, at_ms=1786819271275, group="build", text="hello"):
            return {
                "seq": seq,
                "at_ms": at_ms,
                "group": group,
                "author": "worker-core",
                "text": text,
            }

        def batch(cursor, through, messages):
            return json.dumps(
                {"cursor": cursor, "through": through, "messages": messages}
            )

        def lines_in(directory, day):
            path = os.path.join(directory, day + ".jsonl")
            if not os.path.exists(path):
                return []
            with open(path, encoding="utf-8") as handle:
                return [json.loads(line) for line in handle if line.strip()]

        day = time.strftime("%Y-%m-%d", time.localtime(1786819271.275))

        # The handshake, first, because getting this one wrong is not a
        # wrong answer -- it is no answer, and the host kills and restarts a
        # plugin that gives none, for as long as it keeps giving none. The
        # bytes below are the shape `Archive.renderHello` writes; the test
        # that feeds this script the *real* ones lives in `Archive.zig`.
        greeted = os.path.join(root, "greeted")
        session, reply = greet(json.dumps({
            "hello": 1,
            "plugin": "archive",
            "cursor": 0,
            "groups": ["*"],
            "params": {"dir": greeted},
        }))
        check("the handshake is acknowledged, not just read", reply, {"ok": True})
        check("and it hands back a session", session is not None, True)

        # A greeting that cannot be honoured still gets an answer: silence is
        # the one reply that is never right, whatever went wrong.
        blocker = os.path.join(root, "blocker")
        with open(blocker, "w", encoding="utf-8") as handle:
            handle.write("not a directory\n")
        blocked, refusal = greet(json.dumps({
            "hello": 1,
            "params": {"dir": os.path.join(blocker, "under-a-file")},
        }))
        check("a greeting it cannot honour is refused out loud", refusal, {"ok": False})
        check("and hands back no session", blocked is None, True)
        check("a first line that is not JSON is refused out loud",
              greet("not json")[1], {"ok": False})
        check("and so is a first line that is not a handshake",
              greet('{"cursor":0,"through":1,"messages":[]}')[1], {"ok": False})

        plain = os.path.join(root, "plain")
        session = Session(Journal(plain))
        check(
            "a batch that lands is acknowledged whole",
            session.handle(batch(0, 3, [message(2), message(3)])),
            {"ok": True},
        )
        check("and both messages are in the day's file", len(lines_in(plain, day)), 2)

        check(
            "a resent batch is acknowledged again",
            session.handle(batch(0, 3, [message(2), message(3)])),
            {"ok": True},
        )
        check(
            "but nothing is written twice",
            len(lines_in(plain, day)),
            2,
        )

        check(
            "a heartbeat with no messages is still an acknowledgement",
            session.handle(batch(3, 3, [])),
            {"ok": True},
        )
        check("and it writes nothing", len(lines_in(plain, day)), 2)

        check(
            "a group filtered out still moves `through` on",
            session.handle(batch(3, 9, [])),
            {"ok": True},
        )
        check(
            "so a message below it is not stored again",
            session.handle(batch(9, 9, [message(5)])),
            {"ok": True},
        )
        check("nothing new landed", len(lines_in(plain, day)), 2)

        check(
            "garbage on stdin is refused, not raised",
            Session(Journal(os.path.join(root, "junk"))).handle("not json"),
            {"ok": False},
        )

        # Two days in one batch: the file is chosen per message, not per
        # batch, so a batch that straddles midnight does not put one day's
        # messages in the other day's file.
        spanning = os.path.join(root, "spanning")
        Session(Journal(spanning)).handle(
            batch(0, 2, [message(1), message(2, at_ms=1786819271275 + 86400 * 1000)])
        )
        other = time.strftime("%Y-%m-%d", time.localtime(1786819271.275 + 86400))
        check("the first day has one line", len(lines_in(spanning, day)), 1)
        check("and so does the next", len(lines_in(spanning, other)), 1)

        # A partial batch: the second message cannot be written, so the
        # answer says how far it got and no further.
        class Failing(Journal):
            def write(self, message):
                if message.get("seq") == 3:
                    raise OSError("no space left on device")
                Journal.write(self, message)

        partial = os.path.join(root, "partial")
        broken = Session(Failing(partial))
        check(
            "a batch that half lands says how far",
            broken.handle(batch(0, 4, [message(2), message(3), message(4)])),
            {"ok": True, "cursor": 2},
        )
        check("and only that much is on disk", len(lines_in(partial, day)), 1)

        class AllFailing(Journal):
            def write(self, message):
                raise OSError("no space left on device")

        none_landed = Session(AllFailing(os.path.join(root, "none")))
        check(
            "a batch that lands nothing is refused rather than claimed",
            none_landed.handle(batch(0, 4, [message(2)])),
            {"ok": False},
        )

        # Signing. The line carries an hmac over everything else in it, and
        # the key is what a verifier needs -- which is why the manifest marks
        # it a credential.
        signed_dir = os.path.join(root, "signed")
        Session(Journal(signed_dir, "a signing key")).handle(
            batch(0, 1, [message(1)])
        )
        signed = lines_in(signed_dir, day)[0]
        digest = signed.pop("hmac", None)
        check(
            "a signed line verifies against the key that wrote it",
            digest,
            hmac.new(
                b"a signing key", canonical(signed), hashlib.sha256
            ).hexdigest(),
        )
        check(
            "and a line edited afterwards does not",
            digest
            == hmac.new(
                b"a signing key",
                canonical(dict(signed, text="something else")),
                hashlib.sha256,
            ).hexdigest(),
            False,
        )

        unsigned = lines_in(plain, day)[0]
        check("without a key there is nothing to verify", "hmac" in unsigned, False)

        # The default the manifest documents and the default this file
        # applies are the same one. Two places saying it is how they drift.
        with open(
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "plugin.json"),
            encoding="utf-8",
        ) as handle:
            manifest = json.load(handle)
        check(
            "the manifest's default directory is the one used",
            manifest["params"]["properties"]["dir"]["default"],
            DEFAULT_DIR,
        )
        check(
            "and the manifest still marks the signing key a credential",
            manifest["params"]["properties"]["sign_key"].get("secret"),
            True,
        )
    finally:
        shutil.rmtree(root, ignore_errors=True)

    if ok[0]:
        sys.stdout.write("ok\n")
    return 0 if ok[0] else 1


def main(argv):
    if not argv:
        return run()
    if argv[0] == "--self-test":
        return self_test()
    sys.stderr.write("archive: unknown argument %s\n" % argv[0])
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
