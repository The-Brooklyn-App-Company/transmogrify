#!/bin/sh
# check.sh - deterministic checks: links, duplicate rule text, skill shape,
# home layout, privacy, and host settings. Needs no profile (host reads one
# when present); safe to run in CI.
#
# Usage: check.sh kit
#        check.sh links [FILE...]
#        check.sh dupes [--min-words N] FILE...
#        check.sh skills [--max-lines N] DIR...
#        check.sh home DIR...
#        check.sh privacy [--denylist FILE] [PATH...]
#        check.sh leaks [--staged] [--no-denylist]
#        check.sh host
#
# kit      Run in a kit checkout (CI does): links over every tracked
#          Markdown file and skills over skills/ must pass, and
#          kit/KIT.md must stay within its byte budget (11100); duplicate
#          rule text across kit/, docs/operations/ and skills/ is reported as a warning.
# links    Every relative Markdown link [text](target) in the given files
#          (default: the Markdown files git tracks here) must name an
#          existing file or directory, and a #fragment must match a heading
#          in the target (GitHub's anchor rules, ASCII). Web, mail and
#          absolute links are not checked. Output: `file:line: target`.
# dupes    One home per rule: reports any sentence of at least N words
#          (default 10) that appears in more than one of the given Markdown
#          files, after normalising case, punctuation and Markdown markup.
#          Code blocks, table rules and link targets are ignored. Output, one
#          finding per line: `file:line, file:line: "sentence..."`.
# skills   Thin skills: reports every SKILL.md under DIR longer than N lines
#          (default 60) or with no pointer into docs/operations/ or ops/templates/.
# home     A kit-managed operator home: AGENTS.md and MANDATE.md exist;
#          CLAUDE.md, if present, only imports AGENTS.md (`@AGENTS.md`);
#          operator.conf, if present, has only key, session.<client>,
#          model.<client>, effort.<client>, archived and
#          work.<name>=<url>|owner|contributor lines. Across all DIRs, a
#          repository URL may have only one owner.
# privacy  Reports home-directory paths (a macOS user folder anywhere; a
#          Linux home folder, a ~user path or a Windows user folder at the
#          start of a path), e-mail addresses
#          (other than the reserved example.com/.org/.net and their
#          subdomains, .example, .test, .invalid and .localhost) and every
#          case-insensitive match of the lines in the denylist (default:
#          $AO_PRIVACY_DENYLIST), in file contents and in file names. A
#          denylist line starting with `=` matches whole words only (`=ann`
#          finds "Ann" but not "planned"). Binary files are listed as not
#          scanned. Keep the denylist local and untracked. PATHs default to
#          the files git tracks in the current directory. Matching lines are
#          printed as file:line only, never with their text, so the report
#          itself leaks nothing. Git history and author metadata are out of scope.
# leaks    The leakage guard for a public checkout: nothing owner- or
#          company-specific reaches the tree. Scans every tracked file (the
#          working copy, contents and names) and the staged copy of every
#          staged file (`staged:` in the output) with generic rules:
#            L01 a home folder (/Users/NAME, escaped or under /Volumes;
#                -Users-NAME-; C:\Users\NAME; /home/NAME) that is not a
#                fictional one (example, test, tester, owner, private, me,
#                person, user, you, runner, someone, name, shared)
#            L02 an e-mail address other than reserved example domains,
#                provider noreply addresses, git SSH users and the project
#                contact (package.json's author email)
#            L03 a Slack channel, user or team id (C, D, G, T, U or W, a
#                digit, then uppercase letters and digits; 9 to 12 long;
#                in URLs and paths too; not inside an integrity-hash value)
#            L04 an API key or token shape (sk-, sk_live_, gh?_,
#                github_pat_, glpat-, npm_, lin_api_, xox?-, xapp-, AKIA,
#                ASIA, AIza, a JWT, a Slack webhook URL) or a PEM private key
#                header
#            L05 a Keychain item named in a security(1) call
#          and, with a private denylist, D<n> for a match of its line n
#          (case-insensitive; `=word` matches whole words; a `!phrase` line
#          is an allowed phrase, such as the publisher's own name, blanked
#          out before matching). The denylist
#          comes from TRANSMOGRIFY_LEAK_DENYLIST, else the profile's
#          leak_denylist; it must live outside the repository and is never
#          committed. Output is `file:line: RULE` only, never the matched
#          text or a denylist line (a denylist match in a file name prints
#          that name). One stderr line says how many denylist rules ran. A
#          line carrying `leak-ok: RULE` is exempt from RULE. Tracked
#          symlinks are scanned as their target path, never followed. Each
#          file has a hard time budget (TRANSMOGRIFY_LEAK_FILE_SECONDS,
#          default 60); one that runs over it is stopped, reported as not
#          scanned, and the run fails.
#          --staged scans only what is staged (the pre-commit hook,
#          install.sh precommit); --no-denylist runs the generic rules only
#          (CI); --require-denylist fails (exit 2) without denylist rules (the
#          release check and a maintainer's hook).
# host     An always-on macOS host (reads the profile when there is one;
#          read-only). App Nap: every desktop app in host_apps that has run
#          here must have NSAppSleepDisabled set (fix: install.sh host, then
#          restart the app). launchd: every job in host_launchd_dirs whose
#          Label matches a host_latency_jobs pattern (default: the kit's own
#          tick and relay; add your schedulers, watchers, alert routes and
#          CI forwarders) must not set ProcessType Background (or Adaptive)
#          or LowPriorityIO: launchd throttles those. Output, one finding
#          per line: `app-nap: <bundle id>` or `launchd: <file>: <label>:
#          <setting>`. Without `defaults` the App Nap part is skipped.
#
# Exit codes: 0 clean; 1 findings, or a scan that could not complete (the
# message says which); 2 usage error.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"

# The rules file's byte budget (check.sh kit).
AO_KIT_BUDGET=11100

# check_need_number OPTION VALUE...  Die unless VALUE is an integer.
check_need_number() {
  if [ $# -lt 2 ] || ! ao_is_uint "$2"; then
    ao_die "$AO_E_USAGE" "$1 needs a number"
  fi
}

check_dupes() {
  min_words=10
  if [ "${1-}" = --min-words ]; then
    check_need_number "$@"
    min_words=$2
    shift 2
  fi
  [ $# -gt 0 ] || ao_die "$AO_E_USAGE" "dupes needs at least one file"
  for _f in "$@"; do [ -r "$_f" ] || ao_die "$AO_E_USAGE" "not readable: $_f"; done
  # awk would read an operand like `a=b` as an assignment; ./ prevents it.
  for _f in "$@"; do
    case $_f in /*) set -- "$@" "$_f" ;; *) set -- "$@" "./$_f" ;; esac
    shift
  done
  # Sentences are taken from whole paragraphs (consecutive non-blank lines;
  # each heading, list item, quote or table row starts a new one), so a rule
  # wrapped differently in two files still matches. Locations are the
  # paragraph's first line.
  found=$(ao_tmp found)
  awk -v minw="$min_words" '
    function flush(   t, n, i, s, parts, words) {
      if (buf == "") return
      t = tolower(buf)
      buf = ""
      gsub(/<!--[^>]*-->/, " ", t)
      gsub(/\]\([^)]*\)/, "]", t)
      n = split(t, parts, /[.!?;]([[:space:]]+|$)|[|]/)
      for (i = 1; i <= n; i++) {
        s = parts[i]
        gsub(/[^a-z0-9]+/, " ", s)
        gsub(/^ +| +$/, "", s)
        if (split(s, words, " ") < minw) continue
        if ((s, file) in seen) continue
        seen[s, file] = 1
        count[s]++
        where[s] = where[s] (where[s] == "" ? "" : ", ") file ":" start
      }
    }
    FNR == 1 { flush(); fence = 0; file = FILENAME }
    /^[[:space:]]*(```|~~~)/ { flush(); fence = !fence; next }
    fence { next }
    /^[[:space:]|:-]*$/ { flush(); next }
    /^[[:space:]]*([#>|]|[-*+][[:space:]]|[0-9]+[.)][[:space:]])/ { flush() }
    {
      if (buf == "") start = FNR
      buf = buf " " $0
    }
    END {
      flush()
      for (s in count) if (count[s] > 1) printf "%s: \"%s\"\n", where[s], substr(s, 1, 90)
    }' "$@" >"$found" || ao_die "$AO_E_USAGE" "duplicate scan failed"
  [ -s "$found" ] || return 0
  sort "$found"
  return "$AO_E_FAIL"
}

check_skills() {
  max_lines=60
  if [ "${1-}" = --max-lines ]; then
    check_need_number "$@"
    max_lines=$2
    shift 2
  fi
  [ $# -gt 0 ] || ao_die "$AO_E_USAGE" "skills needs at least one directory"
  for _d in "$@"; do [ -d "$_d" ] || ao_die "$AO_E_USAGE" "not a directory: $_d"; done
  skills=$(ao_tmp skills)
  find "$@" -name SKILL.md -type f >"$skills.raw" || ao_die "$AO_E_USAGE" "cannot list skills"
  sort "$skills.raw" >"$skills"
  _bad=0
  while IFS= read -r _s; do
    _n=$(wc -l <"$_s" | tr -d ' ')
    if [ "$_n" -gt "$max_lines" ]; then
      printf '%s: %s lines (cap %s)\n' "$_s" "$_n" "$max_lines"
      _bad=1
    fi
    if ! grep -Eq '(docs|templates)/' "$_s"; then
      printf '%s: no pointer into docs/operations/ or ops/templates/\n' "$_s"
      _bad=1
    fi
  done <"$skills"
  [ "$_bad" -eq 0 ] || return "$AO_E_FAIL"
}

# check_links [FILE...]  Report dead relative links and fragments.
check_links() {
  if [ $# -eq 0 ]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      ao_die "$AO_E_USAGE" "not a git checkout; pass files explicitly"
    _list=$(ao_tmp mdlist)
    git ls-files -z -- '*.md' >"$_list" || ao_die "$AO_E_USAGE" "git ls-files failed"
    [ -s "$_list" ] || return 0
    xargs -0 "$AO_SCRIPTS/check.sh" links <"$_list"
    return
  fi
  _bad=0
  for _f in "$@"; do
    [ -r "$_f" ] || ao_die "$AO_E_USAGE" "not readable: $_f"
    _dir=$(dirname -- "$_f")
    # One line per link: LINE<TAB>TARGET (code blocks and spans skipped).
    check_link_targets "$_f" >"$AO_TMPDIR/links" || ao_die "$AO_E_FAIL" "cannot read links in $_f"
    while IFS="$AO_TAB" read -r _ln _t; do
      case $_t in
        '' | http:* | https:* | mailto:* | /*) continue ;;
        '#'*) _path=$_f _frag=${_t#\#} ;;
        *'#'*) _path=$_dir/${_t%%#*} _frag=${_t#*#} ;;
        *) _path=$_dir/$_t _frag= ;;
      esac
      if [ ! -e "$_path" ]; then
        printf '%s:%s: %s\n' "$_f" "$_ln" "$_t"
        _bad=1
      elif [ -n "$_frag" ] && [ -f "$_path" ] && ! check_link_anchors "$_path" | grep -Fxq -- "$_frag"; then
        printf '%s:%s: %s (no such heading)\n' "$_f" "$_ln" "$_t"
        _bad=1
      fi
    done <"$AO_TMPDIR/links"
  done
  [ "$_bad" -eq 0 ] || return "$AO_E_FAIL"
}

check_link_targets() {
  case $1 in /*) _op=$1 ;; *) _op=./$1 ;; esac
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)
      while (match(line, /\]\([^)[:space:]]+\)/)) {
        t = substr(line, RSTART + 2, RLENGTH - 3)
        line = substr(line, RSTART + RLENGTH)
        print FNR "\t" t
      }
    }' "$_op"
}

# check_link_anchors FILE  Print the GitHub anchor of every heading.
check_link_anchors() {
  case $1 in /*) _op=$1 ;; *) _op=./$1 ;; esac
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    /^#+[[:space:]]/ {
      h = $0
      sub(/^#+[[:space:]]+/, "", h)
      sub(/[[:space:]]+#+[[:space:]]*$/, "", h)
      h = tolower(h)
      gsub(/[^a-z0-9 _-]/, "", h)
      gsub(/ /, "-", h)
      if (h in seen) { n = seen[h]++; print h "-" n } else { seen[h] = 1; print h }
    }' "$_op"
}

# check_home DIR...  Kit-managed home layout and single ownership.
check_home() {
  [ $# -gt 0 ] || ao_die "$AO_E_USAGE" "home needs at least one directory"
  _bad=0
  _owners=$(ao_tmp owners)
  for _h in "$@"; do
    [ -d "$_h" ] || ao_die "$AO_E_USAGE" "not a directory: $_h"
    for _req in AGENTS.md MANDATE.md; do
      [ -f "$_h/$_req" ] || { printf '%s: missing %s\n' "$_h" "$_req"; _bad=1; }
    done
    if [ -f "$_h/CLAUDE.md" ] && [ "$(grep -v '^[[:space:]]*$' "$_h/CLAUDE.md")" != "@AGENTS.md" ]; then
      printf '%s/CLAUDE.md: must contain only @AGENTS.md\n' "$_h"
      _bad=1
    fi
    [ -f "$_h/operator.conf" ] || continue
    _n=0
    while IFS= read -r _l || [ -n "$_l" ]; do
      _n=$((_n + 1))
      case $_l in '' | '#'*) continue ;; esac
      _k=${_l%%=*} _v=${_l#*=}
      case $_k in
        key) ao_is_name "$_v" || { printf '%s/operator.conf:%s: invalid key\n' "$_h" "$_n"; _bad=1; } ;;
        session.claude | session.codex | session.custom | session.file-only) ;;
        model.claude | model.codex | effort.claude | effort.codex)
          case $_v in '' | *[!A-Za-z0-9._:-]*) printf '%s/operator.conf:%s: %s must be one word\n' "$_h" "$_n" "$_k"; _bad=1 ;; esac ;;
        archived) ;;
        work.*)
          case $_v in
            *'|owner') printf '%s\t%s\n' "$(ao_repo_key "${_v%|owner}")" "$_h" >>"$_owners" ;;
            *'|contributor') ;;
            *) printf '%s/operator.conf:%s: work value must end in |owner or |contributor\n' "$_h" "$_n"; _bad=1 ;;
          esac ;;
        *) printf '%s/operator.conf:%s: unknown key %s\n' "$_h" "$_n" "$_k"; _bad=1 ;;
      esac
    done <"$_h/operator.conf"
  done
  _dups=$(cut -f 1 "$_owners" | sort | uniq -d)
  if [ -n "$_dups" ]; then
    printf '%s\n' "$_dups" | while IFS= read -r _u; do printf 'owned by more than one home: %s\n' "$_u"; done
    _bad=1
  fi
  [ "$_bad" -eq 0 ] || return "$AO_E_FAIL"
}

# check_kit  The kit repository's own gate.
check_kit() {
  [ -f kit/KIT.md ] && [ -d skills ] || ao_die "$AO_E_USAGE" "run check.sh kit at the root of a kit checkout"
  _rc=0
  check_links || _rc=$AO_E_FAIL
  check_skills skills || _rc=$AO_E_FAIL
  # The rules stay readable in one sitting: a new rule replaces words, it
  # does not add them (K-32).
  _kb=$(wc -c <kit/KIT.md | tr -d ' ')
  if [ "$_kb" -gt "$AO_KIT_BUDGET" ]; then
    printf 'kit/KIT.md is %s bytes, over its budget of %s: replace rather than add (K-32)\n' "$_kb" "$AO_KIT_BUDGET"
    _rc=$AO_E_FAIL
  fi
  set -- kit/KIT.md docs/operations/*.md skills/*/SKILL.md
  if ! _d=$(check_dupes "$@"); then
    printf 'warning: duplicated rule text (keep one home, point to it):\n%s\n' "$_d"
  fi
  return "$_rc"
}

# check_privacy_each PATTERNS FILE...  Scan each text file (internal entry
# point, run through xargs -0 / find -exec so any file name is safe). Exits
# 2 if a file cannot be read.
check_privacy_each() {
  _pat=$1
  shift
  _rc=0
  for _f in "$@"; do
    [ -f "$_f" ] || continue
    [ -r "$_f" ] || { ao_warn "cannot read $_f"; _rc=2; continue; }
    check_privacy_name "$_f" "$_pat"
    # grep: 0 text, 1 binary or empty, 2 error (fail).
    grep -qI . -- "$_f" 2>/dev/null
    case $? in
      0) ;;
      1) [ ! -s "$_f" ] || printf '%s: binary, not scanned\n' "$_f"; continue ;;
      *) ao_warn "cannot read $_f"; _rc=2; continue ;;
    esac
    check_privacy_scan "$_f" "$_pat" || { ao_warn "could not scan $_f"; _rc=2; }
  done
  return "$_rc"
}

# check_privacy_name FILE PATTERNS  Report a denylist match in the path.
check_privacy_name() {
  AO_F=$1 AO_P=$2 awk 'BEGIN {
    f = ENVIRON["AO_F"]; low = tolower(f)
    while ((getline p < ENVIRON["AO_P"]) > 0) {
      p = tolower(p); w = 0
      if (substr(p, 1, 1) == "=") { p = substr(p, 2); w = 1 }
      if (p == "") continue
      if (w ? wordin(low, p) : index(low, p)) { print f ": denylist match in the file name"; exit }
    }
  }
  '"$CHECK_AWK_WORDIN"
}

# Shared awk: wordin(text, word) is true when word occurs in text with no
# letter or digit on either side.
CHECK_AWK_WORDIN='
  function wordin(t, w,   i, b, a) {
    while ((i = index(t, w)) > 0) {
      b = i > 1 ? substr(t, i - 1, 1) : ""
      a = substr(t, i + length(w), 1)
      if (b !~ /[a-z0-9]/ && a !~ /[a-z0-9]/) return 1
      t = substr(t, i + 1)
    }
    return 0
  }'


# check_privacy_scan FILE PATTERNS  Print `FILE:LINE: kind` for each finding.
# File names travel through the environment, never through program text.
check_privacy_scan() {
  case $1 in /*) _op=$1 ;; *) _op=./$1 ;; esac
  AO_F=$1 AO_P=$2 awk '
    BEGIN {
      f = ENVIRON["AO_F"]
      while ((getline p < ENVIRON["AO_P"]) > 0) {
        p = tolower(p); w = 0
        if (substr(p, 1, 1) == "=") { p = substr(p, 2); w = 1 }
        if (p != "") { deny[++nd] = p; word[nd] = w }
      }
    }
    {
      if ($0 ~ /\/Users\/[A-Za-z0-9._-]+/ || $0 ~ /(^|[^A-Za-z0-9_}.$-])\/home\/[A-Za-z0-9._-]+/ || $0 ~ /(^|[^A-Za-z0-9])~[a-z][a-z0-9_-]*\// || $0 ~ /[A-Za-z]:(\\)+Users(\\)+/) print f ":" FNR ": home path"
      rest = $0
      while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/)) {
        addr = tolower(substr(rest, RSTART, RLENGTH))
        rest = substr(rest, RSTART + RLENGTH)
        if (addr !~ /@([a-z0-9-]+\.)*(example\.(com|org|net)|example|test|invalid|localhost)$/) {
          print f ":" FNR ": e-mail address"
          break
        }
      }
      low = tolower($0)
      for (i = 1; i <= nd; i++) if (word[i] ? wordin(low, deny[i]) : index(low, deny[i])) { print f ":" FNR ": denylist match"; break }
    }
    '"$CHECK_AWK_WORDIN" "$_op"
}

check_privacy() {
  denylist=${AO_PRIVACY_DENYLIST:-}
  if [ "${1-}" = --denylist ]; then
    [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--denylist needs a file"
    denylist=$2
    shift 2
  fi
  patterns=$(ao_tmp patterns)
  if [ -n "$denylist" ]; then
    [ -r "$denylist" ] || ao_die "$AO_E_USAGE" "denylist not readable: $denylist"
    # Blank lines would match everything; # lines are comments.
    grep -v -e '^[[:space:]]*$' -e '^#' "$denylist" >"$patterns"
  fi
  hits=$(ao_tmp hits)
  _err=0
  if [ $# -eq 0 ]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
      ao_die "$AO_E_USAGE" "not a git checkout; pass paths explicitly"
    # NUL-delimited, so tracked names with quotes or newlines are scanned too.
    inventory=$(ao_tmp inventory)
    git ls-files -z >"$inventory" || ao_die "$AO_E_USAGE" "git ls-files failed"
    if [ -s "$inventory" ]; then
      xargs -0 "$AO_SCRIPTS/check.sh" __scan "$patterns" <"$inventory" >"$hits" || _err=1
    fi
  else
    for _p in "$@"; do [ -e "$_p" ] || ao_die "$AO_E_USAGE" "no such path: $_p"; done
    for _p in "$@"; do
      case $_p in -*) _p=./$_p ;; esac
      find "$_p" -type f ! -path '*/.git/*' -exec "$AO_SCRIPTS/check.sh" __scan "$patterns" {} + >>"$hits" || _err=1
    done
  fi
  _hits=$(sort -u "$hits") || _err=1
  if [ "$_err" -ne 0 ]; then
    [ -z "$_hits" ] || printf '%s\n' "$_hits"
    ao_msg "privacy scan incomplete: some files could not be read"
    return "$AO_E_FAIL"
  fi
  [ -z "$_hits" ] && return 0
  printf '%s\n' "$_hits"
  return "$AO_E_FAIL"
}

# check_host  App Nap and launchd priority on an always-on host.
check_host() {
  [ $# -eq 0 ] || ao_die "$AO_E_USAGE" "usage: check.sh host"
  _pf=$(ao_profile_path)
  [ ! -r "$_pf" ] || ao_profile_parse "$_pf"
  _apps=$(ao_cfg host_apps "$AO_HOST_APPS")
  _jobs=$(ao_cfg host_latency_jobs "$AO_HOST_LATENCY_JOBS")
  _dirs=$(ao_cfg host_launchd_dirs "$AO_HOST_LAUNCHD_DIRS")
  _hits=$(ao_tmp host-hits)
  if command -v defaults >/dev/null 2>&1 && [ "$_apps" != none ]; then
    for _id in $_apps; do
      # Only apps that have run here (their defaults domain exists).
      defaults read "$_id" >/dev/null 2>&1 || continue
      [ "$(defaults read "$_id" NSAppSleepDisabled 2>/dev/null)" = 1 ] ||
        printf 'app-nap: %s (fix: install.sh host, then restart the app)\n' "$_id" >>"$_hits"
    done
  fi
  [ "$_jobs" != none ] || _dirs=
  set -f
  for _d in $_dirs; do
    set +f
    _d=$(ao_expand_path "$_d" /)
    for _p in "$_d"/*.plist; do
      [ -f "$_p" ] || continue
      check_host_plist "$_p" "$_jobs" >>"$_hits"
    done
    set -f
  done
  set +f
  [ -s "$_hits" ] || return 0
  cat "$_hits"
  return "$AO_E_FAIL"
}

# check_host_plist FILE PATTERNS  Print a finding for a latency-sensitive
# job that launchd would throttle. Binary plists are read through plutil.
check_host_plist() {
  if command -v plutil >/dev/null 2>&1; then
    _xml=$(plutil -convert xml1 -o - "$1" 2>/dev/null) || _xml=$(cat "$1")
  else
    _xml=$(cat "$1")
  fi
  # Top-level keys of the outer <dict> only (nested dictionaries such as
  # EnvironmentVariables never count): `key type value` per line.
  _kv=$(printf '%s\n' "$_xml" | tr -d '\n\t' | sed 's|<|\
<|g' | awk '
    /^<dict>/ { depth++; if (depth > 1) k = ""; next }
    /^<\/dict>/ { depth--; next }
    /^<array>/ { depth++; k = ""; next }
    /^<\/array>/ { depth--; next }
    depth != 1 { next }
    /^<key>/ { k = substr($0, 6); next }
    k != "" && /^<[a-z]+\/?>/ {
      t = $0; sub(/^</, "", t); v = t; sub(/[\/]?>.*/, "", t); sub(/^[^>]*>/, "", v)
      print k, t, v; k = ""
    }')
  _label=$(printf '%s\n' "$_kv" | awk '$1 == "Label" { print $3; exit }')
  [ -n "$_label" ] || return 0
  _hit=
  set -f
  for _pat in $2; do
    # shellcheck disable=SC2254 # the pattern is a glob on purpose
    case $_label in $_pat) _hit=1 ;; esac
  done
  set +f
  [ -n "$_hit" ] || return 0
  _pt=$(printf '%s\n' "$_kv" | awk '$1 == "ProcessType" { print $3; exit }')
  case $_pt in Background | Adaptive) printf 'launchd: %s: %s: ProcessType %s (use Standard or leave it unset)\n' "$1" "$_label" "$_pt" ;; esac
  printf '%s\n' "$_kv" | awk '$1 == "LowPriorityIO" && $2 == "true" { f = 1 } END { exit !f }' &&
    printf 'launchd: %s: %s: LowPriorityIO true (remove it)\n' "$1" "$_label"
  return 0
}

# ---------------------------------------------------------------- leaks
# The leakage guard: owner- or company-specific text must not reach the
# public tree. Rule ids are printed, never the matched text.

# Fictional home folders the docs and tests use on purpose.
CHECK_LEAK_HOMES='example examples test tests tester owner private me person user users you runner someone name shared'

# check_leak_scan FILE SHOWNAME PATTERNS CONTACT  Print `SHOWNAME:LINE: RULE`
# once per rule and line in FILE's text, and `SHOWNAME: D<n> (file name)`
# for a denylist match in the name. File names, the contact and the
# denylist reach awk through the environment, never through program text. A
# line carrying `leak-ok: RULE` is exempt from RULE.
# Each file gets a hard time budget (TRANSMOGRIFY_LEAK_FILE_SECONDS, default
# 60): a scan that runs over it is stopped, its whole process group killed,
# and the file reported as not scanned, so the guard can never spin forever.
check_leak_scan() {
  case $1 in /*) _lf=$1 ;; *) _lf=./$1 ;; esac
  _lb=${TRANSMOGRIFY_LEAK_FILE_SECONDS:-60}
  ao_is_uint "$_lb" && [ "$_lb" -gt 0 ] || ao_die "$AO_E_USAGE" "TRANSMOGRIFY_LEAK_FILE_SECONDS must be a positive integer"
  AO_N=$2 AO_P=$3 AO_C=$4 AO_H=$CHECK_LEAK_HOMES
  export AO_N AO_P AO_C AO_H
  # shellcheck disable=SC2016 # the awk program is literal text
  ao_timeout "$_lb" awk '
    # exempt(rule): the line carries `leak-ok: RULE` with no letter or digit
    # after the id (leak-ok: D12 does not exempt D1).
    function exempt(rule,   t, k, c) {
      t = $0
      while ((k = index(t, "leak-ok: " rule)) > 0) {
        c = substr(t, k + 9 + length(rule), 1)
        if (c !~ /[A-Za-z0-9]/) return 1
        t = substr(t, k + 1)
      }
      return 0
    }
    function hit(rule) {
      if ((rule in seen) || exempt(rule)) return
      print n ":" FNR ": " rule; seen[rule] = 1
    }
    function home(name) { if (!(tolower(name) in homes)) hit("L01") }
    # Only a token inside the payload of an explicitly labelled integrity
    # hash is exempt. A hash elsewhere on the line, or +/= in an arbitrary
    # run, is not evidence that a URL/path identifier is encoded data.
    function inhash(line, st, len,   i, j, run, prefix, algorithm, payload) {
      i = st; while (i > 1 && substr(line, i - 1, 1) ~ /[A-Za-z0-9+\/=]/) i--
      j = st + len; while (j <= length(line) && substr(line, j, 1) ~ /[A-Za-z0-9+\/=]/) j++
      run = substr(line, i, j - i)
      prefix = substr(line, 1, i - 1)
      if (prefix !~ /(^|[^A-Za-z0-9_\/])sha(1|256|384|512)-$/) return 0
      algorithm = prefix; sub(/^.*sha/, "", algorithm); sub(/-$/, "", algorithm)
      payload = run; sub(/=+$/, "", payload)
      if (payload ~ /[^A-Za-z0-9+\/]/) return 0
      # Require the digest length and canonical base64 padding for this algorithm.
      if (algorithm == "384") return length(run) == 64 && run !~ /=/
      if (algorithm == "512") return length(run) == 88 && run ~ /[AQgw]==$/
      return length(run) == (algorithm == "1" ? 28 : 44) && run ~ /[AEIMQUYcgkosw048]=$/
    }
    # jwt(line): three dot-separated base64url parts after "eyJ".
    function jwt(line,   t, k, parts, np, x) {
      t = line
      while ((k = index(t, "eyJ")) > 0) {
        t = substr(t, k)
        x = t; sub(/[^A-Za-z0-9_.-].*$/, "", x)
        np = split(x, parts, ".")
        if (np >= 3 && length(parts[1]) >= 10 && length(parts[2]) >= 10 && length(parts[3]) >= 10) return 1
        t = substr(t, 4)
      }
      return 0
    }
    function slackid(t,   i, c, d, l) {
      if (substr(t, 2, 1) !~ /[0-9]/) return 0
      d = 0; l = 0
      for (i = 2; i <= length(t); i++) {
        c = substr(t, i, 1)
        if (c ~ /[0-9]/) d++
        else if (c ~ /[A-Z]/) l++
        else return 0
      }
      return d > 0 && l > 1
    }
    # blank(t): t with every allowed phrase (denylist lines `!phrase`) spaced out.
    function blank(t,   i, k, sp) {
      for (i = 1; i <= na; i++)
        while ((k = index(t, allow[i])) > 0) {
          sp = sprintf("%" length(allow[i]) "s", "")
          t = substr(t, 1, k - 1) sp substr(t, k + length(allow[i]))
        }
      return t
    }
    function allup(t,   i) {
      for (i = 1; i <= length(t); i++) if (substr(t, i, 1) !~ /[A-Z0-9]/) return 0
      return 1
    }
    BEGIN {
      n = ENVIRON["AO_N"]; contact = tolower(ENVIRON["AO_C"]); sq = sprintf("%c", 39)
      nh = split(ENVIRON["AO_H"], hl, " "); for (i = 1; i <= nh; i++) homes[hl[i]] = 1
      while ((getline p < ENVIRON["AO_P"]) > 0) {
        nd++
        sub(/\r$/, "", p); sub(/[ \t]+$/, "", p)
        p = tolower(p); w = 0
        if (p ~ /^[ \t]*$/ || p ~ /^[ \t]*#/) continue
        if (substr(p, 1, 1) == "!") { p = substr(p, 2); if (p !~ /^[ \t]*$/) allow[++na] = p; continue }
        if (substr(p, 1, 1) == "=") { p = substr(p, 2); w = 1 }
        if (p ~ /^[ \t]*$/) continue
        deny[nd] = p; word[nd] = w
      }
      low = blank(tolower(n))
      for (i = 1; i <= nd; i++) if ((i in deny) && (word[i] ? wordin(low, deny[i]) : index(low, deny[i]))) { print n ": D" i " (file name)"; break }
    }
    {
      split("", seen)
      # L01: a home folder that is not one of the fictional ones: /Users/NAME
      # anywhere (also escaped, \/Users\/NAME, and under /Volumes or
      # /System/Volumes/Data), its dash encoding -Users-NAME- (project
      # folder names), C:\Users\NAME, and /home/NAME at the start of a path.
      rest = $0; gsub(/\\/, "", rest)
      while (match(rest, /\/Users\/[A-Za-z0-9._-]+/)) {
        seg = substr(rest, RSTART + 7, RLENGTH - 7); rest = substr(rest, RSTART + RLENGTH)
        home(seg)
      }
      rest = $0
      while (match(rest, /-Users-[A-Za-z0-9._]+-/)) {
        seg = substr(rest, RSTART + 7, RLENGTH - 8); rest = substr(rest, RSTART + RLENGTH - 1)
        home(seg)
      }
      rest = $0
      while (match(rest, /[A-Za-z]:\\+Users\\+[A-Za-z0-9._-]+/)) {
        seg = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        sub(/^.*\\/, "", seg)
        home(seg)
      }
      rest = $0
      while (match(rest, /\/home\/[A-Za-z0-9._-]+/)) {
        pre = RSTART > 1 ? substr(rest, RSTART - 1, 1) : ""
        seg = substr(rest, RSTART + 6, RLENGTH - 6); rest = substr(rest, RSTART + RLENGTH)
        if (pre !~ /[A-Za-z0-9_}.$-]/) home(seg)
      }
      # L02: an e-mail address other than a reserved domain, a provider noreply
      # address, the SSH user of the public git hosts and the project contact (a
      # handle at users.noreply.github.com names a GitHub account).
      rest = $0
      while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/)) {
        addr = tolower(substr(rest, RSTART, RLENGTH)); rest = substr(rest, RSTART + RLENGTH)
        if (addr ~ /@([a-z0-9-]+\.)*(example\.(com|org|net)|example|test|invalid|localhost)$/) continue
        if (addr ~ /^git@(github\.com|gitlab\.com|bitbucket\.org)$/ || addr ~ /^noreply@(anthropic|openai|github)\.com$/) continue
        if (contact != "" && addr == contact) continue
        hit("L02"); break
      }
      # L03: Slack ids, on alphanumeric tokens (SLACK_CHANNEL=..., /archives/...,
      # message, client and thread links, slack-...), unless the token sits
      # inside an integrity-hash payload.
      rest = $0; off = 0
      while (match(rest, /[A-Za-z0-9]+/)) {
        st = off + RSTART; t = substr(rest, RSTART, RLENGTH); l = RLENGTH
        off += RSTART + RLENGTH - 1; rest = substr(rest, RSTART + RLENGTH)
        if (l >= 9 && l <= 12 && substr(t, 1, 1) ~ /[CDGTUW]/ && slackid(t) && !inhash($0, st, l)) hit("L03")
      }
      # L04: API keys and tokens by shape.
      rest = $0
      while (match(rest, /[A-Za-z0-9_-]+/)) {
        t = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        l = length(t)
        if ((substr(t, 1, 3) == "sk-" && l >= 24) ||
            (t ~ /^[rs]k_(live|test)_/ && l >= 24) ||
            (substr(t, 1, 4) ~ /^gh[oprsu]_$/ && l >= 40) ||
            (substr(t, 1, 11) == "github_pat_" && l >= 40) ||
            (substr(t, 1, 6) == "glpat-" && l >= 20) ||
            (substr(t, 1, 4) == "npm_" && l >= 36) ||
            (substr(t, 1, 8) == "lin_api_" && l >= 40) ||
            (substr(t, 1, 5) ~ /^xox[abprs]-$/ && l >= 20) ||
            (substr(t, 1, 5) == "xapp-" && l >= 20) ||
            (substr(t, 1, 4) ~ /^(AKIA|ASIA)$/ && l == 20 && allup(t)) ||
            (substr(t, 1, 4) == "AIza" && l == 39)) hit("L04")
      }
      if (index($0, "PRIVATE KEY-----") || index($0, "hooks.slack.com/services/") || jwt($0)) hit("L04") # leak-ok: L04 (the rule itself)
      # L05: a Keychain item named in a security(1) call: a quoted name, or a
      # bare one on a shell line; a $variable or <placeholder> is fine.
      i = 0
      if (index($0, "generic-password")) {
        i = index($0, " -s "); off = 4
        if (!i) { i = index($0, sq "-s" sq); off = 4 }
        if (!i) { i = index($0, "\"-s\""); off = 4 }
      }
      if (i) {
        v = substr($0, i + off); q = 0
        while (v != "") {
          c = substr(v, 1, 1)
          if (c == sq || c == "\"") q = 1
          else if (c != " " && c != "\t" && c != ",") break
          v = substr(v, 2)
        }
        c = substr(v, 1, 1)
        if (v != "" && c != "$" && c != "<" && (q || index($0, "security "))) hit("L05")
      }
      # D<n>: line n of the private denylist, after its allowed phrases are blanked.
      low = blank(tolower($0))
      for (i = 1; i <= nd; i++) if ((i in deny) && (word[i] ? wordin(low, deny[i]) : index(low, deny[i]))) hit("D" i)
    }
    '"$CHECK_AWK_WORDIN" "$_lf"
  _lrc=$?
  if [ "$_lrc" -eq "$AO_E_TIMEOUT" ]; then
    printf '%s: not scanned (stopped after the %s s budget)\n' "$2" "$_lb"
    return 2
  fi
  return "$_lrc"
}

# check_leaks_each PATTERNS CONTACT FILE...  Scan tracked text files
# (internal entry point, run through xargs -0 so any file name is safe).
check_leaks_each() {
  _pat=$1 _con=$2
  shift 2
  _rc=0
  _lnk=$(ao_tmp leak-link)
  for _f in "$@"; do
    # A tracked symlink is its target path (what git stores), never followed.
    if [ -L "$_f" ]; then
      readlink "$_f" >"$_lnk" 2>/dev/null || { ao_warn "cannot read the link $_f"; _rc=2; continue; }
      check_leak_scan "$_lnk" "$_f" "$_pat" "$_con" || _rc=2
      continue
    fi
    [ -f "$_f" ] || continue
    [ -r "$_f" ] || { ao_warn "cannot read $_f"; _rc=2; continue; }
    grep -qI . -- "$_f" 2>/dev/null
    case $? in 0) ;; 1) continue ;; *) ao_warn "cannot read $_f"; _rc=2; continue ;; esac
    check_leak_scan "$_f" "$_f" "$_pat" "$_con" || _rc=2
  done
  return "$_rc"
}

# check_leaks_staged PATTERNS CONTACT FILE...  Scan the staged copy of each
# file (internal entry point, run through xargs -0 in the checkout's root).
check_leaks_staged() {
  _pat=$1 _con=$2
  shift 2
  _rc=0
  _blob=$(ao_tmp leak-blob)
  for _f in "$@"; do
    git show ":$_f" >"$_blob" 2>/dev/null || { ao_warn "cannot read the staged $_f"; _rc=2; continue; }
    grep -qI . "$_blob" 2>/dev/null || continue
    check_leak_scan "$_blob" "staged:$_f" "$_pat" "$_con" || _rc=2
  done
  return "$_rc"
}

# check_realfile PATH  PATH with every symlink resolved (the file itself and
# its folders), for the inside-the-repository test.
check_realfile() {
  _rf=$1 _rn=0
  while [ -L "$_rf" ] && [ "$_rn" -lt 40 ]; do
    _rt=$(readlink "$_rf") || return 1
    case $_rt in /*) _rf=$_rt ;; *) _rf=$(dirname -- "$_rf")/$_rt ;; esac
    _rn=$((_rn + 1))
  done
  [ ! -L "$_rf" ] || return 1
  printf '%s/%s\n' "$(CDPATH='' cd -- "$(dirname -- "$_rf")" && pwd -P)" "${_rf##*/}"
}

# check_leaks [--staged] [--no-denylist | --require-denylist]
check_leaks() {
  _ls_staged='' _ls_deny=1 _ls_req=''
  while [ $# -gt 0 ]; do
    case $1 in
      --staged) _ls_staged=1 ;;
      --no-denylist) _ls_deny='' ;;
      --require-denylist) _ls_req=1 ;;
      *) ao_die "$AO_E_USAGE" "usage: check.sh leaks [--staged] [--no-denylist | --require-denylist]" ;;
    esac
    shift
  done
  [ -z "$_ls_req" ] || [ -n "$_ls_deny" ] || ao_die "$AO_E_USAGE" "--require-denylist and --no-denylist exclude each other"
  _top=$(git rev-parse --show-toplevel 2>/dev/null) || ao_die "$AO_E_USAGE" "check.sh leaks runs inside a git checkout"
  _top=$(CDPATH='' cd -- "$_top" && pwd -P)
  patterns=$(ao_tmp leak-patterns)
  : >"$patterns"
  if [ -n "$_ls_deny" ]; then
    _dl=${TRANSMOGRIFY_LEAK_DENYLIST:-}
    if [ -z "$_dl" ]; then
      _pf=$(ao_profile_path)
      if [ -r "$_pf" ]; then ao_profile_parse "$_pf"; _dl=$(ao_cfg_path leak_denylist ''); fi
    fi
    if [ -n "$_dl" ]; then
      [ -f "$_dl" ] && [ -r "$_dl" ] || ao_die "$AO_E_USAGE" "the leak denylist is not a readable file (TRANSMOGRIFY_LEAK_DENYLIST or the profile's leak_denylist)"
      _dr=$(check_realfile "$_dl") || ao_die "$AO_E_USAGE" "cannot resolve the leak denylist's real location"
      case $_dr in "$_top"/*) ao_die "$AO_E_USAGE" "the leak denylist must live outside this repository (it is never committed)" ;; esac
      # Line numbers are kept: the rule id is D<line>; the text never prints.
      cp "$_dl" "$patterns" || ao_die "$AO_E_USAGE" "cannot read the leak denylist"
    fi
  fi
  # One line on stderr, counts only, so a run without the denylist is visible.
  _nr=$(sed -e 's/\r$//' "$patterns" | awk '!/^[ \t]*$/ && !/^[ \t]*#/ && !/^!/ { n++ } END { print n + 0 }')
  _na=$(sed -e 's/\r$//' "$patterns" | awk '/^![ \t]*[^ \t]/ { n++ } END { print n + 0 }')
  if [ "$_nr" -gt 0 ]; then
    printf 'leaks: denylist: %s rules, %s allowed phrases\n' "$_nr" "$_na" >&2
  else
    printf 'leaks: no denylist: generic rules only\n' >&2
    [ -z "$_ls_req" ] || ao_die "$AO_E_USAGE" "--require-denylist: no denylist rules (set TRANSMOGRIFY_LEAK_DENYLIST or the profile's leak_denylist)"
  fi
  _con=$(sed -n 's/^ *"email": *"\([^"]*\)".*/\1/p' "$_top/package.json" 2>/dev/null | head -n 1)
  hits=$(ao_tmp leak-hits)
  : >"$hits"
  _err=0
  list=$(ao_tmp leak-list)
  if [ -z "$_ls_staged" ]; then
    (cd "$_top" && git ls-files -z) >"$list" || ao_die "$AO_E_USAGE" "git ls-files failed"
    if [ -s "$list" ]; then
      (cd "$_top" && xargs -0 sh "$AO_SCRIPTS/check.sh" __leaks "$patterns" "$_con" <"$list") >>"$hits" || _err=1
    fi
  fi
  # The staged copy of every added, copied, modified or renamed file.
  (cd "$_top" && git diff --cached --name-only -z --diff-filter=ACMR) >"$list" || _err=1
  if [ -s "$list" ]; then
    (cd "$_top" && xargs -0 sh "$AO_SCRIPTS/check.sh" __leaks_staged "$patterns" "$_con" <"$list") >>"$hits" || _err=1
  fi
  _hits=$(sort -u "$hits") || _err=1
  [ -z "$_hits" ] || printf '%s\n' "$_hits"
  if [ "$_err" -ne 0 ]; then
    ao_msg "leak scan incomplete: some files could not be read"
    return "$AO_E_FAIL"
  fi
  [ -z "$_hits" ] || return "$AO_E_FAIL"
}

main() {
  case ${1-} in
    kit) shift; check_kit "$@" ;;
    links) shift; check_links "$@" ;;
    home) shift; check_home "$@" ;;
    dupes) shift; check_dupes "$@" ;;
    skills) shift; check_skills "$@" ;;
    privacy) shift; check_privacy "$@" ;;
    host) shift; check_host "$@" ;;
    leaks) shift; check_leaks "$@" ;;
    __scan) shift; check_privacy_each "$@" ;;
    __leaks) shift; check_leaks_each "$@" ;;
    __leaks_staged) shift; check_leaks_staged "$@" ;;
    -h | --help) ao_usage; exit 0 ;;
    *) ao_die "$AO_E_USAGE" "usage: check.sh kit|links|dupes|skills|home|privacy|leaks|host ... (see --help)" ;;
  esac
}

main "$@"
