#!/usr/bin/python3 -I
"""grants.py - one client-neutral grants file, two native renderers, one three-state check.

Run through ops/grants.sh, which loads the profile and passes every path in the environment:
  GRANTS_SOURCE           the grants file (Markdown; format in docs/operations/grants.md)
  GRANTS_REGISTRY         operators/REGISTRY.tsv (key, name, home, session, client)
  GRANTS_ORACLE_KEY       the Oracle's registry key
  GRANTS_ACCEPTED         the accepted-state ledger (TSV)
  GRANTS_CLAUDE_SETTINGS  the Claude Code settings file that holds autoMode.allow
  GRANTS_CODEX_BIN        the Codex CLI
  GRANTS_STATE            a state directory for the writer lock and the log
  CODEX_HOME              the Codex user folder (never written)

Never prints a config file, a policy or the model catalog: hashes, lengths and origins only. No network, no
Keychain, no Apple Events. Codex readback is a local `codex app-server` over stdio (initialize, config/read,
configRequirements/read). Standard library only.
"""
import datetime
import fcntl
import hashlib
import json
import os
import re
import select
import signal
import subprocess
import sys
import tempfile
import time

# The kit's exit codes: 0 ok; 1 findings or a failure (not synchronized); 2 usage or an invalid grants file;
# 3 busy (another render holds the writer lock).
E_OK, E_FINDINGS, E_FAIL, E_USAGE, E_BUSY = 0, 1, 1, 2, 3


class Fail(Exception):
    """A refusal or failure with a message for the person; code is the exit status."""

    def __init__(self, msg, code=E_FAIL):
        Exception.__init__(self, msg)
        self.code = code


def env(name, default=None):
    v = os.environ.get(name, default)
    if v is None:
        raise Fail("%s is not set (run through ops/grants.sh)" % name, E_USAGE)
    return v


SOURCE = env("GRANTS_SOURCE", "")
REG = env("GRANTS_REGISTRY", "")
ORACLE = os.environ.get("GRANTS_ORACLE_KEY", "oracle")
ACCEPTED = env("GRANTS_ACCEPTED", "")
CLAUDE_SETTINGS = env("GRANTS_CLAUDE_SETTINGS", "")
CODEX = os.environ.get("GRANTS_CODEX_BIN", "codex")
CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.join(os.environ.get("HOME", "/nonexistent"), ".codex")
STATE = env("GRANTS_STATE", "")
REVIEW_SLUG = os.environ.get("GRANTS_CODEX_REVIEW_SLUG", "codex-auto-review")
READBACK_TIMEOUT = int(os.environ.get("GRANTS_READBACK_TIMEOUT", "45"))
TODAY = os.environ.get("GRANTS_TODAY") or datetime.date.today().isoformat()
# Managed requirement keys a person has checked and found to set no reviewer policy (profile key
# grants_managed_requirements_ok, comma-separated).
REQUIREMENTS_OK = [k.strip() for k in os.environ.get("GRANTS_MANAGED_REQUIREMENTS_OK", "").split(",") if k.strip()]

BEGIN = "# >>> transmogrify grants: managed by ops/grants.sh from the grants file; do not edit by hand >>>"
END = "# <<< transmogrify grants <<<"
TAG_RE = re.compile(r" \[grant:([a-z0-9][a-z0-9-]*)\]$")
SECTION_RE = re.compile(r"^(Allowed|Limits|Does NOT cover)\b[^\n]*:$")
MANAGED_LAYERS = ("mdm", "enterpriseManaged", "legacyManagedConfigTomlFromFile", "legacyManagedConfigTomlFromMdm")


def sha(text):
    return hashlib.sha256(text.encode("utf-8") if isinstance(text, str) else text).hexdigest()


def short(h):
    return (h or "none")[:12]


def log(*cols):
    if not STATE:
        return
    try:
        os.makedirs(STATE, exist_ok=True)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with open(os.path.join(STATE, "grants.log"), "a", encoding="utf-8") as f:
            f.write("\t".join([stamp] + [str(c) for c in cols]) + "\n")
    except OSError:
        pass


_LOCK = None


def writer_lock():
    """One writer at a time; a second writer is refused, never queued."""
    global _LOCK
    if _LOCK or not STATE:
        return
    os.makedirs(STATE, exist_ok=True)
    fd = os.open(os.path.join(STATE, "grants.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        raise Fail("another grants render is running; try again", E_BUSY)
    _LOCK = fd


def write_temp(path, content, mode):
    """Write content to a temporary file beside path and return its name."""
    fd, tmp = tempfile.mkstemp(prefix=".grants.", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
    except BaseException:
        os.unlink(tmp)
        raise
    return tmp


def current(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None


def replace_if_unchanged(tmp, path, expected):
    """Move tmp over path only if path still holds what the plan was made from."""
    if current(path) != expected:
        os.unlink(tmp)
        raise Fail("%s changed during the render; nothing written, run it again" % path)
    os.replace(tmp, path)


# ---- source and registry --------------------------------------------------------------------------------------------
def registry():
    """{key: (name, home)} from REGISTRY.tsv."""
    reg = {}
    try:
        with open(REG, encoding="utf-8") as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                c = line.rstrip("\n").split("\t")
                if len(c) < 3:
                    continue
                home = c[2]
                if home == "~" or home.startswith("~/"):  # as the installer writes them
                    home = os.environ.get("HOME", "") + home[1:]
                if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", c[0]) and home.startswith("/"):
                    reg[c[0]] = (c[1], home)
    except OSError:
        raise Fail("registry: cannot read %s" % REG, E_USAGE)
    if ORACLE not in reg:
        raise Fail("registry: no row for the Oracle key '%s' in %s" % (ORACLE, REG), E_USAGE)
    return reg


def between(text, name):
    m = re.search(r"<!-- %s:begin[^>]*-->\n(.*?)<!-- %s:end -->" % (name, name), text, re.S)
    if not m:
        raise Fail("source: no <!-- %s:begin --> ... <!-- %s:end --> block" % (name, name), E_USAGE)
    return m.group(1)


def fence(lines, i, where):
    """lines[i] is '~~~text'; returns (content, index after the closing fence)."""
    j = i + 1
    while j < len(lines) and lines[j] != "~~~":
        j += 1
    if j >= len(lines):
        raise Fail("source: unclosed ~~~ fence in %s" % where, E_USAGE)
    return "\n".join(lines[i + 1:j]), j + 1


def parse_source(path=None):
    path = path or SOURCE
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        raise Fail("source: cannot read %s" % path, E_USAGE)
    src = {"sha": sha(text), "baselines": {}, "grants": []}
    for line in between(text, "baselines").splitlines():
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(c) == 4 and re.fullmatch(r"[0-9a-f]{64}", c[1]):
            src["baselines"][c[1]] = {"cli": c[0], "bytes": c[2], "verified": c[3]}
    pre = between(text, "preamble").splitlines()
    if "~~~text" not in pre:
        raise Fail("source: the preamble block has no ~~~text fence", E_USAGE)
    src["preamble"], _ = fence(pre, pre.index("~~~text"), "preamble")
    chunks = re.split(r"^### grant: *", between(text, "grants"), flags=re.M)
    if chunks[0].strip():
        raise Fail("source: text before the first '### grant:' in the grants block", E_USAGE)
    for chunk in chunks[1:]:
        src["grants"].append(parse_grant(chunk))
    return src


def parse_grant(chunk):
    lines = chunk.split("\n")
    gid = lines[0].strip()
    g = {"id": gid, "title": "", "actors": [], "codex": None, "codex_reason": "", "words": [], "sections": [],
         "claude": None, "expires": None}
    i, cur = 1, None
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line == "Claude:":
            i += 1
            while i < len(lines) and not lines[i].strip():
                i += 1
            if i >= len(lines) or lines[i] != "~~~text":
                raise Fail("grant %s: 'Claude:' must be followed by a ~~~text fence" % gid, E_USAGE)
            g["claude"], i = fence(lines, i, "grant " + gid)
            cur = None
            continue
        if SECTION_RE.match(line):
            cur = {"kind": SECTION_RE.match(line).group(1), "header": line, "bullets": []}
            g["sections"].append(cur)
        elif line.startswith("- ") and cur is not None:
            cur["bullets"].append(line[2:].strip())
        elif line.startswith("- "):
            k, sep, v = line[2:].partition(":")
            if not sep:
                raise Fail("grant %s: field line without 'key:': %s" % (gid, line[:60]), E_USAGE)
            k, v = k.strip(), v.strip()
            if k == "title":
                g["title"] = v
            elif k == "actors":
                g["actors"] = [a.strip() for a in v.split(",") if a.strip()]
            elif k == "codex":
                g["codex"] = v.split()[0].lower() == "yes" if v else None
                g["codex_reason"] = v
            elif k == "expires":
                g["expires"] = v
            elif k == "words":
                parts = [p.strip() for p in v.split(" | ", 2)]
                if len(parts) != 3:
                    raise Fail("grant %s: words must be 'date | provenance | quote'" % gid, E_USAGE)
                g["words"].append({"date": parts[0], "prov": parts[1], "quote": parts[2]})
            else:
                raise Fail("grant %s: unknown field '%s'" % (gid, k), E_USAGE)
        else:
            raise Fail("grant %s: unexpected line: %s" % (gid, line[:60]), E_USAGE)
        i += 1
    return g


def expired(g):
    return g["expires"] not in (None, "never") and g["expires"] < TODAY


def live(src):
    """The grants that render: every grant that has not expired."""
    return [g for g in src["grants"] if not expired(g)]


def expand(actors, reg):
    out = []
    for a in actors:
        if a == "operators":
            out += [k for k in reg if k != ORACLE]
        elif a == "oracle":
            out.append(ORACLE)
        else:
            out.append(a)
    return sorted(set(out))


def validate(src, reg):
    ids = [g["id"] for g in src["grants"]]
    errs = []
    if len(set(ids)) != len(ids):
        errs.append("duplicate grant ids")
    byid = {g["id"]: g for g in src["grants"]}
    for g in src["grants"]:
        p = "grant %s: " % g["id"]
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", g["id"]):
            errs.append(p + "bad id (lowercase letters, digits and dashes)")
        if not g["title"]:
            errs.append(p + "no title")
        if not g["actors"]:
            errs.append(p + "no actors")
        for a in g["actors"]:
            if a not in ("operators", "oracle") and a not in reg:
                errs.append(p + "actor '%s' is not operators, oracle or a registry key" % a)
        if g["codex"] is None:
            errs.append(p + "codex: must start with yes or no")
        if not g["expires"] or not (g["expires"] == "never" or re.fullmatch(r"\d{4}-\d{2}-\d{2}", g["expires"])):
            errs.append(p + "expires: must be YYYY-MM-DD or never")
        if not g["words"]:
            errs.append(p + "no words (the owner's verbatim grant)")
        c = g["claude"]
        if not c:
            errs.append(p + "no Claude text")
            continue
        if "\n" in c or "[grant:" in c:
            errs.append(p + "Claude text must be one line without a [grant:] tag")
        for w in g["words"]:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", w["date"]):
                errs.append(p + "words date '%s'" % w["date"])
            if w["quote"] not in c:
                errs.append(p + "quote not verbatim in the Claude text: %s..." % w["quote"][:40])
        kinds = [s["kind"] for s in g["sections"]]
        if g["codex"]:
            if not any(s["bullets"] for s in g["sections"] if s["kind"] == "Allowed"):
                errs.append(p + "codex: yes needs an Allowed list")
            if "Does NOT cover" not in kinds:
                errs.append(p + "codex: yes needs a Does NOT cover list")
            keys = expand(g["actors"], reg)
            for s in g["sections"]:
                for b in s["bullets"]:
                    m = re.match(r"\[only: *([^\]]+)\]", b)
                    if m:
                        for k in [x.strip() for x in m.group(1).split(",")]:
                            if k not in keys:
                                errs.append(p + "[only: %s] names a key outside the actors" % k)
                    if "@include" in b and not re.fullmatch(r"@include +\S+", b):
                        errs.append(p + "'%s': @include stands alone (no [only:] or [no-include])" % b[:60])
                    m = re.fullmatch(r"@include +(\S+)", b)
                    if m:
                        t = byid.get(m.group(1))
                        if not t or s["kind"] != "Does NOT cover":
                            errs.append(p + "@include %s: unknown grant or not in Does NOT cover" % m.group(1))
                        elif any(re.fullmatch(r"@include +\S+", x) for ts in t["sections"] for x in ts["bullets"]):
                            errs.append(p + "@include %s: nested includes are not supported" % m.group(1))
        elif g["sections"]:
            errs.append(p + "codex: no, so it must not carry Codex clauses")
    if errs:
        raise Fail("source invalid:\n  " + "\n  ".join(errs), E_USAGE)
    return src


def load():
    reg = registry()
    return validate(parse_source(), reg), reg


# ---- Claude ---------------------------------------------------------------------------------------------------------
def claude_entry(g):
    return "%s [grant:%s]" % (g["claude"], g["id"])


def claude_head(text):
    m = re.match(r"^[^:(]+", text)
    return m.group(0).strip() if m else text


def claude_set_sha(src):
    return sha("\n".join(claude_entry(g) for g in live(src)))


def json_style(raw, data):
    """The json.dumps arguments that reproduce this file byte for byte, or a default."""
    for indent in (2, 4, "\t"):
        for ea in (True, False):
            out = json.dumps(data, indent=indent, ensure_ascii=ea)
            if out == raw:
                return indent, ea, ""
            if out + "\n" == raw:
                return indent, ea, "\n"
    return 2, False, "\n"


def claude_plan(src, data, prune=False):
    """(new allow list, changes, problems). Untagged entries are never touched, except a byte-identical copy of a
    grant's text, which gains its tag. An expired grant's entry is removed."""
    auto = data.get("autoMode", {})
    allow = auto.get("allow", []) if isinstance(auto, dict) else None
    if not isinstance(allow, list) or not all(isinstance(x, str) for x in allow):
        return None, [], ["autoMode.allow is not a list of strings"]
    grants = live(src)
    byid = {g["id"]: g for g in grants}
    gone = {g["id"] for g in src["grants"] if expired(g)}
    legacy = {g["claude"]: g["id"] for g in grants}  # an expired grant's untagged copy is the owner's to remove
    heads = {claude_head(g["claude"]): g["id"] for g in grants}
    seen, out, changes, problems = set(), [], [], []
    for e in allow:
        m = TAG_RE.search(e)
        gid = m.group(1) if m else legacy.get(e)
        if gid is None:
            h = claude_head(e)
            if h in heads:
                problems.append("untagged entry '%s' differs from grant %s: reconcile it by hand first" % (h, heads[h]))
            out.append(e)
            continue
        if gid in gone:
            changes.append("removed %s (expired)" % gid)
            continue
        if gid not in byid:
            if prune:
                changes.append("removed %s (no longer in the grants file)" % gid)
                continue
            problems.append("tagged entry [grant:%s] is not in the grants file (pass --prune to remove it)" % gid)
            out.append(e)
            continue
        if gid in seen:
            changes.append("dropped a duplicate of %s" % gid)
            continue
        seen.add(gid)
        want = claude_entry(byid[gid])
        if e != want:
            changes.append("tagged %s (identical untagged text)" % gid if not m else
                           "updated %s (live text sha %s differed)" % (gid, short(sha(e))))
        out.append(want)
    for g in grants:
        if g["id"] not in seen:
            out.append(claude_entry(g))
            changes.append("added %s" % g["id"])
    return out, changes, problems


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return None, {}
    try:
        data = json.loads(raw)
    except ValueError:
        raise Fail("%s does not parse" % path)
    if not isinstance(data, dict):
        raise Fail("%s is not a JSON object" % path)
    return raw, data


def render_claude(src, path, dry=False, prune=False):
    raw, data = read_json(path)
    new, changes, problems = claude_plan(src, data, prune)
    if problems:
        raise Fail("claude: not rendered:\n  " + "\n  ".join(problems))
    if not changes:
        print("claude: rendered, no change (%d managed entries, set %s)" % (len(live(src)), short(claude_set_sha(src))))
        return E_OK
    for c in changes:
        print("claude: " + c)
    if dry:
        print("claude: dry run, nothing written")
        return E_OK
    indent, ea, nl = json_style(raw, data) if raw is not None else (2, False, "\n")
    nd = json.loads(raw) if raw is not None else {}
    if not isinstance(nd.get("autoMode"), dict):
        nd["autoMode"] = {}
    nd["autoMode"]["allow"] = new
    out = json.dumps(nd, indent=indent, ensure_ascii=ea) + nl
    # Everything except autoMode.allow must be identical, and so must the non-grant entries, in order.
    a, b = json.loads(raw) if raw is not None else {}, json.loads(out)
    a.get("autoMode", {}).pop("allow", None)
    b["autoMode"].pop("allow")
    if not a.get("autoMode") and not b["autoMode"]:
        a.pop("autoMode", None)
        b.pop("autoMode", None)
    if a != b:
        raise Fail("claude: internal check failed (a key outside autoMode.allow would change); nothing written")
    texts = {g["claude"] for g in src["grants"]}

    def keep(entries):
        return [e for e in entries if not TAG_RE.search(e) and e not in texts]
    if keep((data.get("autoMode") or {}).get("allow", [])) != keep(new):
        raise Fail("claude: internal check failed (a non-grant entry would change); nothing written")
    writer_lock()
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    mode = os.stat(path).st_mode & 0o7777 if raw is not None else 0o600
    bak = None
    if raw is not None:
        bak = "%s.bak-%s-grants" % (path, datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.replace(write_temp(bak, raw, mode), bak)
    tmp = write_temp(path, out, mode)
    try:
        json.loads(current(tmp))
    except ValueError:
        os.unlink(tmp)
        raise Fail("claude: the new file does not parse; nothing written")
    replace_if_unchanged(tmp, path, raw)
    print("claude: written (%sset %s)" % ("backup %s; " % bak if bak else "", short(claude_set_sha(src))))
    log("render-claude", "claude", "*", "written", claude_set_sha(src))
    return E_OK


def claude_state(src, path):
    """{'rendered': (ok, why), 'resolved': (ok, why)}"""
    try:
        raw, data = read_json(path)
    except Fail as e:
        return {"rendered": (False, str(e)), "resolved": (False, str(e))}
    if raw is None:
        why = "%s does not exist" % path
        if not live(src):
            return {"rendered": (True, "no grants to render"), "resolved": (True, "nothing to resolve")}
        return {"rendered": (False, why), "resolved": (False, why)}
    auto = data.get("autoMode", {})
    allow = auto.get("allow", []) if isinstance(auto, dict) else None
    ok = isinstance(allow, list) and all(isinstance(x, str) for x in allow)
    resolved = (True, "settings parse; autoMode.allow is a list of strings") if ok else (
        False, "autoMode.allow missing or malformed")
    new, changes, problems = claude_plan(src, data)
    if problems or changes:
        return {"rendered": (False, "; ".join(problems + ["render would: " + c for c in changes])), "resolved": resolved}
    return {"rendered": (True, "%d managed entries match the grants file" % len(live(src))), "resolved": resolved}


# ---- Codex: baseline ------------------------------------------------------------------------------------------------
def run_codex(args, timeout=120):
    try:
        return subprocess.run([CODEX] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Fail("codex: cannot run %s (%s): not synchronized" % (CODEX, type(e).__name__))


def catalog_policy(data):
    for m in data.get("models") or []:
        if isinstance(m, dict) and m.get("slug") == REVIEW_SLUG:
            return ((m.get("model_messages") or {}).get("auto_review") or {}).get("policy")
    return None


_BASE = None


def bundled_baseline():
    """The bundled reviewer policy as the CLI reports it, without checking it against the grants file."""
    r = run_codex(["debug", "models", "--bundled"])
    if r.returncode:
        raise Fail("codex: `codex debug models --bundled` failed (rc %d): not synchronized" % r.returncode)
    try:
        policy = catalog_policy(json.loads(r.stdout))
    except ValueError:
        policy = None
    if not isinstance(policy, str) or not policy:
        raise Fail("codex: no %s policy in the bundled catalog: not synchronized" % REVIEW_SLUG)
    v = run_codex(["--version"], 30).stdout.decode("utf-8", "replace").strip().split()
    return {"text": policy, "sha": sha(policy), "bytes": len(policy.encode("utf-8")), "cli": v[-1] if v else "?"}


def baseline(src):
    """The bundled reviewer policy, refused unless its hash is a known baseline in the grants file."""
    global _BASE
    if _BASE:
        return _BASE
    b = bundled_baseline()
    b["warn"] = []
    cache = os.path.join(CODEX_HOME, "models_cache.json")
    cache_sha = None
    if os.path.exists(cache):
        try:
            with open(cache, encoding="utf-8") as f:
                cp = catalog_policy(json.load(f))
            cache_sha = sha(cp) if isinstance(cp, str) else None
        except (OSError, ValueError):
            b["warn"].append("the cached model catalog is unreadable")
    known = src["baselines"].get(b["sha"])
    if not known:
        raise Fail("codex: unknown baseline policy sha256 %s (cli %s): not synchronized; a person reads it "
                   "(grants.sh baseline --write FILE) and adds it to Known Codex baselines" % (b["sha"], b["cli"]))
    if cache_sha and cache_sha != b["sha"]:
        raise Fail("codex: the cached catalog's reviewer policy (sha %s) differs from the bundled one (sha %s): the "
                   "live default may differ; not synchronized" % (short(cache_sha), short(b["sha"])))
    if known["cli"] != b["cli"]:
        b["warn"].append("CLI %s differs from the one this baseline was verified with (%s)" % (b["cli"], known["cli"]))
    _BASE = b
    return b


# ---- Codex: render --------------------------------------------------------------------------------------------------
def grant_bullets(src, g, section, key, included=False):
    byid = {x["id"]: x for x in src["grants"]}
    out = []
    for b in section["bullets"]:
        m = re.fullmatch(r"@include +(\S+)", b)
        if m:
            for s in byid[m.group(1)]["sections"]:
                if s["kind"] == "Does NOT cover":
                    out += [x for x in grant_bullets(src, byid[m.group(1)], s, key, True) if x not in out]
            continue
        if b.startswith("[no-include]"):
            if included:
                continue
            b = b[len("[no-include]"):].strip()
        m = re.match(r"\[only: *([^\]]+)\] *", b)
        if m:
            if key not in [x.strip() for x in m.group(1).split(",")]:
                continue
            b = b[m.end():]
        if b not in out:
            out.append(b)
    return out


def codex_grants(src, reg, key):
    return [g for g in live(src) if g["codex"] and key in expand(g["actors"], reg)]


def codex_grants_text(src, reg, key):
    name, home = reg[key]
    pre = src["preamble"].replace("{key}", key).replace("{name}", name).replace("{home}", home)
    parts, used = [pre.rstrip("\n")], []
    for g in codex_grants(src, reg, key):
        used.append(g["id"])
        lines = ["### Grant `%s`: %s" % (g["id"], g["title"]), "", "The owner's words (verbatim):"]
        lines += ['- "%s" (%s; %s)' % (w["quote"], w["date"], w["prov"]) for w in g["words"]]
        if g["expires"] != "never":
            lines += ["", "Expires: %s." % g["expires"]]
        for s in g["sections"]:
            bl = grant_bullets(src, g, s, key)
            if bl:
                lines += ["", s["header"]] + ["- " + b for b in bl]
        parts.append("\n".join(lines))
    return "\n\n".join(parts) + "\n", used


def codex_policy(src, reg, key, base):
    text, used = codex_grants_text(src, reg, key)
    return base["text"] + ("" if base["text"].endswith("\n") else "\n") + "\n" + text, used


def toml_string(s):
    if "'''" not in s and not s.endswith("'") and not re.search(r"[\x00-\x08\x0b-\x1f\x7f]", s):
        return "'''\n" + s + "'''"
    return json.dumps(s, ensure_ascii=False).replace("\x7f", "\\u007f")


def toml_unstring(v):
    """Decode the two forms toml_string writes; None for anything else."""
    if v.startswith("'''\n") and v.endswith("'''"):
        return v[4:-3]
    if v.startswith('"') and v.endswith('"'):
        try:
            return json.loads(v)
        except ValueError:
            return None
    return None


def toplevel_lines(text):
    """For each line of text, whether it starts outside every TOML string, so that a marker, a key or a table
    header on it is real and not part of a (multi-line) string value."""
    out, state, i, n = [True], None, 0, len(text)
    while i < n:
        c = text[i]
        if state is None:
            if c == "#":
                j = text.find("\n", i)
                i = n if j < 0 else j
                continue
            for q in ('"""', "'''", '"', "'"):
                if text.startswith(q, i):
                    state = q
                    i += len(q)
                    break
            else:
                if c == "\n":
                    out.append(True)
                i += 1
            continue
        if state in ('"""', '"') and c == "\\":
            i += 1
            if i < n and text[i] == "\n":
                out.append(False)
            i += 1
            continue
        if text.startswith(state, i):
            if len(state) == 3:
                while text.startswith(state + state[0], i):
                    i += 1
            i += len(state)
            state = None
            continue
        if c == "\n":
            if len(state) == 1:
                state = None  # an unterminated one-line string ends with its line
            out.append(state is None)
        i += 1
    return out


def split_managed(text):
    """(text outside the managed block, block or None). Raises when the file can't be managed safely. Markers,
    keys and table headers count only on lines that start outside TOML strings."""
    lines = text.split("\n")
    top = toplevel_lines(text)
    begins = [i for i, line in enumerate(lines) if line == BEGIN and top[i]]
    ends = [i for i, line in enumerate(lines) if line == END and top[i]]
    if len(begins) > 1 or len(ends) > 1 or bool(begins) != bool(ends):
        raise Fail("managed markers are missing a pair or repeated")
    block = None
    if begins:
        b, e = begins[0], ends[0]
        if e < b:
            raise Fail("managed markers are out of order")
        block = "\n".join(lines[b:e + 1])
        for k in range(e + 1, len(lines)):
            st = lines[k].strip()
            if top[k] and st and not st.startswith("#"):
                if not st.startswith("["):
                    raise Fail("a key follows the managed block without a table header (it would join [auto_review])")
                break
        lines, top = lines[:b] + lines[e + 1:], top[:b] + top[e + 1:]
    for k, line in enumerate(lines):
        s = line.strip()
        if not top[k] or not s or s.startswith("#"):
            continue
        keypart = s if s.startswith("[") else s.split("=", 1)[0] if "=" in s else ""
        if re.search(r"auto.{0,12}review", keypart, re.I) or (keypart and "\\" in keypart):
            raise Fail("an unmanaged auto_review setting (or a key this renderer can't read safely) exists; refusing "
                       "to add a second one")
    return "\n".join(lines), block


def managed_block(key, policy, base, src):
    return "\n".join([
        BEGIN,
        "# actor=%s policy_sha256=%s baseline_sha256=%s cli=%s source_sha256=%s" % (
            key, sha(policy), base["sha"], base["cli"], src["sha"]),
        "[auto_review]",
        "policy = " + toml_string(policy),
        END])


def block_policy(block):
    m = re.search(r"^policy = (.*)\n" + re.escape(END) + r"$", block, re.S | re.M)
    return toml_unstring(m.group(1)) if m else None


def managed_span(text):
    """(begin, end) line indexes of the managed block, or None; markers count only outside TOML strings."""
    lines, top = text.split("\n"), toplevel_lines(text)
    begins = [i for i, line in enumerate(lines) if line == BEGIN and top[i]]
    ends = [i for i, line in enumerate(lines) if line == END and top[i]]
    return (begins[0], ends[0]) if begins and ends else None


def compose(existing, block):
    """The new file: the existing managed block replaced in place (or the block appended after a blank line),
    every other byte kept as it was. Verified by splitting the result again."""
    rest, old = split_managed(existing)
    if old is not None:
        b, e = managed_span(existing)
        lines = existing.split("\n")
        new = "\n".join(lines[:b] + (block.split("\n") if block is not None else []) + lines[e + 1:])
        expect = rest
    elif block is None:
        return existing
    else:
        base = existing
        if base and not base.endswith("\n"):
            base += "\n"
        if base.strip():
            base += "\n"
        new, expect = base + block + "\n", base
    again, blk = split_managed(new)
    if again != expect or blk != block:
        raise Fail("internal check failed: the text outside the managed block would change")
    return new


def app_server_read(cwd, timeout=READBACK_TIMEOUT):
    """Readback through the documented app-server protocol: hashes and origins only."""
    try:
        p = subprocess.Popen([CODEX, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, cwd=cwd, start_new_session=True)
    except OSError:
        return {"error": "cannot start codex app-server"}
    res, buf = {}, b""

    def send(o):
        p.stdin.write((json.dumps(o) + "\n").encode())
        p.stdin.flush()

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "transmogrify-grants", "version": "1"}}})
        deadline = time.time() + timeout
        while time.time() < deadline and not (2 in res and 3 in res):
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
                        return {"error": "initialize failed"}
                    send({"jsonrpc": "2.0", "method": "initialized"})
                    send({"jsonrpc": "2.0", "id": 2, "method": "config/read",
                          "params": {"cwd": cwd, "includeLayers": True}})
                    send({"jsonrpc": "2.0", "id": 3, "method": "configRequirements/read", "params": None})
                elif m.get("id") in (2, 3):
                    res[m["id"]] = m
    except (OSError, ValueError):
        pass
    finally:
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
    if 2 not in res or "error" in res[2] or not isinstance(res[2].get("result"), dict):
        return {"error": "config/read gave no result" if 2 not in res else "config/read error"}
    r = res[2]["result"]
    policy = ((r.get("config") or {}).get("auto_review") or {}).get("policy")
    origin = (r.get("origins") or {}).get("auto_review.policy") or {}
    layers = []
    for layer in r.get("layers") or []:
        n = layer.get("name") or {}
        layers.append({"type": n.get("type"),
                       "path": n.get("dotCodexFolder") or n.get("file") or n.get("domain") or "",
                       "disabled": bool(layer.get("disabledReason")),
                       "auto_review": isinstance(layer.get("config"), dict) and "auto_review" in layer["config"]})
    req = None
    if 3 in res and isinstance(res[3].get("result"), dict):
        rq = res[3]["result"].get("requirements")
        req = sorted(k for k, v in rq.items() if v is not None) if isinstance(rq, dict) else []
    return {"policy_sha": sha(policy) if isinstance(policy, str) else None,
            "origin_type": (origin.get("name") or {}).get("type"),
            "origin_path": (origin.get("name") or {}).get("dotCodexFolder") or (origin.get("name") or {}).get("file"),
            "origin_version": origin.get("version"), "layers": layers, "requirements": req}


def resolve_verdict(rb, home, want_sha):
    if rb.get("error"):
        return False, "readback: " + rb["error"]
    dot = os.path.realpath(os.path.join(home, ".codex"))
    proj = [x for x in rb["layers"] if x["type"] == "project" and os.path.realpath(x["path"] or "/") == dot]
    if not proj:
        return False, "the home's .codex layer is not loaded (no project layer for %s)" % dot
    if proj[0]["disabled"]:
        return False, "the home's .codex layer is disabled (is the project trusted?)"
    managed = [x["type"] for x in rb["layers"] if x["auto_review"] and x["type"] in MANAGED_LAYERS]
    if managed:
        return False, "a managed layer sets auto_review (%s): the local policy is not authoritative" % ",".join(managed)
    if rb["policy_sha"] != want_sha:
        return False, "effective auto_review.policy sha %s, rendered %s" % (short(rb["policy_sha"]), short(want_sha))
    if rb["origin_type"] != "project" or os.path.realpath(rb["origin_path"] or "/") != dot:
        return False, "auto_review.policy comes from %s %s, not the home's .codex" % (
            rb["origin_type"], rb["origin_path"])
    why = "config/read: policy %s from the home's .codex (%s)" % (short(rb["policy_sha"]), rb["origin_version"])
    if rb["requirements"] is None:
        return False, "configRequirements/read gave no answer: a managed reviewer policy can't be ruled out"
    unchecked = [k for k in rb["requirements"] if k not in REQUIREMENTS_OK]
    if unchecked:
        return False, ("managed requirements present (%s): a managed reviewer policy can't be ruled out; once a "
                       "person has checked them, list them in grants_managed_requirements_ok" % ",".join(unchecked))
    if rb["requirements"]:
        return True, why + "; managed requirements checked by a person (%s)" % ",".join(rb["requirements"])
    return True, why + "; no managed requirements"


def safe_target(path, root):
    """The config must be a plain file inside the home's own .codex, never a link into the Codex user folder."""
    for p in (os.path.dirname(path), path):
        if os.path.islink(p):
            raise Fail("refusing: %s is a symlink" % p)
    real = os.path.realpath(path)
    user = os.path.realpath(CODEX_HOME)
    if real == user or real.startswith(user + os.sep) or not real.startswith(os.path.realpath(root) + os.sep):
        raise Fail("refusing: %s resolves outside the home's .codex (%s)" % (path, real))


def codex_targets(src, reg):
    """Registry keys whose home gets (or must lose) a managed Codex block."""
    keys = [k for k in reg if codex_grants(src, reg, k)]
    for k, (_, home) in reg.items():
        if k not in keys:
            try:
                with open(os.path.join(home, ".codex", "config.toml"), encoding="utf-8") as f:
                    if BEGIN in f.read().split("\n"):
                        keys.append(k)
            except OSError:
                pass
    return sorted(keys)


def render_codex(src, reg, key, out_dir=None, dry=False, readback=True):
    if key not in reg:
        raise Fail("codex: '%s' is not a registry key" % key, E_USAGE)
    name, home = reg[key]
    used_grants = codex_grants(src, reg, key)
    base = baseline(src) if used_grants else None
    for w in (base or {}).get("warn", []):
        print("codex: warning: " + w)
    live_path = os.path.join(home, ".codex", "config.toml")
    path = os.path.join(out_dir, key, ".codex", "config.toml") if out_dir else live_path
    root = os.path.join(out_dir, key) if out_dir else home
    safe_target(path, root)
    snap = current(path)
    existing = snap if snap is not None else ((current(live_path) or "") if out_dir else "")
    try:
        split_managed(existing)
    except Fail as e:
        raise Fail("codex %s: not rendered: %s (%s)" % (key, e, path))
    if base:
        policy, used = codex_policy(src, reg, key, base)
        new = compose(existing, managed_block(key, policy, base, src))
        tag = "codex %s: policy %s (%d bytes; baseline %s + grants %s)" % (
            key, short(sha(policy)), len(policy.encode("utf-8")), short(base["sha"]), ",".join(used))
    else:
        policy, new = None, compose(existing, None)
        tag = "codex %s: no grant applies; managed block removed" % key
    if snap == new or (snap is None and new == ""):
        print(tag + "; rendered, no change: " + path)
        return E_OK
    if dry:
        print(tag + "; dry run, nothing written: " + path)
        return E_OK
    writer_lock()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    safe_target(path, root)
    before = current(path)
    if before != snap:
        raise Fail("codex %s: %s changed during the render; nothing written, run it again" % (key, path))
    mode = (os.stat(path).st_mode & 0o7777) if before is not None else 0o644
    bak = None
    if before is not None:
        bak = "%s.bak-%s-grants" % (path, datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.replace(write_temp(bak, before, mode), bak)
    why = ""
    try:
        replace_if_unchanged(write_temp(path, new, mode), path, before)
        _, blk = split_managed(current(path) or "")
        if policy is not None and (blk is None or block_policy(blk) != policy):
            raise Fail("the written block does not decode to the rendered policy")
        if policy is not None and readback and not out_dir:
            ok, why = resolve_verdict(app_server_read(home), home, sha(policy))
            if not ok:
                raise Fail("written but not resolved (%s)" % why)
    except BaseException as e:  # any failure or interruption once the write may have landed restores the file
        msg = rollback(path, bak, before, new) if current(path) == new else "nothing written"
        if not isinstance(e, Exception):
            print("codex %s: interrupted; %s" % (key, msg), file=sys.stderr)
            raise
        log("render-codex", "codex", key, "rolled-back", sha(policy) if policy else "-")
        raise Fail("codex %s: %s; %s" % (key, e if isinstance(e, Fail) else "readback failed: %s" % type(e).__name__,
                                          msg))
    print(tag + ("; written and resolved: " + why if why else "; written (not read back): " + path))
    if bak:
        print("codex %s: backup %s" % (key, bak))
    log("render-codex", "codex", key, "written" if why else "written-noreadback", sha(policy) if policy else "-",
        "baseline=" + (base["sha"] if base else "-"))
    return E_OK


def rollback(path, bak, before, written):
    """Restore the previous file, but never over an edit someone made after our write."""
    if current(path) != written:
        return "NOT rolled back: the file changed after the write (backup %s)" % (bak or "none: the file was new")
    if bak:
        os.replace(write_temp(path, before, os.stat(bak).st_mode & 0o7777), path)
    else:
        os.unlink(path)
    return "rolled back to the previous file"


def codex_state(src, reg, key, resolve=True):
    st = {"rendered": (False, ""), "resolved": (None, "not checked"), "sha": None}
    _, home = reg[key]
    path = os.path.join(home, ".codex", "config.toml")
    try:
        safe_target(path, home)
        _, blk = split_managed(current(path) or "")
    except Fail as e:
        st["rendered"] = (False, "%s: %s" % (path, e))
        st["resolved"] = (False, "not rendered") if resolve else st["resolved"]
        return st
    if not codex_grants(src, reg, key):
        st["rendered"] = (blk is None, "no grant applies" if blk is None else
                          "a managed block remains but no grant applies (render to remove it)")
        st["resolved"] = (None, "nothing to resolve") if blk is None else (False, "not rendered")
        return st
    try:
        base = baseline(src)
    except Fail as e:
        st["rendered"] = (False, str(e))
        st["resolved"] = (False, "not rendered") if resolve else st["resolved"]
        return st
    want, _ = codex_policy(src, reg, key, base)
    st["sha"] = sha(want)
    if blk is None:
        st["rendered"] = (False, "no managed [auto_review] block in %s" % path)
    else:
        got = block_policy(blk)
        st["rendered"] = (True, "policy %s matches the grants file and baseline %s" % (
            short(st["sha"]), short(base["sha"]))) if got == want else (
            False, "disk policy %s differs from the rendering %s (grants file or baseline changed?)" % (
                short(sha(got)) if got else "undecodable", short(st["sha"])))
    if resolve:
        st["resolved"] = resolve_verdict(app_server_read(home), home, st["sha"]) if st["rendered"][0] else (
            False, "not rendered")
    return st


# ---- accepted state -------------------------------------------------------------------------------------------------
def accepted(side, actor, h):
    try:
        with open(ACCEPTED, encoding="utf-8") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if not line.startswith("#") and len(c) >= 5 and c[1] == side and c[2] == actor and c[3] == h:
                    return True, "%s (%s)" % (c[0], c[4])
    except OSError:
        pass
    return False, "no probe recorded for %s" % short(h)


def word(ok):
    return "OK" if ok else ("-" if ok is None else "NO")


def side_ok(st, resolve=True):
    """Rendered, and resolved (or nothing to resolve)."""
    return bool(st["rendered"][0]) and (st["resolved"][0] is not False if resolve else True)


def cmd_gate(src, reg, key, side):
    if key not in reg:
        raise Fail("gate: '%s' is not a registry key" % key, E_USAGE)
    if side == "claude":
        st = claude_state(src, CLAUDE_SETTINGS)
        label = "claude"
    elif side == "codex":
        st = codex_state(src, reg, key, True)
        label = "codex " + key
    else:
        raise Fail("gate: the side must be claude or codex", E_USAGE)
    ok = side_ok(st)
    print("grants gate %s: %s (rendered %s: %s; resolved %s: %s)" % (
        label, "ok" if ok else "REFUSED", word(st["rendered"][0]), st["rendered"][1], word(st["resolved"][0]),
        st["resolved"][1]))
    return E_OK if ok else E_FINDINGS


def cmd_check(args, src, reg):
    side, actor, resolve, findings = "all", None, True, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--side" and i + 1 < len(args):
            side = args[i + 1]
            i += 1
        elif a == "--actor" and i + 1 < len(args):
            actor = args[i + 1]
            i += 1
        elif a == "--no-resolve":
            resolve = False
        elif a == "--findings":
            findings = True
        elif a == "--gate" and i + 2 < len(args):
            return cmd_gate(src, reg, args[i + 1], args[i + 2])
        else:
            raise Fail("check: unknown or incomplete argument %s" % a, E_USAGE)
        i += 1
    if side not in ("all", "claude", "codex"):
        raise Fail("check: --side must be claude, codex or all", E_USAGE)
    bad, out = False, []
    if not findings:
        out.append("grants: file ok (%d grants, %d live; sha %s)" % (len(src["grants"]), len(live(src)),
                                                                    short(src["sha"])))
    for g in src["grants"]:
        if expired(g):
            out.append(("- " if findings else "") + "grants: %s expired on %s (render to remove it)" % (
                g["id"], g["expires"]))
    if side in ("all", "claude"):
        st = claude_state(src, CLAUDE_SETTINGS)
        acc = accepted("claude", "*", claude_set_sha(src))
        bad |= not side_ok(st)
        if findings:
            for k in ("rendered", "resolved"):
                if st[k][0] is False:
                    out.append("- grants: claude not %s: %s" % (k, st[k][1]))
            if live(src) and not acc[0]:
                out.append("- grants: claude accepted-state probe pending (%s)" % acc[1])
        else:
            out.append("claude: rendered %s (%s) | resolved %s (%s) | accepted %s (%s)" % (
                word(st["rendered"][0]), st["rendered"][1], word(st["resolved"][0]), st["resolved"][1],
                word(acc[0]), acc[1]))
    if side in ("all", "codex"):
        keys = [actor] if actor else codex_targets(src, reg)
        for k in keys:
            if k not in reg:
                out.append("%scodex %s: not a registry key" % ("- grants: " if findings else "", k))
                bad = True
                continue
            st = codex_state(src, reg, k, resolve)
            acc = accepted("codex", k, st["sha"]) if st["sha"] else (None, "-")
            bad |= not side_ok(st, resolve)
            if findings:
                for n in ("rendered", "resolved"):
                    if st[n][0] is False:
                        out.append("- grants: codex %s not %s: %s" % (k, n, st[n][1]))
                if st["sha"] and st["rendered"][0] and not acc[0]:
                    out.append("- grants: codex %s accepted-state probe pending (%s)" % (k, acc[1]))
            else:
                out.append("codex %s: rendered %s (%s) | resolved %s (%s) | accepted %s (%s)" % (
                    k, word(st["rendered"][0]), st["rendered"][1], word(st["resolved"][0]), st["resolved"][1],
                    word(acc[0]), acc[1]))
    if out:
        print("\n".join(out))
    return E_FINDINGS if bad else E_OK


def cmd_accept(args, src, reg):
    if len(args) != 3:
        raise Fail("accept: SIDE ACTOR NOTE (ACTOR is * for claude)", E_USAGE)
    side, actor, note = args
    if "\t" in note or "\n" in note or not note.strip():
        raise Fail("accept: NOTE is one line without tabs: what was probed, in a fresh session", E_USAGE)
    if side == "claude":
        if actor != "*":
            raise Fail("accept: the Claude side has one settings file; ACTOR is *", E_USAGE)
        st, h = claude_state(src, CLAUDE_SETTINGS), claude_set_sha(src)
    elif side == "codex":
        if actor not in reg:
            raise Fail("accept: '%s' is not a registry key" % actor, E_USAGE)
        st = codex_state(src, reg, actor, True)
        h = st["sha"]
        if not h:
            raise Fail("accept: no grant renders for %s on Codex" % actor, E_USAGE)
    else:
        raise Fail("accept: the side must be claude or codex", E_USAGE)
    if not side_ok(st):
        raise Fail("accept: %s %s is not rendered and resolved; a probe can't be recorded" % (side, actor), E_FINDINGS)
    os.makedirs(os.path.dirname(ACCEPTED) or ".", exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(ACCEPTED, "a", encoding="utf-8") as f:
        if f.tell() == 0:
            f.write("# utc\tside\tactor\tsha256\tprobe\n")
        f.write("\t".join([stamp, side, actor, h, note]) + "\n")
    print("grants: accepted %s %s at %s" % (side, actor, short(h)))
    return E_OK


def cmd_baseline(args):
    b = bundled_baseline()
    print("codex baseline: cli %s, policy sha256 %s, %d bytes" % (b["cli"], b["sha"], b["bytes"]))
    if args[:1] == ["--write"] and len(args) == 2:
        path = args[1]
        if os.path.lexists(path):
            raise Fail("baseline: %s exists; pick a new file" % path, E_USAGE)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(b["text"])
        print("codex baseline: written to %s for a person to read; once read, add this row to Known Codex baselines:"
              % path)
        print("| %s | %s | %d | %s |" % (b["cli"], b["sha"], b["bytes"], TODAY))
    elif args:
        raise Fail("baseline: [--write FILE]", E_USAGE)
    return E_OK


def _interrupt(signum, frame):
    raise KeyboardInterrupt()


def main(argv):
    signal.signal(signal.SIGTERM, _interrupt)
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return E_USAGE if not argv else E_OK
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "baseline":
            return cmd_baseline(args)
        src, reg = load()
        if cmd == "validate":
            print("grants: file ok (%d grants: %s; sha %s)" % (
                len(src["grants"]), ", ".join(g["id"] for g in src["grants"]) or "none", short(src["sha"])))
            return E_OK
        if cmd == "render-claude":
            dry, prune = "--dry-run" in args, "--prune" in args
            if [a for a in args if a not in ("--dry-run", "--prune")]:
                raise Fail("render-claude: [--dry-run] [--prune]", E_USAGE)
            return render_claude(src, CLAUDE_SETTINGS, dry, prune)
        if cmd == "render-codex":
            out_dir, keys, rest = None, None, list(args)
            if "--out-dir" in rest:
                j = rest.index("--out-dir")
                out_dir = rest[j + 1]
                del rest[j:j + 2]
            if "--actor" in rest:
                j = rest.index("--actor")
                keys = [rest[j + 1]]
                del rest[j:j + 2]
            elif "--all" in rest:
                rest.remove("--all")
                keys = codex_targets(src, reg)
            if keys is None or [a for a in rest if a not in ("--dry-run", "--no-readback")]:
                raise Fail("render-codex: --actor KEY or --all, [--out-dir DIR] [--dry-run] [--no-readback]", E_USAGE)
            rc = E_OK
            for k in keys:
                try:
                    render_codex(src, reg, k, out_dir, "--dry-run" in rest, "--no-readback" not in rest)
                except Fail as e:
                    print(str(e), file=sys.stderr)
                    rc = max(rc, e.code)
            return rc
        if cmd == "check":
            return cmd_check(args, src, reg)
        if cmd == "accept":
            return cmd_accept(args, src, reg)
        raise Fail("unknown command %s (see --help)" % cmd, E_USAGE)
    except Fail as e:
        print("grants: %s" % e, file=sys.stderr)
        return e.code
    except IndexError:
        print("grants: bad arguments (see --help)", file=sys.stderr)
        return E_USAGE
    except KeyboardInterrupt:
        print("grants: interrupted; nothing reported as synchronized", file=sys.stderr)
        return E_FAIL
    except Exception as e:  # never a silent crash: hygiene and the switch gate treat this as not synchronized
        print("grants: internal error (%s); nothing reported as synchronized" % type(e).__name__, file=sys.stderr)
        return E_FAIL


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
