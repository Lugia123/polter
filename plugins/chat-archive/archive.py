#!/usr/bin/env python3
"""Follow Polter's chat log and copy it somewhere that outlives this machine.

The protocol is one line of JSON in, one line of JSON out: the host greets us
once with `{"hello":1,...,"params":{...}}` and then hands us batches, and every
line it writes gets exactly one acknowledgement. An acknowledgement that names
a cursor is a promise that everything at or below it is stored, so nothing here
ever names a seq that did not come out of the batch in hand -- a number the
host cannot have sent us is the silent hole the whole design exists to prevent.

Design: docs/poltergeist/storage.md. The host side is src/poltergeist/Archive.zig.

Python 3.8, standard library only. Under a Polter launched from the Dock
`/usr/bin/env python3` resolves to the system interpreter -- 3.9 on a stock
macOS -- and not to whatever is on a developer's PATH, so nothing newer is used.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

# Only for the last-resort handler in `Session.handle`. A traceback prints the
# call stack and not the locals, so it cannot spill a parsed value; the one
# exception whose *message* carries the DSN is caught separately, at the parse.
import traceback
import urllib.parse

# ---------------------------------------------------------------------------
# 1. Constants
#
# The manifest declares defaults, but the host does not apply them: it passes
# `settings.params` straight through, so a plugin with no settings file is
# handed `"params":{}`. These are the same values as plugin.json's `default`,
# and the self-test compares the two so they cannot drift apart.
# ---------------------------------------------------------------------------

BACKENDS = ("postgres", "file")

# No default for `backend` and none for `path`, and that absence is the
# design. A `chat-archive` switched on with no parameters used to mean "write
# newline-delimited JSON under the state directory" -- the same shape, in
# another place, as the record Polter itself is already keeping. Silently
# duplicating the core's work is not what a plugin is for, and an archive that
# has to be asked where to write cannot do it by accident.
DEFAULTS = {
    "schema": "public",
    "stream": "default",
}

# `\A ... \Z` rather than `^ ... $` on purpose: `$` also matches just before a
# trailing newline, and a `stream` ending in one would carry that newline into
# psql's `\set`, where it becomes a second line of script.
RE_SCHEMA = re.compile(r"\A[a-z_][a-z0-9_]{0,62}\Z")
RE_STREAM = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
# An export destination: absolute, plain components, and ending in `.jsonl`.
#
# The suffix is not decoration. `path` is a parameter an agent can write and
# what gets written through it is chat text, so an unrestricted path is a way
# from "configure an archive plugin" to appending into ~/.zshrc or
# ~/.ssh/authorized_keys. Requiring the name to end `.jsonl` costs a user
# nothing -- it is what they are producing -- and takes every file that
# matters out of reach. Absolute because a relative path would be resolved
# against whatever directory Polter happened to be started from, which is not
# a place anybody chose.
#
# `..` needs no separate check and does not get one: every component has to
# begin with a letter or a digit, so a component that is `..` -- or `.`, or
# anything hidden -- is not one this pattern can accept. A second check
# would look like it was carrying weight while never once firing.
RE_EXPORT = re.compile(r"\A(?:/[A-Za-z0-9][A-Za-z0-9._-]*)+\.jsonl\Z")

# The host refuses a line longer than this and kills the child for it.
ACK_MAX = 64 * 1024

# One transaction per chunk. A whole batch is at most 256 messages, so this is
# not about size -- it is so the partial-acknowledgement path exists and can be
# tested rather than being a branch nobody has ever run.
CHUNK = 100

# Never configurable. An identifier has no parameter binding and can only be
# pasted into the SQL text, so a configurable table name is an injection
# channel with nothing on the other side of the trade.
TABLE = "polter_chat"

TAIL_BYTES = 64 * 1024

# The host's own ceiling on one batch, from `max_batch` in Archive.zig.
#
# It is how far ahead of the host's cursor this plugin can legitimately be: a
# child killed after a chunk committed but before its acknowledgement was read
# leaves the rows stored and the cursor where it was. Anything past one batch
# is not that, and is worth saying out loud.
HOST_MAX_BATCH = 256

# Where psql is looked for when PATH does not have it. A constant, not a
# setting: this is not a "choose an executable" channel. It exists because a
# Polter launched from the Dock inherits launchd's PATH -- /usr/bin, /bin,
# /usr/sbin, /sbin -- and would otherwise fail on a machine where psql works
# perfectly well in the user's own shell.
PSQL_DIRS = ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin")
PSQL_TREES = (("/Library/PostgreSQL", "", "bin"), ("/usr", "pgsql-", "bin"))

# libpq environment we take charge of. Everything here is cleared before any of
# it is set, so a stray PGDATABASE in the user's environment cannot quietly
# redirect the archive; PGSERVICE goes with them because it can override the
# lot from a file we never looked at.
PG_ENV = (
    ("host", "PGHOST"),
    ("port", "PGPORT"),
    ("user", "PGUSER"),
    ("password", "PGPASSWORD"),
    ("dbname", "PGDATABASE"),
    ("sslmode", "PGSSLMODE"),
    ("connect_timeout", "PGCONNECT_TIMEOUT"),
    ("application_name", "PGAPPNAME"),
)
PG_MANAGED = tuple(v for _, v in PG_ENV) + ("PGSERVICE",)

HELLO_SENTINEL = "<<polter:hello>>"
OK_SENTINEL = "<<polter:ok:"

# Set to a list by --self-test so every acknowledgement can be checked for
# length and line count. None in a real run, so a resident process records
# nothing and grows by nothing.
_ACK_LOG = None


# ---------------------------------------------------------------------------
# 2. Talking to the outside
# ---------------------------------------------------------------------------


def _note(msg):
    """Say one sentence in Polter's log.

    Every sentence this plugin composes goes through here, so that "no
    parameter value ever reaches the log" is a property of one function rather
    than a habit spread over the file. Nothing passed in may be a parsed
    parameter value, or an exception message derived from one: urllib and shlex
    both quote the string they choked on, and that string is the DSN.

    The one other writer is the last-resort `traceback.print_exc` in
    `Session._handle`, and it is deliberate: a traceback prints the call stack
    and not the locals, so it carries no value to spill. Both go through
    `sys.stderr` looked up at call time, which is what lets the self-test swap
    it out and check that no fragment of the DSN reached either.
    """
    try:
        sys.stderr.write("chat-archive: " + msg + "\n")
        sys.stderr.flush()
    except Exception:
        pass


def _emit(text):
    """Write one acknowledgement and flush it.

    Bytes, not text: under a GUI launch LANG is often unset and text-mode stdio
    then picks an ASCII codec, which raises on the first CJK message -- the one
    input this plugin is guaranteed to see.

    The flush is not optional either. `python3 -u` cannot be reached through a
    shebang, and an acknowledgement sitting in a buffer looks exactly like a
    plugin that has stopped answering: the exchange times out and the child is
    killed.
    """
    try:
        sys.stdout.buffer.write(text.encode("utf-8") + b"\n")
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        # The host has gone. Leaving normally would have the interpreter try to
        # flush this same pipe again on the way out and print an "Exception
        # ignored" splatter into Polter's log for it.
        os._exit(0)


def _which(name):
    """PATH lookup. `shutil` is eight lines we do not need to import."""
    for d in (os.environ.get("PATH") or "").split(os.pathsep):
        if not d:
            continue
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def find_psql():
    found = _which("psql")
    if found:
        return found

    for d in PSQL_DIRS:
        p = os.path.join(d, "psql")
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p

    for parent, prefix, sub in PSQL_TREES:
        try:
            names = sorted(os.listdir(parent), reverse=True)
        except OSError:
            continue
        for name in names:
            if not name.startswith(prefix):
                continue
            p = os.path.join(parent, name, sub, "psql")
            if os.path.isfile(p) and os.access(p, os.X_OK):
                return p

    return None


# ---------------------------------------------------------------------------
# 3. Configuration
# ---------------------------------------------------------------------------


class ConfigError(Exception):
    """Something in `params` will not do, and will not fix itself.

    Every message is a static sentence. The value that failed is never in it:
    these go to stderr, stderr is Polter's log, and one of these parameters is
    a database password that arrived here already resolved to plain text.
    """


class Config(object):
    def __init__(self, backend, dsn, schema, stream, export_path, psql):
        self.backend = backend
        self.dsn = dsn
        self.schema = schema
        self.stream = stream
        self.export_path = export_path
        self.psql = psql


def resolve_config(params):
    def get(name):
        v = params.get(name, DEFAULTS.get(name, ""))
        if not isinstance(v, str):
            return DEFAULTS.get(name, "")
        return v.strip()

    # Re-validated here even though plugin.json declares an `enum`, because the
    # enum is enforced by the tool surface and only against literals: a value
    # written as `env:BACKEND` passes that check and arrives here as whatever
    # the environment happened to hold.
    backend = get("backend")
    if backend not in BACKENDS:
        raise ConfigError(
            "the backend parameter is not one this plugin has. It takes "
            "postgres or file."
        )

    schema = get("schema") or DEFAULTS["schema"]
    if not RE_SCHEMA.match(schema):
        raise ConfigError(
            "the schema parameter is not a plain lowercase identifier. It has "
            "to match [a-z_][a-z0-9_]* and be at most 63 characters, because "
            "an identifier cannot be bound as a parameter and is pasted into "
            "the SQL itself."
        )

    stream = get("stream") or DEFAULTS["stream"]
    if not RE_STREAM.match(stream):
        raise ConfigError(
            "the stream parameter has a character in it that is not a letter, "
            "digit, dot, dash or underscore, or it is longer than 64."
        )

    export_path = get("path")
    if backend == "file":
        if not export_path:
            raise ConfigError(
                "the file backend needs a path parameter, and there is none. "
                "It has no default on purpose: Polter already keeps a "
                "readable local record of its own, and a plugin quietly "
                "writing a second copy of it somewhere is not an archive. "
                "Name the file you want exported."
            )
        if not RE_EXPORT.match(export_path):
            raise ConfigError(
                "the path parameter has to be an absolute path whose "
                "components are letters, digits, dot, dash and underscore, "
                "and whose last component ends in .jsonl. That is what this "
                "plugin writes, and the restriction is what keeps a "
                "parameter an agent can set from naming a file that is not "
                "one."
            )
        parent = os.path.dirname(export_path)
        if not os.path.isdir(parent):
            raise ConfigError(
                "the directory the path parameter names is not there. It is "
                "not created here: making directories at a path somebody "
                "else chose is a wider thing to be able to do than writing "
                "the file that was asked for."
            )

    dsn = params.get("dsn", "")
    if not isinstance(dsn, str):
        dsn = ""
    dsn = dsn.strip()

    psql = None
    if backend == "postgres":
        if not dsn:
            raise ConfigError(
                "the postgres backend needs a dsn parameter, and there is "
                "none. Give it as a reference -- env:NAME, keychain:service/"
                "account, or file: under the polter config directory."
            )
        # Parsed now rather than at the first batch: an unparseable DSN is a
        # thing that will not fix itself, and the difference between exit 2 and
        # a patient retry is the whole diagnosis a user gets.
        pg_env(dsn)

        psql = find_psql()
        if psql is None:
            raise ConfigError(
                "psql is not on PATH and is not in any of the usual places "
                "(" + ", ".join(PSQL_DIRS) + ", /Library/PostgreSQL/*/bin, "
                "/usr/pgsql-*/bin). Install the postgres client, or start "
                "Polter from a shell where psql works."
            )

    return Config(backend, dsn, schema, stream, export_path, psql)


# ---------------------------------------------------------------------------
# 4. DSN to libpq environment
# ---------------------------------------------------------------------------


def _parse_dsn(dsn):
    """The DSN as a plain dict of libpq keywords. Raises on anything odd."""
    lowered = dsn.lower()
    if lowered.startswith("postgresql://") or lowered.startswith("postgres://"):
        u = urllib.parse.urlsplit(dsn)
        out = {}
        if u.hostname:
            out["host"] = u.hostname
        if u.port:
            out["port"] = str(u.port)
        if u.username:
            out["user"] = urllib.parse.unquote(u.username)
        if u.password:
            out["password"] = urllib.parse.unquote(u.password)
        path = (u.path or "").lstrip("/")
        if path:
            out["dbname"] = urllib.parse.unquote(path)
        for k, v in urllib.parse.parse_qsl(u.query, keep_blank_values=False):
            out[k] = v
        return out

    if "=" not in dsn:
        raise ValueError("neither a URI nor a conninfo string")

    out = {}
    for token in shlex.split(dsn):
        if "=" not in token:
            raise ValueError("conninfo token without an =")
        k, _, v = token.partition("=")
        out[k.strip()] = v
    return out


def pg_env(dsn):
    """Turn the DSN into an environment for psql.

    Nothing about the connection ever goes into argv. On Linux
    /proc/PID/cmdline is world readable and `ps` shows the whole command line,
    so a password there is a password every account on the machine can read.
    """
    try:
        parsed = _parse_dsn(dsn)
    except Exception:
        # The exception's own text is never shown. urllib and shlex both quote
        # the string they failed on, and that string is the credential.
        raise ConfigError(
            "the dsn parameter is not a postgres URI or conninfo string. It "
            "wants postgresql://user:password@host:5432/dbname, or a "
            "host=... dbname=... line."
        )

    env = os.environ.copy()
    for k in PG_MANAGED:
        env.pop(k, None)

    dropped = False
    known = dict(PG_ENV)
    for k, v in parsed.items():
        name = known.get(k)
        if name is None:
            dropped = True
            continue
        if v is None or v == "":
            continue
        env[name] = str(v)

    if dropped:
        # Naming what was dropped would echo the input, and the input is the
        # credential. Naming what is carried over says the same thing safely.
        _note(
            "the dsn has settings this plugin does not carry over; it uses "
            "host, port, user, password, dbname, sslmode, connect_timeout and "
            "application_name."
        )

    env.setdefault("PGCONNECT_TIMEOUT", "10")
    env.setdefault("PGAPPNAME", "polter-chat-archive")
    return env


# ---------------------------------------------------------------------------
# 5. The backend seam
# ---------------------------------------------------------------------------


class StoreResult(object):
    """What became of one batch.

    `ALL` means **nothing of this batch is outstanding**, not "rows were
    inserted". A replayed batch in which every message is already stored is
    `ALL`. Reading it the other way answers `{"ok":false}` for ever on a
    replay, and a replay is the ordinary path after a handshake rewind: three
    of those is backoff, ten is dormant, and the archive never moves again
    while the log keeps growing.
    """

    ALL = "all"
    PARTIAL = "partial"
    NONE = "none"

    def __init__(self, kind, seq=0):
        self.kind = kind
        self.seq = seq


def make_backend(config):
    if config.backend == "postgres":
        return PgBackend(config)
    return FileBackend(config)


# ---------------------------------------------------------------------------
# 6. The file backend: an export to a file somebody named
# ---------------------------------------------------------------------------


class FileBackend(object):
    """Newline-delimited JSON, appended to the file the `path` parameter names.

    **It writes nowhere by default, and that is the whole of what changed
    about it.** It used to put a file under the state directory whenever the
    plugin was switched on, which was the same shape of data, one directory
    away from the record Polter keeps for itself. Keeping a readable local
    copy is the core's job -- whether there is a record at all must not depend
    on whether some plugin is enabled -- and this plugin's job is getting the
    chat somewhere else: a database, a share, a directory that syncs.

    So the destination is required and is checked in `resolve_config`, which
    is also where the reasoning about what `path` may be lives.
    """

    def __init__(self, config):
        self.config = config
        self.path = config.export_path
        self.fd = None
        self.written_through = 0

    def open(self):
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            size = os.lseek(fd, 0, os.SEEK_END)
            tail = b""
            if size:
                start = max(0, size - TAIL_BYTES)
                os.lseek(fd, start, os.SEEK_SET)
                chunks = []
                want = size - start
                while want > 0:
                    got = os.read(fd, want)
                    if not got:
                        break
                    chunks.append(got)
                    want -= len(got)
                tail = b"".join(chunks)

                if not tail.endswith(b"\n"):
                    # A record torn by a crash. Left alone it would concatenate
                    # into the next one and take both records out rather than
                    # one.
                    cut = tail.rfind(b"\n")
                    if cut >= 0:
                        os.ftruncate(fd, start + cut + 1)
                        tail = tail[: cut + 1]
                    elif start == 0:
                        os.ftruncate(fd, 0)
                        tail = b""
                    else:
                        _note(
                            "the archive file ends in a record longer than the "
                            "tail this plugin reads; it was left alone and this "
                            "run starts from nothing it can see."
                        )
                        tail = b""

            self.written_through = _last_seq(tail)
            os.lseek(fd, 0, os.SEEK_END)
        except Exception:
            os.close(fd)
            raise

        self.fd = fd

    def hello(self, host_cursor):
        return self.written_through

    def heartbeat(self):
        pass

    def store(self, before, through, messages):
        if self.fd is None:
            return StoreResult(StoreResult.NONE)

        for m in messages:
            seq = m["seq"]
            if seq <= self.written_through:
                continue
            row = {
                "stream": self.config.stream,
                "seq": seq,
                "at_ms": m["at_ms"],
                "group": m["group"],
                "author": m["author"],
                "summary": m["summary"],
                "text": m["text"],
            }
            line = json.dumps(row, ensure_ascii=True) + "\n"
            try:
                os.write(self.fd, line.encode("utf-8"))
                os.fsync(self.fd)
            except Exception:
                _note("a record would not be written to the archive file.")
                return StoreResult(StoreResult.NONE)

            # Advanced as each line lands rather than once at the end. A
            # failure halfway answers `{"ok":false}` and the host resends the
            # whole batch; the prefix already on disk has to be skipped then,
            # or the dedupe this backend exists to have does the opposite of
            # its job.
            self.written_through = seq

        return StoreResult(StoreResult.ALL)

    def close(self):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except Exception:
                pass
            self.fd = None


def _last_seq(tail):
    """The seq of the last line that parses, or 0."""
    for raw in reversed(tail.split(b"\n")):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw.decode("utf-8"))
        except Exception:
            continue
        seq = row.get("seq") if isinstance(row, dict) else None
        if isinstance(seq, int) and not isinstance(seq, bool) and seq > 0:
            return seq
    return 0


# ---------------------------------------------------------------------------
# 7. The postgres backend
# ---------------------------------------------------------------------------


def render_ddl(schema):
    return (
        'CREATE SCHEMA IF NOT EXISTS "{s}";\n'
        "\n"
        'CREATE TABLE IF NOT EXISTS "{s}".{t} (\n'
        "  stream     text        NOT NULL,\n"
        "  seq        bigint      NOT NULL,\n"
        "  at_ms      bigint      NOT NULL,\n"
        '  "group"    text        NOT NULL,\n'
        "  author     text        NOT NULL,\n"
        "  summary    boolean     NOT NULL DEFAULT false,\n"
        "  text       text        NOT NULL,\n"
        "  stored_at  timestamptz NOT NULL DEFAULT now(),\n"
        "  PRIMARY KEY (stream, seq)\n"
        ");\n"
        "\n"
        "CREATE INDEX IF NOT EXISTS {t}_group_seq\n"
        '  ON "{s}".{t} ("group", seq);\n'
    ).format(s=schema, t=TABLE)


class PgBackend(object):
    """One long-lived psql, fed SQL on its stdin, read back by sentinel.

    One psql per batch would be one psql per message: in the steady state the
    host polls every 500ms and a batch is usually a single line, so "per batch"
    and "per message" are the same thing, and building a TLS connection for
    each is what the resident design exists to avoid.

    Two states and no others: psql is alive or it is not. `ON_ERROR_STOP=1`
    ends it on any SQL error, we see the pipe close, and the next batch builds
    a fresh one.
    """

    def __init__(self, config):
        self.config = config
        self.proc = None

        # What MAX(seq) said when this backend was opened. Set here as well so
        # that a `hello` reaching a backend whose `open` raised answers "I
        # cannot say" -- which keeps the host's cursor -- rather than dying on
        # a missing attribute.
        self._max_at_open = None

    # -- process ------------------------------------------------------------

    def _spawn(self):
        argv = [
            self.config.psql,
            # Never prompt for a password: there is no controlling tty here,
            # and a psql waiting on one is an exchange that ends in a kill.
            "-w",
            "--no-psqlrc",
            "-q",
            "-A",
            "-t",
            "-v",
            "ON_ERROR_STOP=1",
            # terse drops the DETAIL and CONTEXT lines, and those are the ones
            # that quote COPY data back -- which here is chat text, on its way
            # into Polter's log.
            "-v",
            "VERBOSITY=terse",
            "-f",
            "-",
        ]
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            # Not optional. An inherited stdout puts psql's output into the
            # protocol channel, and the host judges any line that is not an
            # acknowledgement as misconduct and kills the child.
            stdout=subprocess.PIPE,
            # Inherited on purpose: this is Polter's log, and it is where psql
            # gets to say what went wrong.
            stderr=None,
            env=pg_env(self.config.dsn),
        )

    def _teardown(self):
        p = self.proc
        self.proc = None
        if p is None:
            return
        try:
            if p.stdin is not None:
                p.stdin.close()
        except Exception:
            pass
        try:
            p.wait(timeout=5)
            return
        except Exception:
            pass
        try:
            p.kill()
        except Exception:
            pass
        try:
            # Reaped, always. One unwaited psql per failure is one zombie per
            # failure over a run that is meant to last a month.
            p.wait(timeout=5)
        except Exception:
            pass

    def _write(self, script):
        # psql runs meta-command arguments through a shell for backticks, so a
        # backtick reaching `\set` would be command substitution in our own
        # process tree. `stream` is regex-validated for that reason and not for
        # tidiness; this is the belt to that pair of braces.
        assert "`" not in script, "a rendered script must not contain a backtick"
        self.proc.stdin.write(script.encode("utf-8"))
        self.proc.stdin.flush()

    def _read_to(self, sentinel):
        """Lines up to the sentinel, or None if psql went away first."""
        out = []
        while True:
            raw = self.proc.stdout.readline()
            if not raw:
                return None
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if line.startswith(sentinel):
                return out
            out.append(line)

    # -- protocol -----------------------------------------------------------

    def _handshake_script(self):
        s = self.config.schema
        return (
            "\\set stream '" + self.config.stream + "'\n"
            "SET client_min_messages = warning;\n"
            "SET statement_timeout = '20s';\n"
            "SET lock_timeout = '5s';\n"
            "BEGIN;\n" + render_ddl(s) + "COMMIT;\n"
            'SELECT COALESCE(MAX(seq), 0) FROM "'
            + s
            + '".'
            + TABLE
            + " WHERE stream = :'stream';\n"
            "\\echo " + HELLO_SENTINEL + "\n"
        )

    def _ensure(self):
        """A live psql that has run the DDL, or an exception."""
        if self.proc is not None and self.proc.poll() is None:
            return None
        self._teardown()
        self._spawn()
        self._write(self._handshake_script())
        lines = self._read_to(HELLO_SENTINEL)
        if lines is None:
            self._teardown()
            raise IOError("psql did not get as far as saying hello")
        return _last_number(lines)

    def open(self):
        self._max_at_open = self._ensure()

    def hello(self, host_cursor):
        return self._max_at_open

    def heartbeat(self):
        # Costs nothing and touches no database: it only collects a psql that
        # has already exited, so the corpse does not wait for the next batch.
        if self.proc is not None and self.proc.poll() is not None:
            self._teardown()

    def store(self, before, through, messages):
        try:
            self._ensure()
        except Exception:
            _note("psql would not start or would not build the table.")
            self._teardown()
            return StoreResult(StoreResult.NONE)

        committed = 0
        for i in range(0, len(messages), CHUNK):
            chunk = messages[i : i + CHUNK]
            last = chunk[-1]["seq"]
            try:
                script = self._batch_script(chunk, last)
                self._write(script)
                got = self._read_to(OK_SENTINEL)
            except Exception:
                got = None

            if got is None:
                # ON_ERROR_STOP fired, or the pipe went. Either way psql is
                # gone and has to be collected before the next attempt.
                self._teardown()
                if committed:
                    return StoreResult(StoreResult.PARTIAL, committed)
                return StoreResult(StoreResult.NONE)

            committed = last

        return StoreResult(StoreResult.ALL)

    def _batch_script(self, chunk, last):
        doc = {"messages": chunk}
        rendered = json.dumps(doc, ensure_ascii=True)

        # COPY TEXT escaping, and doubling the backslash is the whole of it.
        # The round trip: a backslash in the text becomes `\\` on the wire,
        # COPY turns it back into one backslash, and jsonb then reads the JSON
        # escape it was part of. `ensure_ascii=True` is what makes that
        # sufficient -- it guarantees the rendering holds no raw control
        # character, so there is nothing else COPY could misread.
        data = rendered.replace("\\", "\\\\")

        # If that guarantee ever broke, the right answer is `{"ok":false}` and
        # a retry, not a row with a newline in it -- a data line reading exactly
        # `\.` would end the COPY early and hand the rest of the chat text to
        # psql as SQL.
        if "\n" in data or "\r" in data or "\t" in data:
            raise ValueError("the rendered COPY line is not one line")

        s = self.config.schema
        return (
            "BEGIN;\n"
            "CREATE TEMP TABLE polter_in (doc text) ON COMMIT DROP;\n"
            "COPY polter_in (doc) FROM STDIN;\n" + data + "\n"
            "\\.\n"
            'INSERT INTO "' + s + '".' + TABLE + " (stream, seq, at_ms, "
            '"group", author, summary, text)\n'
            "SELECT :'stream', (m->>'seq')::bigint, (m->>'at_ms')::bigint, "
            "m->>'group', m->>'author', "
            "COALESCE((m->>'summary')::boolean, false), m->>'text'\n"
            "FROM polter_in, LATERAL jsonb_array_elements(doc::jsonb -> "
            "'messages') AS m\n"
            "ON CONFLICT (stream, seq) DO NOTHING;\n"
            "COMMIT;\n"
            "\\echo " + OK_SENTINEL + str(last) + ">>\n"
        )

    def close(self):
        self._teardown()


def _last_number(lines):
    for line in reversed(lines):
        t = line.strip()
        if not t:
            continue
        try:
            return int(t)
        except ValueError:
            continue
    return None


# ---------------------------------------------------------------------------
# 8. The protocol layer
# ---------------------------------------------------------------------------


def _int(v, fallback=0):
    if isinstance(v, bool) or not isinstance(v, int):
        return fallback
    return v


def _clean(messages):
    """The batch as rows we can store, or None if one of them will not do.

    Only `seq` has to be right, because `seq` is the thing an acknowledgement
    is a promise about. The rest is coerced: being strict there would stall the
    archive over a field nobody reads, and a stall is the failure this design
    is most concerned with.
    """
    out = []
    for m in messages:
        if not isinstance(m, dict):
            return None
        seq = m.get("seq")
        if isinstance(seq, bool) or not isinstance(seq, int) or seq <= 0:
            return None
        out.append(
            {
                "seq": seq,
                "at_ms": _int(m.get("at_ms")),
                "group": m.get("group") if isinstance(m.get("group"), str) else "",
                "author": m.get("author") if isinstance(m.get("author"), str) else "",
                "summary": m.get("summary") is True,
                "text": m.get("text") if isinstance(m.get("text"), str) else "",
            }
        )

    # Kept-first dedupe. The host does not send a seq twice in one batch; this
    # is free and means the SQL never leans on what PostgreSQL does with two
    # conflicting rows inside a single INSERT.
    seen = set()
    unique = []
    for row in out:
        if row["seq"] in seen:
            continue
        seen.add(row["seq"])
        unique.append(row)
    return unique


class Session(object):
    """One conversation with the host. Returns lines; never touches stdio.

    That separation is the seam the self-test drives: everything below can be
    exercised without a pipe, a database, or a Polter.
    """

    def __init__(self, factory=None):
        self.factory = factory or make_backend
        self.config = None
        self.backend = None

        # Set when the right thing to do after this acknowledgement is to go
        # away quietly rather than keep reading.
        self.finished = False

    def handle(self, line):
        ack = self._handle(line)

        # Not reachable with the acknowledgements written above, which is
        # exactly why it is worth having: it fails the day somebody puts a
        # message, or an error string, into one. Over 64KB or holding a newline
        # is misconduct and gets the child killed.
        if "\n" in ack or "\r" in ack or len(ack.encode("utf-8")) >= ACK_MAX:
            _note("an acknowledgement came out malformed and was replaced.")
            ack = '{"ok":false}'

        if _ACK_LOG is not None:
            _ACK_LOG.append(ack)
        return ack

    def _handle(self, line):
        try:
            obj = json.loads(line)
        except Exception:
            _note("a line from the host was not JSON; it was refused.")
            return '{"ok":false}'

        if not isinstance(obj, dict):
            _note("a line from the host was not an object; it was refused.")
            return '{"ok":false}'

        try:
            if "hello" in obj:
                return self._hello(obj)
            return self._batch(obj)
        except SystemExit:
            raise
        except Exception:
            # The stack, not the values. Tracebacks do not print locals, so
            # this cannot spill a parameter -- and the one exception whose
            # message carries the DSN was caught at the parse, in `pg_env`.
            traceback.print_exc(file=sys.stderr)
            return '{"ok":false}'

    # -- handshake ----------------------------------------------------------

    def _hello(self, obj):
        params = obj.get("params")
        if not isinstance(params, dict):
            params = {}

        host_cursor = _int(obj.get("cursor"))
        if host_cursor < 0:
            host_cursor = 0

        try:
            self.config = resolve_config(params)
        except ConfigError as e:
            # The host cannot see an exit code, so this one line is the whole
            # diagnosis anybody will ever get. Exit 2 rather than answer:
            # nothing here fixes itself by being retried.
            _note(str(e))
            sys.exit(2)

        try:
            self.backend = self.factory(self.config)
            self.backend.open()
            ours = self.backend.hello(host_cursor)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            _note("the backend would not open; the host will try again later.")
            # Not misconduct -- the host reads a false greeting as "later", not
            # as a lie -- and exiting cleanly keeps the log free of a kill.
            self.finished = True
            return '{"ok":false}'

        if ours is None:
            return '{"ok":true}'
        if not isinstance(ours, int) or isinstance(ours, bool) or ours < 0:
            _note("the backend gave a position that is not a number.")
            return '{"ok":true}'

        if ours > host_cursor + HOST_MAX_BATCH:
            # What a wiped $XDG_STATE_HOME looks like, and what dotfiles copied
            # to a second machine look like: the log restarts at seq 1 while
            # the database still holds the old machine's rows, and ON CONFLICT
            # DO NOTHING then drops every new message without a word.
            #
            # A whole batch of slack, because being a little ahead is the
            # ordinary shape of a child that was killed mid-batch, and this
            # sentence says the archive is silently losing messages. Said on
            # that path it is a false alarm, and a false alarm is how the real
            # one gets read past.
            #
            # The stream is named as "the configured stream" and never by its
            # value: this goes to Polter's log, and no parameter value does.
            _note(
                "the configured stream already holds messages past where this "
                "machine's log has got to. If the local log was wiped, or "
                "these settings came from another machine, give this one its "
                "own stream -- otherwise the primary key will drop the new "
                "messages and nothing will say so."
            )

        if ours >= host_cursor:
            # Forwards is a violation and gets the child killed, so there is
            # nothing to say here at all.
            return '{"ok":true}'

        if not 0 <= ours < host_cursor:
            _note("a rewind came out wrong and was dropped; the host keeps its position.")
            return '{"ok":true}'

        return '{"ok":true,"cursor":%d}' % ours

    # -- batches ------------------------------------------------------------

    def _batch(self, obj):
        messages = obj.get("messages")
        if not isinstance(messages, list):
            _note("a batch had no messages array; it was refused.")
            return '{"ok":false}'

        if not messages:
            # A heartbeat wants one thing: that we are still here and still
            # listening. Reaching for the database to answer it would turn a
            # network hiccup into a restart.
            if self.backend is not None:
                try:
                    self.backend.heartbeat()
                except Exception:
                    pass
            return '{"ok":true}'

        if self.backend is None:
            _note("a batch arrived before the greeting; it was refused.")
            return '{"ok":false}'

        rows = _clean(messages)
        if rows is None:
            _note("a batch held a message without a usable seq; it was refused.")
            return '{"ok":false}'

        before = _int(obj.get("cursor"))

        # Missing or unreadable falls back to the last message's seq, which is
        # the smallest value the protocol allows `through` to have. It is never
        # raised past what the host said: `through` is the ceiling a partial
        # acknowledgement is checked against, and a ceiling we lifted ourselves
        # would let us name a position the host never sent -- which is the one
        # claim it kills a child for.
        through = _int(obj.get("through"), rows[-1]["seq"])
        if through < rows[-1]["seq"]:
            _note(
                "a batch named a last-seen position behind its own last "
                "message; it was refused rather than guessed at."
            )
            return '{"ok":false}'

        res = self.backend.store(before, through, rows)

        if res.kind == StoreResult.ALL:
            # No cursor: the host reads that as the whole batch, which is what
            # `through` is for -- it can be past the last message we were shown
            # when groups filtered the tail away.
            return '{"ok":true}'

        if res.kind == StoreResult.PARTIAL:
            seq = res.seq
            # Both bounds. Over `through` is a violation, under the pre-batch
            # cursor is a violation too, and equal to it is read as "still
            # standing here" and burns a soft failure.
            ok = (
                isinstance(seq, int)
                and not isinstance(seq, bool)
                and before < seq <= through
            )
            if not ok:
                # The number itself is not repeated anywhere: a backend that
                # claims a position it cannot have does not get that claim
                # written into the log either.
                _note(
                    "the backend named a position outside the batch it was "
                    "given, so the batch is reported as not stored."
                )
                return '{"ok":false}'
            return '{"ok":true,"cursor":%d}' % seq

        return '{"ok":false}'

    def close(self):
        if self.backend is not None:
            try:
                self.backend.close()
            except Exception:
                pass
            self.backend = None


# ---------------------------------------------------------------------------
# 9. main
# ---------------------------------------------------------------------------


def run():
    session = Session()
    try:
        while True:
            raw = sys.stdin.buffer.readline()
            if not raw:
                # The host closed the pipe. Nothing is wrong.
                break
            line = raw.decode("utf-8", "replace")
            _emit(session.handle(line))
            if session.finished:
                break
    finally:
        session.close()
    return 0


USAGE = (
    "usage: archive.py [--self-test [--backend postgres] | --print-schema]\n"
    "\n"
    "With no arguments it speaks the archive protocol on stdin and stdout,\n"
    "which is how Polter runs it. Polter never passes arguments.\n"
)


def main(argv):
    if not argv:
        return run()

    if argv == ["--print-schema"]:
        sys.stdout.write(render_ddl(DEFAULTS["schema"]))
        return 0

    if argv == ["--self-test"]:
        return self_test(False)

    if argv == ["--self-test", "--backend", "postgres"]:
        return self_test(True)

    sys.stderr.write(USAGE)
    return 2


# ---------------------------------------------------------------------------
# 10. The self-test
# ---------------------------------------------------------------------------


def _fail(name, expected, got):
    sys.stdout.write("FAIL  " + name + "\n")
    sys.stdout.write("  expected: " + repr(expected) + "\n")
    sys.stdout.write("  got:      " + repr(got) + "\n")
    sys.exit(1)


def _eq(name, got, expected):
    if got != expected:
        _fail(name, expected, got)
    sys.stdout.write("ok  " + name + "\n")


def _hello_line(cursor, params):
    return json.dumps(
        {"hello": 1, "plugin": "chat-archive", "cursor": cursor, "groups": ["*"], "params": params}
    )


def _batch_line(cursor, through, messages):
    return json.dumps({"cursor": cursor, "through": through, "messages": messages})


def _msg(seq, text="hi", group="build", author="worker", at_ms=1786819271275):
    return {"seq": seq, "at_ms": at_ms, "group": group, "author": author, "text": text}


def _lines(path):
    if not os.path.exists(path):
        return []
    with open(path, "rb") as f:
        return [l for l in f.read().split(b"\n") if l.strip()]


class _Capture(object):
    """Swap stderr for something we can read back.

    It catches everything because both writers -- `_note` and the last-resort
    `traceback.print_exc` -- look stderr up on `sys` when they are called
    rather than holding on to the object. That is what makes "no fragment of
    the DSN reached the log" a claim about the log and not just about `_note`,
    and it is also why a case that drives a raising backend does not splatter
    a traceback through this output.
    """

    def __init__(self):
        self.buf = []

    def write(self, s):
        self.buf.append(s)

    def flush(self):
        pass

    def text(self):
        return "".join(self.buf)


class _Stub(object):
    """A backend that stores nothing, for driving `Session` without storage."""

    def __init__(self, config):
        self.config = config

    def open(self):
        pass

    def hello(self, host_cursor):
        return None

    def heartbeat(self):
        pass

    def store(self, before, through, messages):
        raise AssertionError("this stub was not meant to be asked to store")

    def close(self):
        pass


class _Liar(_Stub):
    def store(self, before, through, messages):
        return StoreResult(StoreResult.PARTIAL, through + 5)


class _Thrower(_Stub):
    def store(self, before, through, messages):
        raise RuntimeError("the backend is having a day")


def _claiming(seq):
    """A backend that stored part of a batch and says it got as far as `seq`."""

    class _Partial(_Stub):
        def store(self, before, through, messages):
            return StoreResult(StoreResult.PARTIAL, seq)

    return _Partial


def self_test(with_postgres):
    global _ACK_LOG

    # First, before anything else can open a file: every destination in here
    # is under a fresh temporary directory.
    #
    # This used to also point `XDG_STATE_HOME` at the temporary directory,
    # because the file backend derived its own path from it. It no longer
    # derives anything -- the destination is a parameter now -- so that line
    # went with it rather than staying on as a guard against nothing.
    tmp = tempfile.mkdtemp(prefix="polter-chat-archive-")
    exports = os.path.join(tmp, "exports")
    os.makedirs(exports, 0o700)
    _ACK_LOG = []

    def _p(name):
        return os.path.join(exports, name)

    def params(name, backend="file"):
        return {"backend": backend, "path": _p(name), "stream": "selftest"}

    p1 = _p("t1.jsonl")

    # 1
    s = Session()
    _eq(
        "a handshake on an empty backend keeps the host's cursor",
        s.handle(_hello_line(0, params("t1.jsonl"))),
        '{"ok":true}',
    )

    # 2
    batch = _batch_line(0, 5, [_msg(3), _msg(5)])
    ack = s.handle(batch)
    _eq("a batch is stored and acknowledged", (ack, len(_lines(p1))), ('{"ok":true}', 2))

    # 3
    ack = s.handle(batch)
    _eq(
        "a replayed batch is acknowledged and stored once",
        (ack, len(_lines(p1))),
        ('{"ok":true}', 2),
    )

    # 4
    real = s.backend.store

    def _boom(*a, **k):
        raise AssertionError("a heartbeat reached the backend")

    s.backend.store = _boom
    ack = s.handle(_batch_line(5, 5, []))
    s.backend.store = real
    _eq("a heartbeat is answered without the backend", ack, '{"ok":true}')
    s.close()

    # 5
    s = Session()
    _eq(
        "a handshake rewinds a cursor that ran ahead",
        s.handle(_hello_line(99, params("t1.jsonl"))),
        '{"ok":true,"cursor":5}',
    )
    s.close()

    # 6
    s = Session()
    ack = s.handle(_hello_line(2, params("t1.jsonl")))
    _eq(
        "a handshake behind ours is answered without a cursor",
        (ack, "5" in ack),
        ('{"ok":true}', False),
    )
    s.close()

    # 7
    s = Session()
    s.handle(_hello_line(0, params("t7.jsonl")))
    _eq(
        "a batch is taken whole past its last message",
        s.handle(_batch_line(0, 12, [_msg(7)])),
        '{"ok":true}',
    )
    s.close()

    # 8
    cap = _Capture()
    saved = sys.stderr
    sys.stderr = cap
    try:
        s = Session(factory=_Liar)
        s.handle(_hello_line(0, params("t8.jsonl")))
        ack = s.handle(_batch_line(0, 10, [_msg(3)]))
        s.close()
    finally:
        sys.stderr = saved
    _eq(
        "a backend that claims too much is not believed",
        (ack, "15" in ack, "15" in cap.text()),
        ('{"ok":false}', False, False),
    )

    # 8b -- the other half of case 8, and the half that stalls the archive when
    # it is wrong. A liar being refused proves the assertion fires; it does not
    # prove the assertion lets an honest partial through. Tightened by one
    # character -- `< through` where it says `<= through` -- every partial
    # store would answer `{"ok":false}`, which the host reads as "still
    # standing here": three of them is backoff, ten is dormant, and nothing
    # anywhere reports an error while the log keeps growing.
    saved = sys.stderr
    sys.stderr = _Capture()
    try:
        acks = []
        for claim in (7, 12, 5, 13, 4):
            s = Session(factory=_claiming(claim))
            s.handle(_hello_line(0, params("t8b.jsonl")))
            acks.append(s.handle(_batch_line(5, 12, [_msg(7), _msg(12)])))
            s.close()
    finally:
        sys.stderr = saved
    _eq(
        "an honest partial is taken, and only between the two bounds",
        acks,
        [
            # Inside the batch, and exactly at `through`: both are positions
            # the host itself named, so both are ours to confirm.
            '{"ok":true,"cursor":7}',
            '{"ok":true,"cursor":12}',
            # Exactly the pre-batch cursor. The host reads that as no progress
            # and burns a soft failure for it, so `{"ok":false}` says the same
            # thing without the pretence.
            '{"ok":false}',
            # Past `through`, and behind the pre-batch cursor. Each is a claim
            # the host kills a child for, so neither is worth making.
            '{"ok":false}',
            '{"ok":false}',
        ],
    )

    # 9
    saved = sys.stderr
    sys.stderr = _Capture()
    try:
        s = Session(factory=_Thrower)
        s.handle(_hello_line(0, params("t9.jsonl")))
        first = s.handle(_batch_line(0, 10, [_msg(3)]))
        second = s.handle(_batch_line(0, 10, []))
        s.close()
    finally:
        sys.stderr = saved
    _eq(
        "a backend that raises leaves the stream alive",
        (first, second),
        ('{"ok":false}', '{"ok":true}'),
    )

    # 10
    saved = sys.stderr
    sys.stderr = _Capture()
    try:
        s = Session()
        s.handle(_hello_line(0, params("t10.jsonl")))
        first = s.handle("this is not json {")
        second = s.handle(_batch_line(0, 0, []))
        s.close()
    finally:
        sys.stderr = saved
    _eq(
        "a line that is not JSON is refused and the loop lives",
        (first, second),
        ('{"ok":false}', '{"ok":true}'),
    )

    # 11
    odd = "\u4e2d\u6587 \"quoted\" back\\slash\nsecond line\ttab \u00e9"
    p11 = _p("t11.jsonl")
    s = Session()
    s.handle(_hello_line(0, params("t11.jsonl")))
    s.handle(_batch_line(0, 1, [_msg(1, text=odd)]))
    s.close()
    stored = json.loads(_lines(p11)[0].decode("utf-8"))
    _eq(
        "text survives the round trip byte for byte",
        (stored["text"], len(_lines(p11))),
        (odd, 1),
    )

    # 12
    worst = max(len(a.encode("utf-8")) for a in _ACK_LOG)
    multi = [a for a in _ACK_LOG if "\n" in a or "\r" in a]
    _eq(
        "every acknowledgement is one short line",
        (worst < ACK_MAX, multi, len(_ACK_LOG) >= 12),
        (True, [], True),
    )

    # 13 -- the manifest is not decoration. `"secret": true` on `dsn` is the
    # only thing that makes the tool surface refuse a plaintext password for
    # this plugin, and a non-bool there reads as false and says nothing.
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "plugin.json"), "rb") as f:
        manifest = json.loads(f.read().decode("utf-8"))
    props = manifest["params"]["properties"]
    _eq(
        "the manifest agrees with the validator",
        (
            manifest["key"],
            manifest["kind"],
            manifest["exec"],
            manifest["wants"]["groups"],
            props["schema"].get("default"),
            props["stream"].get("default"),
            # No default for either, and the manifest has to agree: a default
            # here is what would let the plugin pick a destination nobody
            # asked for, which is the thing this backend stopped doing.
            props["backend"].get("default"),
            props["path"].get("default"),
            props["dsn"].get("secret") is True,
            tuple(props["backend"].get("enum", ())),
            tuple(manifest["params"].get("required", ())),
        ),
        (
            "chat-archive",
            "archive",
            "archive.py",
            ["*"],
            DEFAULTS["schema"],
            DEFAULTS["stream"],
            None,
            None,
            True,
            BACKENDS,
            ("backend",),
        ),
    )

    # 14
    bad = ["../x", "a/b", ".hidden", "a`b", "x" * 200, "ok\n", "", "/etc/passwd"]
    leaks = []
    for pattern in (RE_SCHEMA, RE_STREAM):
        for v in bad:
            if pattern.match(v):
                leaks.append(v)

    # The export path takes its own list: it is the one parameter that is
    # meant to hold slashes, so "refuses a path" is not what is being asked
    # of it. What is being asked is that it only ever names a `.jsonl` --
    # every entry below is a file somebody would mind having chat appended
    # to, and the last two are the shapes that get past a naive suffix test.
    for v in bad + [
        "relative/x.jsonl",
        "/home/u/.ssh/authorized_keys",
        "/home/u/.zshrc",
        "/home/u/x.jsonl.sh",
        "/home/u/.jsonl",
    ]:
        if RE_EXPORT.match(v):
            leaks.append(v)

    # And the positive half, because a pattern that matches nothing would
    # pass every line above while making the backend unusable.
    _eq(
        "the name patterns refuse a path, and the export path refuses a file",
        (
            leaks,
            bool(RE_STREAM.match("default")),
            bool(RE_SCHEMA.match("public")),
            bool(RE_EXPORT.match("/home/u/archive/chat.jsonl")),
        ),
        ([], True, True, True),
    )

    # 15 -- the one failure that looks healthy. A wiped state directory, or
    # one settings file synced to a second machine, has the log restart at
    # seq 1 while the database still holds the old rows, and ON CONFLICT DO
    # NOTHING then drops every new message silently. The warning is the only
    # thing that ever says so, which makes both halves worth pinning: that it
    # fires on a real gap, and that it stays quiet for a child killed
    # mid-batch -- being a batch ahead is ordinary, and a sentence this
    # alarming spent on an ordinary event is one nobody reads the next time.
    def _greet(name, cursor):
        cap = _Capture()
        saved = sys.stderr
        sys.stderr = cap
        try:
            s = Session()
            s.handle(_hello_line(cursor, params(name)))
            s.close()
        finally:
            sys.stderr = saved
        return cap.text()

    s = Session()
    s.handle(_hello_line(0, params("t15.jsonl")))
    s.handle(_batch_line(0, 1000, [_msg(1000)]))
    s.close()

    wiped = _greet("t15.jsonl", 0)
    ordinary = _greet("t1.jsonl", 0)
    _eq(
        "a database further along than the log is called out, and only then",
        (
            "already holds messages" in wiped,
            "already holds messages" in ordinary,
            "selftest" in wiped,
        ),
        (True, False, False),
    )

    # 16 -- case 14 pins the patterns; this pins that `resolve_config` is
    # wired to them, which is the half that can rot without anything saying
    # so. Take the `path` check out and every other case here stays green
    # while `path: "/home/u/.ssh/authorized_keys"` gets chat text appended
    # to it -- `path` is a parameter an agent can set, and what is written
    # through it is the chat log.
    #
    # Two of the cases below are about the absence of a default rather than
    # about a bad value: no `path` at all, and a `path` whose directory is
    # not there. Both used to be answered by picking somewhere, and both
    # have to be refusals now.
    #
    # The exit code is pinned too. These do not come right by being retried,
    # and exit 2 is what puts the sentence in front of somebody instead of a
    # patient retry that never ends.
    escaped = os.path.join(tmp, "zqescaped.jsonl")
    codes = []
    said = []
    for bad in (
        {"backend": "zqbackend"},
        {"backend": "postgres"},
        {"backend": "file", "schema": "zqSCHEMA"},
        {"backend": "file", "stream": "zqstream'x", "path": _p("t1.jsonl")},
        {"backend": "file", "path": os.path.join(exports, "..", "zqescaped.jsonl")},
        # No destination at all, which used to mean "the state directory".
        {"backend": "file"},
        # A directory nobody made. Refused rather than created.
        {"backend": "file", "path": os.path.join(tmp, "zqnodir", "x.jsonl")},
    ):
        cap = _Capture()
        saved = sys.stderr
        sys.stderr = cap
        try:
            Session().handle(_hello_line(0, bad))
            codes.append(None)
        except SystemExit as e:
            codes.append(e.code)
        finally:
            sys.stderr = saved
        said.append(cap.text())
    _eq(
        "a parameter that will not do exits, and says so without quoting it",
        (
            codes,
            os.path.exists(escaped),
            # One sentence each, and not one of them holding the value that
            # failed. Every marker here starts `zq` so a substring search can
            # decide it: this goes to Polter's log, and one of these
            # parameters arrives as a database password in plain text.
            [len(t.strip().split("\n")) for t in said],
            [t for t in said if "zq" in t],
        ),
        ([2, 2, 2, 2, 2, 2, 2], False, [1, 1, 1, 1, 1, 1, 1], []),
    )

    if with_postgres:
        pg_self_test(tmp)

    return 0


# The fake psql, written at runtime into a temp directory and never into the
# repository: `plugins/` is installed into the app bundle whole (only `.md` is
# left out), and a file called `psql` shipped to users is not a thing to have
# even when it is harmless.
FAKE_PSQL = r'''#!/usr/bin/env python3
import json, os, sys

d = os.environ["POLTER_FAKE_DIR"]
with open(os.path.join(d, "argv.json"), "w") as f:
    json.dump(sys.argv, f)
with open(os.path.join(d, "env.json"), "w") as f:
    json.dump(dict((k, v) for k, v in os.environ.items() if k.startswith("PG")), f)

maxseq = os.environ.get("POLTER_FAKE_MAXSEQ", "0")

# How many chunks to see through before vanishing mid-script, which is what
# ON_ERROR_STOP=1 looks like from the other end of the pipe. 0 means never.
limit = int(os.environ.get("POLTER_FAKE_OK_LIMIT", "0"))
done = 0

rec = open(os.path.join(d, "stdin.txt"), "ab")
while True:
    raw = sys.stdin.buffer.readline()
    if not raw:
        break
    rec.write(raw)
    rec.flush()
    s = raw.decode("utf-8", "replace").rstrip("\r\n").strip()
    if "COALESCE(MAX(seq)" in s:
        sys.stdout.write(maxseq + "\n")
        sys.stdout.flush()
    elif s.startswith("\\echo "):
        said = s[len("\\echo "):]
        if said.startswith("<<polter:ok:"):
            done += 1
            if limit and done > limit:
                break
        sys.stdout.write(said + "\n")
        sys.stdout.flush()
rec.close()
'''


def pg_self_test(tmp):
    fake_dir = os.path.join(tmp, "fake")
    os.makedirs(fake_dir)
    fake = os.path.join(fake_dir, "psql")
    with open(fake, "w") as f:
        f.write(FAKE_PSQL)
    os.chmod(fake, 0o755)

    os.environ["PATH"] = fake_dir + os.pathsep + os.environ.get("PATH", "")
    os.environ["POLTER_FAKE_DIR"] = fake_dir
    os.environ["POLTER_FAKE_MAXSEQ"] = "0"

    # Every part of the DSN carries a marker, so "no fragment reached argv or
    # stderr" is something a substring search can actually decide.
    user, password, host, db = "zquser", "zqpassword", "zqhost", "zqdb"
    dsn = "postgresql://%s:%s@%s:5433/%s?sslmode=require" % (user, password, host, db)
    markers = (user, password, host, db)

    odd = "\u4e2d\u6587 \"q\" back\\slash\nline two"
    msgs = [_msg(3, text=odd), _msg(5, text="plain", group="ops")]

    cap = _Capture()
    saved = sys.stderr
    sys.stderr = cap
    try:
        s = Session()
        hello_ack = s.handle(
            _hello_line(
                0,
                {
                    "backend": "postgres",
                    "dsn": dsn,
                    "schema": "public",
                    "stream": "selftest",
                },
            )
        )
        batch_ack = s.handle(_batch_line(0, 5, msgs))
        s.close()
    finally:
        sys.stderr = saved

    _eq("the postgres backend greets and acknowledges", (hello_ack, batch_ack), ('{"ok":true}', '{"ok":true}'))

    with open(os.path.join(fake_dir, "stdin.txt"), "rb") as f:
        sql = f.read().decode("utf-8")
    with open(os.path.join(fake_dir, "argv.json")) as f:
        argv = json.load(f)
    with open(os.path.join(fake_dir, "env.json")) as f:
        env = json.load(f)

    _eq(
        "the insert is idempotent and the identifiers are fixed",
        (
            "ON CONFLICT (stream, seq) DO NOTHING" in sql,
            '"public".polter_chat' in sql,
            "polter_chat_group_seq" in sql,
        ),
        (True, True, True),
    )

    lines = sql.split("\n")
    at = lines.index("COPY polter_in (doc) FROM STDIN;")
    payload = lines[at + 1]
    doc = json.loads(payload.replace("\\\\", "\\"))
    _eq(
        "the copy payload is one line that reads back as the batch",
        (lines[at + 2], [m["text"] for m in doc["messages"]], [m["seq"] for m in doc["messages"]]),
        ("\\.", [odd, "plain"], [3, 5]),
    )

    joined = " ".join(argv)
    _eq(
        "no part of the dsn is in the command line",
        [m for m in markers if m in joined],
        [],
    )

    _eq(
        "the password reaches psql through the environment",
        (env.get("PGPASSWORD"), env.get("PGHOST"), env.get("PGDATABASE"), env.get("PGSSLMODE")),
        (password, host, db, "require"),
    )

    _eq(
        "no part of the dsn reaches the log",
        [m for m in markers if m in cap.text()],
        [],
    )

    # A batch that does not fit in one chunk, with the second chunk's psql
    # going away the way ON_ERROR_STOP leaves it. 100 messages to a
    # transaction is not about size -- a whole batch is at most 256 -- it is so
    # that the partial path exists and has been run at least once. What comes
    # back has to be the last seq that actually committed, not the last one we
    # were handed: naming the second would tell the host that a hundred
    # messages are stored when they are not, and it would never send them
    # again.
    chunk_dir = os.path.join(tmp, "fake2")
    os.makedirs(chunk_dir)
    os.environ["POLTER_FAKE_DIR"] = chunk_dir
    os.environ["POLTER_FAKE_OK_LIMIT"] = "1"

    many = [_msg(seq) for seq in range(1, 151)]
    saved = sys.stderr
    sys.stderr = _Capture()
    try:
        s = Session()
        s.handle(
            _hello_line(
                0, {"backend": "postgres", "dsn": dsn, "stream": "selftest"}
            )
        )
        ack = s.handle(_batch_line(0, 200, many))
        s.close()
    finally:
        sys.stderr = saved

    with open(os.path.join(chunk_dir, "stdin.txt"), "rb") as f:
        chunked = f.read().decode("utf-8")

    _eq(
        "a long batch is chunked, and only what committed is acknowledged",
        (
            ack,
            chunked.count("COPY polter_in (doc) FROM STDIN;"),
            # One for the DDL and one per chunk: every chunk is its own
            # transaction, which is what makes "the first hundred are stored"
            # a true statement to make.
            chunked.count("BEGIN;"),
        ),
        ('{"ok":true,"cursor":100}', 2, 3),
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
