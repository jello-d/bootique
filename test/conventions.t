#!/bin/sh
# conventions.t - the house conventions (shared-notes/_common.md, "Code style"
# and the Equal-weight rules), ENFORCED by the suite. They are not hooked yet,
# deliberately, so that the trees can be brought into line before anything
# blocks a commit; asserting them here means bootique arrives compliant and
# stays that way, and a violation is caught by whoever introduced it rather
# than by whoever next runs a hook.
#
# Every check draws its corpus from `git ls-files`, so adding a file to the
# repo puts it under these rules automatically. A hand-written list is the
# thing that goes stale: it reports clean over a corpus that quietly shrank.
# shellcheck source=test/harness_lib
. "$(dirname "$0")/harness_lib"
harness_init conventions

_files=$(cd "$HERE" && git ls-files 2>/dev/null) || _files=
# A check that cannot see its corpus must FAIL, not pass. This repo has already
# been bitten once by the other shape: `find ! -user <unknown>` errors and
# prints nothing, so an ownership check "passed" having looked at nothing.
[ -n "$_files" ] || fail "cannot list tracked files (git ls-files produced
  nothing). Every check here draws its corpus from git; without it they would
  all pass having looked at nothing."

_shebang() { head -1 "$1" 2>/dev/null; }
_has_shebang() { [ "$(head -c 2 "$1" 2>/dev/null)" = '#!' ]; }

_n=0

# --- 1. every executable PARSES under its own interpreter --------------------
# Dispatched by shebang, because this repo ships both sh and python. A parse
# error ships a broken command; this is the cheapest guard against it.
for _f in $_files; do
  _p="$HERE/$_f"
  _has_shebang "$_p" || continue
  case "$(_shebang "$_p")" in
    # compile() rather than py_compile: the latter writes a __pycache__
    # into the tree, and a test that litters is a test people work around.
    *python*) python3 -c 'import sys
compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$_p" \
        || fail "parse error in $_f" ;;
    *bash) bash -n "$_p" || fail "parse error in $_f" ;;
    *) { dash -n "$_p" 2>/dev/null || sh -n "$_p"; } \
         || fail "parse error in $_f" ;;
  esac
  _n=$((_n + 1))
done

# --- 2. 80 COLUMNS, the hard rule --------------------------------------------
# Prose and code alike: a README and a man page are as much a delivered
# artifact as setup.sh. Only the images are exempt, and they are exempt because
# they are not text.
_long=
for _f in $_files; do
  case "$_f" in *.png) continue ;; esac
  _l=$(awk -v F="$_f" 'length>80 {printf "%s:%d (%d cols)\n", F, FNR, length}' \
    "$HERE/$_f")
  [ -z "$_l" ] || _long="$_long$_l
"
done
[ -z "$_long" ] || fail "lines over 80 columns (hard rule):
$_long"
_n=$((_n + 1))

# --- 3. INDENT WITH 2 SPACES, NEVER TABS -------------------------------------
# A file that legitimately CONTAINS a tab declares so with a `tabs-are-data:`
# marker in its header and says why. That is the honest shape for an exception:
# it lives in the file it applies to, it carries its reason, and it cannot be
# forgotten. A silent allowlist here would rot the moment the file changed.
_tab=$(printf '\t')
for _f in $_files; do
  case "$_f" in *.png) continue ;; esac
  grep -q "$_tab" "$HERE/$_f" || continue
  head -60 "$HERE/$_f" | grep -q 'tabs-are-data:' && continue
  fail "$_f contains a TAB and does not declare why. Indent with 2 spaces; if
    the tab is DATA (a captured transcript, say), add a 'tabs-are-data:
    <reason>' marker in the file's header."
done
_n=$((_n + 1))

# --- 4. Python indents in steps of exactly 2 ---------------------------------
# The tab check cannot see this one: 4-space Python is tab-free and still
# wrong. Asserted over tokenize's INDENT tokens rather than over raw leading
# whitespace, so a continuation line aligned under an open paren (which may sit
# at any column) is not mistaken for an indent level.
for _f in $_files; do
  _p="$HERE/$_f"
  _has_shebang "$_p" || continue
  case "$(_shebang "$_p")" in *python*) ;; *) continue ;; esac
  python3 - "$_p" <<'PY' || fail "$_f does not indent in steps of 2 (see above)"
import sys, tokenize
path = sys.argv[1]
levels, bad = [0], 0
with open(path) as fh:
  for t in tokenize.generate_tokens(fh.readline):
    if t.type == tokenize.INDENT:
      if "\t" in t.string or len(t.string) - levels[-1] != 2:
        print("  %s:%d: indent step %d (want 2)"
              % (path, t.start[0], len(t.string) - levels[-1]))
        bad = 1
      levels.append(len(t.string))
    elif t.type == tokenize.DEDENT and len(levels) > 1:
      levels.pop()
sys.exit(bad)
PY
  _n=$((_n + 1))
done

# --- 5. EVERYTHING MATCHING *_lib IS SOURCED, NEVER EXECUTED -----------------
# This is the assertion the naming rule exists to make possible: `_` separates
# a name from its classifier where `-` separates words, so `harness_lib` parses
# as name + role and can be checked, while `harness-lib` could not be told from
# a file simply called that. A shebang or an exec bit on a `_lib` means
# somebody made it runnable and the seam has quietly gone.
for _f in $_files; do
  case "$_f" in *_lib) ;; *) continue ;; esac
  _p="$HERE/$_f"
  ! _has_shebang "$_p" || fail "$_f is named *_lib (sourced) but has a SHEBANG,
    so it claims to be executable. Either drop the shebang or drop the marker
    -- the name has to tell the truth about how it is loaded."
  [ ! -x "$_p" ] || fail "$_f is named *_lib (sourced) but is EXECUTABLE. The
    marker is what makes the seam checkable; an exec bit on it is a lie."
  _n=$((_n + 1))
done

# --- 6. AN EXECUTED FILE TAKES A BARE NAME -----------------------------------
# `foo.py` rewritten in Rust breaks every caller for no reason; `foo` does not.
# Two exemptions, and both are a CONTRACT rather than a preference: `setup.sh`
# is this fleet's package contract (tackup branches on the name), and `*.t` is
# the test runner's dispatch key (`for _t in "$HERE"/*.t`), so dropping it
# would leave the suite finding nothing and still reporting green.
for _f in $_files; do
  _p="$HERE/$_f"
  _has_shebang "$_p" || continue
  case "$_f" in
    setup.sh|*.t) continue ;;
    *.sh|*.bash|*.py|*.pl) fail "$_f is EXECUTED but carries a language suffix.
      An executed file takes a bare name so that rewriting it in another
      language does not break its callers." ;;
  esac
  _n=$((_n + 1))
done

# --- 7. the exec bit and the shebang agree -----------------------------------
# Both directions, because each failure is silent in its own way: a shebang
# without the bit is a script nobody can run as itself (and `sh file` masks
# it), and the bit without a shebang is a file that claims to be runnable and
# execs under whatever shell happens to pick it up.
for _f in $_files; do
  case "$_f" in *.png) continue ;; esac
  _p="$HERE/$_f"
  if _has_shebang "$_p"; then
    [ -x "$_p" ] || fail "$_f has a SHEBANG but is not executable."
  else
    [ ! -x "$_p" ] || fail "$_f is EXECUTABLE but has no shebang, so what runs
      it is whatever shell happens to pick it up."
  fi
  _n=$((_n + 1))
done

pass "$_n checks: parse, 80 cols, tabs, py indent, *_lib, bare names, modes"
