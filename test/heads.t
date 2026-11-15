#!/bin/sh
# heads.t - plymouth/heads/bootique-heads, the initramfs step that decides
# which monitors the unlock screen is drawn on. Driven against fixture trees
# (lid, DRM sysfs, the theme, the command line), asserting what plymouth
# would SEE and what the step says:
#   - lid OPEN and a laptop panel connected: keep_w/keep_h become that
#     panel's PREFERRED mode (the first line of `modes`), nothing else moves;
#   - lid CLOSED, no lid, no laptop panel, a theme without the lines, a mode
#     that is not a size, a mount that fails: plymouth sees the theme EXACTLY
#     as installed (mirrored);
#   - it waits for a panel that is not there yet, and stops waiting;
#   - bootique.lid= and bootique.panel= on the command line win;
#   - the INSTALLED theme is never written: its directory is read-only here,
#     as the initramfs root is (measured in a dracut VM), and the step edits a
#     copy in its run dir and bind-mounts it over the theme;
#   - it exits 0 on every path: it must never fail a boot.
# Each case gets its own fixture directory under $T, so nothing is deleted
# between cases; the harness removes $T at exit.
# shellcheck source=test/harness_lib
. "$(dirname "$0")/harness_lib"
harness_init heads
S=$HERE/plymouth/heads/bootique-heads

mkdir -p "$T/bin"
# sleep counts its calls and returns at once: the wait is asserted, not felt.
# shellcheck disable=SC2016  # $F is the STUB's to expand, at its run
printf '#!/bin/sh\necho x >> "$F/slept"\n' > "$T/bin/sleep"
# mount --bind SRC DST is RECORDED, not done (no root here): what plymouth
# would see is then SRC. MOUNT_FAILS makes it refuse, the way a real one can.
cat > "$T/bin/mount" <<'EOF'
#!/bin/sh
[ -n "${MOUNT_FAILS:-}" ] && { echo "mount: not permitted" >&2; exit 32; }
[ "$1" = --bind ] || { echo "mount: expected --bind: $*" >&2; exit 2; }
printf '%s %s\n' "$2" "$3" > "$F/mounted"
EOF
chmod +x "$T/bin/sleep" "$T/bin/mount"

fresh() {   # a new fixture in $F: laptop panel + two externals, lid as given
  F=$(mktemp -d "$T/case.XXXXXX")
  mkdir -p "$F/lid/LID0" "$F/drm" "$F/theme"
  : > "$F/slept"
  echo "state:      ${1:-open}" > "$F/lid/LID0/state"
  for _c in card0-eDP-1:2880x1800 card0-DP-7:3840x2160 card0-DP-9:2560x1440
  do
    mkdir -p "$F/drm/${_c%%:*}"
    echo connected > "$F/drm/${_c%%:*}/status"
    printf '%s\n1920x1080\n' "${_c#*:}" > "$F/drm/${_c%%:*}/modes"
  done
  sed -n '1,/^keep_h = /p' "$HERE/plymouth/bootique.script" \
    > "$F/theme/bootique.script"
  cp "$F/theme/bootique.script" "$F/theme.orig"
  echo "BOOT_IMAGE=/vmlinuz root=UUID=x ro quiet splash" > "$F/cmdline"
}
seal() { chmod a-w "$F/theme"; }   # the initramfs root: read-only
# Sealed only while the step runs, so the harness can still remove $T.
run() {
  seal
  env PATH="$T/bin:$PATH" F="$F" BOOTIQUE_LID="$F/lid" BOOTIQUE_DRM="$F/drm" \
    BOOTIQUE_THEME="$F/theme/bootique.script" BOOTIQUE_CMDLINE="$F/cmdline" \
    BOOTIQUE_RUN="$F/run" BOOTIQUE_WAIT="${WAIT:-3}" sh "$S"
  _rc=$?
  chmod u+w "$F/theme"
  return "$_rc"
}
# What plymouth would read: the bound copy if one was mounted, else the theme.
seen() {
  if [ -f "$F/mounted" ]; then
    [ "$(cut -d' ' -f2 "$F/mounted")" = "$F/theme/bootique.script" ] \
      || fail "bound over the wrong path: $(cat "$F/mounted")"
    cat "$(cut -d' ' -f1 "$F/mounted")"
  else cat "$F/theme/bootique.script"; fi
}
kept() { seen | grep -E '^keep_(w|h) = ' | tr '\n' ' '; }
same() { seen | cmp -s - "$F/theme.orig"; }
untouched() {
  cmp -s "$F/theme/bootique.script" "$F/theme.orig" \
    || fail "the INSTALLED theme was written; only a copy may be"
}

# The installed theme mirrors: the step is the only thing that changes that.
fresh
[ "$(kept)" = "keep_w = 0; keep_h = 0; " ] \
  || fail "the theme must ship mirrored (keep 0): $(kept)"

# --- lid open, laptop panel connected: that panel only ------------------------
fresh open
_o=$(run) || fail "exit $? on the open path"
[ "$(kept)" = "keep_w = 2880; keep_h = 1800; " ] \
  || fail "lid open must keep the laptop panel's preferred size: $(kept)"
case $_o in *"on eDP-1 (2880x1800) only"*) ;;
  *) fail "it must say what it chose: $_o" ;; esac
seen | diff "$F/theme.orig" - | grep '^[<>]' | grep -v keep_ \
  && fail "only the two keep lines may change"
untouched
pass "lid open: the laptop panel's size, in a copy bound over the theme"

# --- every unsure path leaves what plymouth sees exactly alone ---------------
fresh closed; _o=$(run) || fail "exit $? when closed"
same || fail "a closed lid must leave the theme mirrored: $(kept)"
case $_o in *"lid closed"*) ;; *) fail "closed: $_o" ;; esac
fresh open; mv "$F/lid" "$F/lid.gone"; _o=$(run) || fail "exit $? no lid"
same || fail "no lid must leave the theme mirrored"
case $_o in *"no lid"*) ;; *) fail "no lid: $_o" ;; esac
fresh open; mkdir -p "$F/lid/LID1"; echo "state:      closed" \
  > "$F/lid/LID1/state"; run >/dev/null
same || fail "ANY lid closed must mirror"
fresh open; echo disconnected > "$F/drm/card0-eDP-1/status"
_o=$(WAIT=2 run) || fail "exit $? with no panel"
same || fail "no laptop panel connected must mirror"
[ "$(wc -l < "$F/slept")" -eq 2 ] \
  || fail "it must wait WAIT seconds for the panel: $(wc -l < "$F/slept")"
case $_o in *"no laptop panel"*) ;; *) fail "no panel: $_o" ;; esac
fresh open; printf 'preferred\n' > "$F/drm/card0-eDP-1/modes"; WAIT=0 run \
  >/dev/null; same || fail "a mode that is not a size must mirror"
fresh open; sed -i '/^keep_h = /d' "$F/theme/bootique.script"
cp "$F/theme/bootique.script" "$F/theme.orig"; _o=$(run)
same || fail "a theme without both lines must be left alone"
case $_o in *"no keep_w/keep_h"*) ;; *) fail "no lines: $_o" ;; esac
fresh open; _o=$(MOUNT_FAILS=1 run) || fail "exit $? when mount fails"
same || fail "a mount that fails must leave plymouth the installed theme"
untouched
case $_o in *"could not put the copy in place (mount: not permitted)"*) ;;
  *) fail "a failed mount must say why: $_o" ;; esac
pass "closed, no lid, no panel, odd mode, old theme, failed mount: mirrored"

# --- a panel that arrives while it waits -------------------------------------
fresh open; mv "$F/drm/card0-eDP-1" "$F/eDP-late"
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
echo x >> "$F/slept"
[ -d "$F/eDP-late" ] && mv "$F/eDP-late" "$F/drm/card0-eDP-1"
exit 0
EOF
run >/dev/null
[ "$(kept)" = "keep_w = 2880; keep_h = 1800; " ] \
  || fail "a panel that appears during the wait must be taken: $(kept)"
[ "$(wc -l < "$F/slept")" -eq 1 ] || fail "it must stop waiting once found"
# shellcheck disable=SC2016  # $F is the STUB's to expand, at its run
printf '#!/bin/sh\necho x >> "$F/slept"\n' > "$T/bin/sleep"
pass "it waits for a laptop panel still binding, and stops when it is there"

# --- the command line wins ----------------------------------------------------
fresh closed
echo "quiet splash bootique.lid=open bootique.panel=DP-9" > "$F/cmdline"
run >/dev/null
[ "$(kept)" = "keep_w = 2560; keep_h = 1440; " ] \
  || fail "bootique.lid=open + bootique.panel=DP-9 must keep DP-9: $(kept)"
fresh open; echo "quiet bootique.lid=closed" > "$F/cmdline"; run >/dev/null
same || fail "bootique.lid=closed must mirror whatever the lid says"
pass "bootique.lid= and bootique.panel= on the command line win"
