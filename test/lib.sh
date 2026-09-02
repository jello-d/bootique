# test/lib.sh - minimal harness for the bootique in-repo tests. Sourced by each
# *.t: sets HERE (repo root), a scratch $T (auto-removed), and pass/fail.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
_tname=test
harness_init() { _tname=$1; }
fail() { printf '  FAIL %s: %s\n' "$_tname" "$1" >&2; exit 1; }
pass() { printf '  ok   %s\n' "${1:-$_tname}"; }
