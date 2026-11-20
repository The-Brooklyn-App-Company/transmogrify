"""firstrun.py - structured reads for bootstrap.sh's checklist (system Python, standard library only).

Every check parses the data it reads (JSON, the Codex app-server protocol); none matches a string in a whole file.
Nothing here writes outside the one file `codex-hook-write` creates, prints a secret, or calls a model.

Usage: firstrun.py claude-auth                      (stdin: `claude auth status --json`)
       firstrun.py claude-hook SETTINGS SCRIPT
       firstrun.py claude-hook-snippet COMMAND
       firstrun.py codex-hook CODEX HOME SCRIPT [TIMEOUT]
       firstrun.py codex-hook-write FILE COMMAND
       firstrun.py codex-pins STATE                 (stdin: name TAB session TAB client, one row per operator)
       firstrun.py claude-attribution SETTINGS          (ok | missing REASON | unreadable)
       firstrun.py claude-attribution-write SETTINGS    (written BACKUP | unchanged | refused REASON)
       firstrun.py shell-quote WORD...

Output: one line, its first word the verdict.
"""
import json
import os
import re
import select
import signal
import subprocess
import sys
import time


def out(*words):
    print("\t".join(str(w) for w in words))
    return 0


def matcher_covers(matcher, *sources):
    """A SessionStart matcher (a regular expression; empty or "*" for all) that selects every given source."""
    if matcher in (None, "", "*"):
        return True
    try:
        return all(re.fullmatch(matcher, s) for s in sources)
    except re.error:
        return False


# ---- Claude ----------------------------------------------------------------------------------------------------------
def claude_auth():
    try:
        data = json.loads(sys.stdin.read())
    except ValueError:
        return out("unknown")
    v = data.get("loggedIn") if isinstance(data, dict) else None
    return out("in" if v is True else "out" if v is False else "unknown")


def claude_hook(settings, script):
    """ok: hooks.SessionStart has a command hook that runs SCRIPT for both compact and resume."""
    try:
        with open(settings, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return out("missing", "no settings file")
    except (OSError, ValueError):
        return out("unreadable", "the settings file does not parse")
    groups = ((data.get("hooks") or {}).get("SessionStart") if isinstance(data, dict) else None) or []
    if not isinstance(groups, list):
        return out("missing", "hooks.SessionStart is not a list")
    for g in groups:
        if not isinstance(g, dict) or not matcher_covers(g.get("matcher"), "compact", "resume"):
            continue
        for h in g.get("hooks") or []:
            if isinstance(h, dict) and h.get("type") == "command" and script in str(h.get("command", "")):
                return out("ok")
    return out("missing", "no SessionStart command hook for compact and resume runs the digest")


def claude_hook_snippet(command):
    return out(json.dumps({"hooks": {"SessionStart": [
        {"matcher": "compact|resume", "hooks": [{"type": "command", "command": command}]}]}}))


# ---- Codex -----------------------------------------------------------------------------------------------------------
def codex_rpc(codex, home, method, params, timeout):
    """One request to `codex app-server` (plugins and apps off), after the initialize handshake."""
    try:
        p = subprocess.Popen([codex, "--disable", "plugins", "--disable", "apps", "app-server"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             cwd=home, start_new_session=True)
    except OSError:
        return None, "cannot start codex app-server"
    buf, result, err = b"", None, "no answer"

    def send(o):
        p.stdin.write((json.dumps(o) + "\n").encode())
        p.stdin.flush()

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "transmogrify-bootstrap", "version": "1"}}})
        deadline = time.time() + timeout
        while time.time() < deadline and result is None:
            r, _, _ = select.select([p.stdout], [], [], 1)
            if not r:
                if p.poll() is not None:
                    break
                continue
            chunk = os.read(p.stdout.fileno(), 1 << 20)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(m, dict):
                    continue
                if m.get("id") == 1:
                    if "error" in m:
                        return None, "initialize failed"
                    send({"jsonrpc": "2.0", "method": "initialized"})
                    send({"jsonrpc": "2.0", "id": 2, "method": method, "params": params})
                elif m.get("id") == 2:
                    if "error" in m or not isinstance(m.get("result"), dict):
                        err = "%s failed" % method
                        result = {}
                    else:
                        result = m["result"]
    except (OSError, ValueError):
        err = "app-server closed"
    finally:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(p.pid, sig)
                p.wait(5)
                break
            except (OSError, subprocess.TimeoutExpired):
                continue
    return (result or None), (None if result else err)


def codex_hook(codex, home, script, timeout=60):
    """Codex's own view of the home's hooks (hooks/list, both hooks.json and config.toml, every layer):
    trusted HASH KEY SOURCE | untrusted | modified | disabled | none | error REASON."""
    res, err = codex_rpc(codex, home, "hooks/list", {"cwds": [home]}, float(timeout))
    if res is None:
        return out("error", err)
    mine = []
    for entry in res.get("data") or []:
        for h in (entry or {}).get("hooks") or []:
            if (isinstance(h, dict) and h.get("eventName") == "sessionStart" and h.get("handlerType") == "command"
                    and script in str(h.get("command", "")) and matcher_covers(h.get("matcher"), "startup")):
                mine.append(h)
    if not mine:
        return out("none")
    for want in ("trusted", "managed"):
        for h in mine:
            if h.get("enabled") is True and h.get("trustStatus") == want:
                return out("trusted", h.get("currentHash", ""), h.get("key", ""), h.get("sourcePath", ""))
    if any(h.get("enabled") is False for h in mine):
        return out("disabled")
    return out("modified" if any(h.get("trustStatus") == "modified" for h in mine) else "untrusted")


def codex_hook_write(path, command):
    doc = {"description": "Transmogrify recovery digest (ops/recover-context.sh)",
           "hooks": {"SessionStart": [{"matcher": "startup|resume|compact|fork",
                                       "hooks": [{"type": "command", "command": command,
                                                  "statusMessage": "Loading recovery digest", "timeout": 10}]}]}}
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError:
        return out("exists")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(doc, indent=2) + "\n")
    return out("written")


def codex_pins(state):
    """ok N | missing NAMES | none | unreadable: the operators active on Codex with a thread id must be pinned."""
    want = []
    for line in sys.stdin.read().splitlines():
        c = line.split("\t")
        if len(c) >= 3 and c[2] == "codex" and c[1] not in ("", "-", "pending"):
            want.append((c[0], c[1]))
    if not want:
        return out("none")
    try:
        with open(state, encoding="utf-8") as f:
            pinned = json.load(f).get("pinned-thread-ids")
        if not isinstance(pinned, list):
            raise ValueError
    except (OSError, ValueError, AttributeError):
        return out("unreadable")
    missing = [n for n, t in want if t not in pinned]
    return out("missing", ", ".join(missing)) if missing else out("ok", len(want))


# ---- Claude Code attribution (K-30) ----------------------------------------------------------------------------------
# Claude Code adds its own commit trailer and pull-request footer unless its settings say otherwise: `attribution`
# ({"commit": "", "pr": ""}, current clients) and `includeCoAuthoredBy` (false, older ones). The write keeps every
# other byte of the settings file: the two keys are spliced into its text, never re-serialized.
ATTR = {"attribution": '{"commit": "", "pr": ""}', "includeCoAuthoredBy": "false"}


def _ws(t, i):
    while i < len(t) and t[i] in " \t\r\n":
        i += 1
    return i


def _value_end(t, i):
    if t[i] == '"':
        i += 1
        while t[i] != '"':
            i += 2 if t[i] == "\\" else 1
        return i + 1
    if t[i] in "[{":
        depth = 0
        while True:
            c = t[i]
            if c == '"':
                i = _value_end(t, i)
                continue
            if c in "[{":
                depth += 1
            elif c in "]}":
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
    j = i
    while j < len(t) and t[j] not in ",]} \t\r\n":
        j += 1
    return j


def _members(t, i):
    out = []
    i = _ws(t, i + 1)
    while t[i] != "}":
        ks, ke = i, _value_end(t, i)
        vs = _ws(t, _ws(t, ke) + 1)
        ve = _value_end(t, vs)
        out.append((json.loads(t[ks:ke]), ks, vs, ve))
        i = _ws(t, ve)
        if t[i] == ",":
            i = _ws(t, i + 1)
    return out, i


def _indent(t, pos):
    start = t.rfind("\n", 0, pos) + 1
    return re.match(r"[ \t]*", t[start:]).group(0)


def attribution_ok(data):
    a = data.get("attribution") if isinstance(data, dict) else None
    return (isinstance(a, dict) and a.get("commit") == "" and a.get("pr") == ""
            and data.get("includeCoAuthoredBy") is not True)


def claude_attribution(settings):
    try:
        with open(settings, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return out("missing", "no settings file")
    except (OSError, ValueError):
        return out("unreadable", "the settings file does not parse")
    if attribution_ok(data):
        return out("ok")
    return out("missing", "attribution is not {\"commit\": \"\", \"pr\": \"\"}")


def splice_top(raw, key, value):
    top = _ws(raw, 0)
    members, close = _members(raw, top)
    nl = "\r\n" if "\r\n" in raw else "\n"
    hit = [m for m in members if m[0] == key]
    if hit:
        _, ks, vs, ve = hit[-1]
        return raw[:vs] + value + raw[ve:]
    if members:
        last, lv = members[-1][3], _indent(raw, members[0][1])
        return raw[:last] + "," + nl + lv + json.dumps(key) + ": " + value + raw[last:]
    return raw[:top] + "{" + nl + "  " + json.dumps(key) + ": " + value + nl + "}" + raw[close + 1:]


def claude_attribution_write(settings):
    # A linked settings file (a dotfiles setup) is written through to its target, never replaced by a copy.
    settings = os.path.realpath(settings)
    try:
        with open(settings, encoding="utf-8", newline="") as f:
            raw = f.read()
    except FileNotFoundError:
        raw = None
    except OSError:
        return out("refused", "cannot read the settings file")
    if raw is None:
        new = "{\n" + ",\n".join("  %s: %s" % (json.dumps(k), v) for k, v in ATTR.items()) + "\n}\n"
        before = {}
    else:
        try:
            before = json.loads(raw)
        except ValueError:
            return out("refused", "the settings file does not parse; fix it first")
        if not isinstance(before, dict):
            return out("refused", "the settings file is not a JSON object")
        if attribution_ok(before):
            return out("unchanged")
        new = raw
        for k, v in ATTR.items():
            new = splice_top(new, k, v)
    after = json.loads(new)
    b = dict(before)
    for k in ATTR:
        b.pop(k, None)
        after_v = after.pop(k, None)
        if after_v != json.loads(ATTR[k]):
            return out("refused", "internal check failed; nothing written")
    if b != after:
        return out("refused", "internal check failed (another key would change); nothing written")
    os.makedirs(os.path.dirname(settings) or ".", exist_ok=True)
    backup = ""
    if raw is not None:
        backup = "%s.bak-%s-attribution" % (settings, time.strftime("%Y%m%d-%H%M%S"))
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, os.stat(settings).st_mode & 0o7777)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(raw)
        os.chmod(backup, os.stat(settings).st_mode & 0o7777)
    tmp = settings + ".tmp-%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(new)
    if raw is not None:
        os.chmod(tmp, os.stat(settings).st_mode & 0o7777)
        try:
            with open(settings, encoding="utf-8", newline="") as f:
                if f.read() != raw:
                    os.unlink(tmp)
                    return out("refused", "the settings file changed meanwhile; nothing written")
        except OSError:
            os.unlink(tmp)
            return out("refused", "cannot re-read the settings file")
    os.replace(tmp, settings)
    return out("written", backup or "-")


def shell_quote(words):
    print(" ".join("'" + w.replace("'", "'\\''") + "'" for w in words))
    return 0


def main(a):
    cmd = a[0] if a else ""
    if cmd == "claude-auth" and len(a) == 1:
        return claude_auth()
    if cmd == "claude-hook" and len(a) == 3:
        return claude_hook(a[1], a[2])
    if cmd == "claude-hook-snippet" and len(a) == 2:
        return claude_hook_snippet(a[1])
    if cmd == "codex-hook" and len(a) in (4, 5):
        return codex_hook(*a[1:])
    if cmd == "codex-hook-write" and len(a) == 3:
        return codex_hook_write(a[1], a[2])
    if cmd == "codex-pins" and len(a) == 2:
        return codex_pins(a[1])
    if cmd == "claude-attribution" and len(a) == 2:
        return claude_attribution(a[1])
    if cmd == "claude-attribution-write" and len(a) == 2:
        return claude_attribution_write(a[1])
    if cmd == "shell-quote" and len(a) >= 2:
        return shell_quote(a[1:])
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
