#!/bin/sh
# setup.t - stub-driven test for the bootique system installer. Sandboxes every
# system path (both theme dirs, the drop-ins, grub.cfg, 10_linux, the KMS conf/
# hook) and stubs sudo/install/tee/grub-mkfont/convert/grub-mkconfig/update-
# initramfs/update-alternatives, then asserts: install places the grub theme
# (background, 4 weight+size fonts, 9-slice bar + frame, theme.txt, drop-in,
# quiet_boot=0) AND the plymouth theme (7 files, the bootique alternative, the
# splash drop-in, the dracut xe early-KMS conf) and regenerates BOTH the
# initramfs and grub.cfg; a second install is a no-op (no regen); check is clean
# and drifts on a removed grub font, a removed plymouth file, a non-bootique
# alternative, and a missing splash drop-in; the initramfs-tools + non-xe KMS
# shapes behave; uninstall removes the drop-ins + theme dirs. Reads the repo's
# own theme sources; nothing on the box is touched.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init setup

mkdir -p "$T/sbin" "$T/boot/grub" "$T/etc/default/grub.d" "$T/etc/grub.d" \
  "$T/plymouth-themes"
# scratch destinations
GAD=$T/boot/grub/themes/bootique         # grub asset dir
BTD=$T/plymouth-themes/bootique          # plymouth theme dir (parent exists)
GDROP=$T/etc/default/grub.d/bootique.cfg
BDROP=$T/etc/default/grub.d/splash.cfg
DCONF=$T/etc/dracut.conf.d/90-bootique-kms.conf
HOOK=$T/etc/initramfs-tools/hooks/bootique-kms
L10=$T/etc/grub.d/10_linux
printf 'quiet_boot="1"\n' > "$L10"       # Ubuntu default, to be flipped to 0
# stand-in TTFs (the grub-mkfont stub reads only the name for Regular vs Bold)
TTF_REG=$T/DejaVuSansMono.ttf;       : > "$TTF_REG"
TTF_BOLD=$T/DejaVuSansMono-Bold.ttf; : > "$TTF_BOLD"
# fake firmware so the dracut conf's install_items has something to list
FWROOT=$T/fw; mkdir -p "$FWROOT/i915" "$FWROOT/xe"
: > "$FWROOT/i915/xe2lpd_dmc.bin.zst"; : > "$FWROOT/xe/lnl_guc_70.bin.zst"
ALT_STATE=$T/alt.value; : > "$ALT_STATE"
IMARK=$T/initramfs.ran; GMARK=$T/grub.ran

# --- stubs -------------------------------------------------------------------
printf '#!/bin/sh\nexec "$@"\n' > "$T/sbin/sudo"
cat > "$T/sbin/install" <<'EOF'
#!/bin/sh
mode=; src=; dst=
while [ $# -gt 0 ]; do
  case "$1" in
    -D) shift ;; -m) mode=$2; shift 2 ;; -o|-g) shift 2 ;;
    *) src=$dst; dst=$1; shift ;;
  esac
done
mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"
[ -n "$mode" ] && chmod "$mode" "$dst"
exit 0
EOF
cat > "$T/sbin/grub-mkfont" <<'EOF'
#!/bin/sh
size=; out=; ttf=
while [ $# -gt 0 ]; do
  case "$1" in -s) size=$2; shift 2 ;; -o) out=$2; shift 2 ;; *) ttf=$1; shift
  ;; esac
done
case "$ttf" in *Bold*) wt=Bold ;; *) wt=Regular ;; esac
printf 'PFF2 DejaVu Sans Mono %s %s\n' "$wt" "$size" > "$out"
EOF
cat > "$T/sbin/convert" <<'EOF'
#!/bin/sh
for a in "$@"; do out=$a; done          # last arg is the output file
out=${out#PNG32:}; out=${out#PNG24:}
printf 'PNG-stub\n' > "$out"
EOF
cat > "$T/sbin/update-alternatives" <<EOF
#!/bin/sh
case "\$1" in
  --install) : ;;
  --set)     printf '%s\n' "\$3" > "$ALT_STATE" ;;
  --remove)  : > "$ALT_STATE" ;;
  --query)   [ -s "$ALT_STATE" ] && printf 'Value: %s\n' "\$(cat "$ALT_STATE")"
             exit 0 ;;
esac
exit 0
EOF
# The initramfs composition guard needs a listable image. MANIFEST stands in for
# the image contents: lsinitramfs prints it, and update-initramfs "rebuilds" by
# replacing it with REBUILT_MANIFEST when that exists, which is how a rebuild
# that DROPS another owner's payload is simulated.
mkdir -p "$T/boot"
: > "$T/boot/vmlinuz-6.8.0-31-generic"
: > "$T/boot/initrd.img-6.8.0-31-generic"
MANIFEST=$T/manifest; REBUILT=$T/manifest.next
# bin/link is rendered as a SYMLINK by the lsinitrd stub, so that dropping it
# proves the ls -l parser reports the link name and not its target.
full_manifest() {
  printf 'usr/sbin/sshd\nusr/bin/clevis\nlib/modules/e1000e.ko\nbin/sh\n'
  printf 'bin/link\n'
}
full_manifest > "$MANIFEST"
printf '#!/bin/sh\ncat "%s"\n' "$MANIFEST" > "$T/sbin/lsinitramfs"
# dracut's lsinitrd has no bare-path mode, so the guard parses an ls -l style
# table. This stub reproduces that shape (header block, a symlink line whose
# "-> target" must NOT be mistaken for the path) to exercise that parser.
cat > "$T/sbin/lsinitrd" <<EOF
#!/bin/sh
echo "Image: \$1: 53M"
echo "========================================================================"
echo "Version:"
echo "========================================================================"
awk '\$0 == "bin/link" {
       printf "lrwxrwxrwx 1 root root 4 Jan  1 00:00 %s -> dash\n", \$0; next }
     { printf "-rw-r--r-- 1 root root 1234 Jan  1 00:00 %s\n", \$0 }' \
  "$MANIFEST"
echo "drwxr-xr-x   2 root     root          0 Jan  1 00:00 usr/bin"
EOF
cat > "$T/sbin/update-initramfs" <<EOF
#!/bin/sh
: > "$IMARK"
[ -f "$REBUILT" ] && cp "$REBUILT" "$MANIFEST"
exit 0
EOF
cat > "$T/sbin/grub-mkconfig" <<EOF
#!/bin/sh
out=
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac
done
: > "$GMARK"
[ -n "\$out" ] && echo '# generated' > "\$out"
EOF
chmod +x "$T/sbin"/*

# Unlock-mode inputs, all sandboxed so the verdict never depends on whether the
# HOST running the suite happens to have clevis: the detector looks for
# BS_CLEVIS_BIN on PATH (a name nothing provides, until a test plants a stub)
# and for a *clevis* dir under BS_DRACUT_MODDIR (an empty scratch dir here).
USES_DRACUT=1; GPU=xe
UMODE=auto; CLEVIS_BIN=absent-clevis; MODEFILE=$T/etc/bootique/unlock-mode
# Which initramfs lister the guard may find. Both are pinned so the host's real
# tools can never leak in and decide which branch the suite exercises.
LSFS=lsinitramfs; LSRD=absent-lsinitrd
DMODS=$T/dracut-mods; mkdir -p "$DMODS"
run() {
  env -i PATH="$T/sbin:/usr/bin:/bin" NO_COLOR=1 ALT_STATE="$ALT_STATE" \
    BS_UNLOCK_MODE="$UMODE" BS_CLEVIS_BIN="$CLEVIS_BIN" \
    BS_MODE_FILE="$MODEFILE" BS_DRACUT_MODDIR="$DMODS" \
    BS_INITRD_DIR="$T/boot" LSINITRAMFS="$LSFS" LSINITRD="$LSRD" \
    GRUB_ASSETDIR="$GAD" GRUB_BG_DST="$GAD/background.png" \
    GRUB_THEME_DST="$GAD/theme.txt" GRUB_DROPIN_DST="$GDROP" \
    GRUB_SELECT_STAMP="$GAD/.sel.bg" GRUB_FRAME_STAMP="$GAD/.frame.spec" \
    GRUB_TTF_REG="$TTF_REG" GRUB_TTF_BOLD="$TTF_BOLD" GRUB_10LINUX="$L10" \
    GRUB_CFG="$T/boot/grub/grub.cfg" \
    BS_THEMEDIR="$BTD" BS_DROPIN="$BDROP" BS_GFXMODE="1440x900" \
    BS_USES_DRACUT="$USES_DRACUT" BS_GPU_DRIVER="$GPU" \
    BS_DRACUT_CONF="$DCONF" BS_FW_ROOT="$FWROOT" BS_HOOK_DST="$HOOK" \
    sh "$HERE/setup.sh" "$@"
}

# --- install: grub theme + plymouth theme + both regens ----------------------
run install >/dev/null 2>&1 || fail "install exited non-zero"
# grub side
cmp -s "$HERE/background.png" "$GAD/background.png" || fail "grub bg not placed"
for _f in mono.pf2 mono-bold.pf2 mono-sm.pf2 mono-sm-bold.pf2; do
  [ -f "$GAD/$_f" ] || fail "grub font $_f not generated"
done
grep -q 'Bold 24' "$GAD/mono-bold.pf2" || fail "grub bold font wrong name"
[ -f "$GAD/sel_c.png" ] || fail "grub selection bar not generated"
[ -f "$GAD/frame_c.png" ] || fail "grub menu frame not generated"
cmp -s "$HERE/grub/theme.txt" "$GAD/theme.txt" || fail "grub theme not placed"
cmp -s "$HERE/grub/bootique.cfg" "$GDROP" || fail "grub drop-in not placed"
grep -q '^quiet_boot="0"' "$L10" || fail "quiet_boot not flipped to 0"
# plymouth side. bootique.script is GENERATED, not copied: with no clevis on
# this sandbox's PATH the mode autodetects to local, so the installed copy must
# differ from the repo source in exactly the baked mode line.
grep -qx 'unlock_mode = "local";' "$BTD/bootique.script" \
  || fail "installed theme not baked for the autodetected (local) unlock mode"
cmp -s "$HERE/plymouth/bootique.script" "$BTD/bootique.script" \
  && fail "installed theme is a verbatim copy (the mode was never baked in)"
diff "$HERE/plymouth/bootique.script" "$BTD/bootique.script" \
  | grep -cE '^[<>]' | grep -qx 2 \
  || fail "generated theme differs from the source by more than the mode line"
cmp -s "$HERE/background.png" "$BTD/background.png" \
  || fail "plymouth background not placed"
[ "$(cat "$ALT_STATE")" = "$BTD/bootique.plymouth" ] \
  || fail "default.plymouth alternative not set to bootique"
grep -qE 'GRUB_CMDLINE_LINUX_DEFAULT=.*splash' "$BDROP" \
  || fail "splash drop-in does not enable splash"
grep -qE 'force_drivers.*\bxe\b' "$DCONF" || fail "dracut KMS conf not written"
grep -q 'install_items' "$DCONF" || fail "dracut KMS conf missing firmware"
[ -e "$HOOK" ] && fail "initramfs-tools hook must be absent on a dracut box"
[ -f "$IMARK" ] || fail "initramfs not rebuilt on first install"
[ -f "$GMARK" ] || fail "grub.cfg not regenerated on first install"

# --- idempotent: a second install rebuilds nothing ---------------------------
rm -f "$IMARK" "$GMARK"
run install >/dev/null 2>&1 || fail "second install exited non-zero"
[ -f "$IMARK" ] && fail "second install rebuilt initramfs with no drift"
[ -f "$GMARK" ] && fail "second install regenerated grub with no drift"

# --- check: clean, then drift on each managed piece --------------------------
run check >/dev/null 2>&1 || fail "check reported drift on a settled box"
rm -f "$GAD/mono-bold.pf2"
run check >/dev/null 2>&1 && fail "check passed with a grub font removed"
run install >/dev/null 2>&1
rm -f "$BTD/bootique.script"
run check >/dev/null 2>&1 && fail "check passed with a plymouth file removed"
run install >/dev/null 2>&1
printf '%s\n' "$T/plymouth-themes/bgrt/bgrt.plymouth" > "$ALT_STATE"
run check >/dev/null 2>&1 && fail "check passed with a non-bootique alternative"
run install >/dev/null 2>&1
rm -f "$BDROP"
run check >/dev/null 2>&1 && fail "check passed with the splash drop-in removed"
run install >/dev/null 2>&1

# --- unlock mode: autodetect, both overrides, and mode drift -----------------
# clevis on the box means something races the human for the same passphrase
# request, so the theme must carry the remote copy.
printf '#!/bin/sh\nexit 0\n' > "$T/sbin/planted-clevis"
chmod +x "$T/sbin/planted-clevis"
CLEVIS_BIN=planted-clevis
run install >/dev/null 2>&1 || fail "install (clevis present) exited non-zero"
grep -qx 'unlock_mode = "remote";' "$BTD/bootique.script" \
  || fail "clevis on the box did not autodetect to the remote unlock mode"
run check >/dev/null 2>&1 || fail "check drifted right after a remote install"
# The SAME theme once clevis is gone is real drift, not a settled box: it would
# promise an auto-unlock that can no longer answer. check must say so.
CLEVIS_BIN=absent-clevis
run check >/dev/null 2>&1 && fail "check passed with a stale remote-mode theme"
run install >/dev/null 2>&1
grep -qx 'unlock_mode = "local";' "$BTD/bootique.script" \
  || fail "install did not re-bake the theme back to local"

# the persistent file override beats autodetection ...
mkdir -p "$(dirname "$MODEFILE")"
printf '# written by the provisioning layer\nremote\n' > "$MODEFILE"
run install >/dev/null 2>&1 || fail "install (mode file) exited non-zero"
grep -qx 'unlock_mode = "remote";' "$BTD/bootique.script" \
  || fail "the mode file override was ignored"
run check >/dev/null 2>&1 || fail "check drifted with the mode file honoured"
# ... and the env override beats the file.
UMODE=local
run install >/dev/null 2>&1 || fail "install (BS_UNLOCK_MODE) exited non-zero"
grep -qx 'unlock_mode = "local";' "$BTD/bootique.script" \
  || fail "BS_UNLOCK_MODE did not override the mode file"
# Anything that is neither local nor remote is incoherent: stop, do not guess.
UMODE=sometimes
run install >/dev/null 2>&1 && fail "install accepted a bogus BS_UNLOCK_MODE"
UMODE=auto
printf 'sometimes\n' > "$MODEFILE"
run install >/dev/null 2>&1 && fail "install accepted a bogus mode file"
# An override we cannot READ must stop too: falling back to autodetection there
# would discard what the operator asked for and then call the result settled.
: > "$MODEFILE"
run install >/dev/null 2>&1 && fail "install accepted an empty mode file"
printf 'remote\n' > "$MODEFILE"; chmod 000 "$MODEFILE"
run install >/dev/null 2>&1 && fail "install ignored an unreadable mode file"
chmod 644 "$MODEFILE"
rm -f "$MODEFILE"
run install >/dev/null 2>&1 || fail "install (mode file removed) non-zero"

# --- initramfs composition guard ---------------------------------------------
# A rebuild that keeps everything is quiet; one that DROPS another owner's
# payload is loud AND non-zero, because the cosmetics succeeding while the box
# lost the thing that unlocks it must not read as success.
rm -f "$BTD/bootique.script"                 # force a rebuild
out=$(run install 2>&1) || fail "install failed on an intact rebuild"
printf '%s' "$out" | grep -q 'initramfs composition intact' \
  || fail "no composition report on a rebuild"
# now a rebuild that loses sshd + the NIC driver
printf 'usr/bin/clevis\nbin/sh\n' > "$REBUILT"
rm -f "$BTD/bootique.script"
out=$(run install 2>&1) && fail "install exited 0 after dropping initramfs bits"
printf '%s' "$out" | grep -q 'DROPPED 3 path' \
  || fail "composition guard did not report the dropped count"
printf '%s' "$out" | grep -q 'usr/sbin/sshd' \
  || fail "composition guard did not name the dropped ssh server"
printf '%s' "$out" | grep -q 'CHECK BEFORE YOU REBOOT' \
  || fail "composition guard did not tell the operator to check"
rm -f "$REBUILT"
run install >/dev/null 2>&1 || fail "install non-zero once the drop settled"

# the dracut lister: same guarantee through the ls -l table parser. Restore the
# full manifest first -- the drop above is PERSISTENT (that is the point: the
# warning is self-clearing), so without this there would be nothing left to drop
# and the block would pass while asserting nothing.
full_manifest > "$MANIFEST"
LSFS=absent-lsinitramfs; LSRD=lsinitrd
rm -f "$BTD/bootique.script"
out=$(run install 2>&1) || fail "install failed on an intact rebuild (dracut)"
printf '%s' "$out" | grep -q 'initramfs composition intact' \
  || fail "no composition report via the dracut lister"
printf 'usr/bin/clevis\nbin/sh\n' > "$REBUILT"
rm -f "$BTD/bootique.script"
out=$(run install 2>&1) && fail "dracut lister missed a dropped payload"
printf '%s' "$out" | grep -q 'usr/sbin/sshd' \
  || fail "dracut lister did not name the dropped ssh server"
printf '%s' "$out" | grep -q 'bin/link' \
  || fail "dracut lister did not name the dropped symlink"
printf '%s' "$out" | grep -q 'dash' \
  && fail "dracut lister took a symlink TARGET for a path"
rm -f "$REBUILT"
run install >/dev/null 2>&1 || fail "install non-zero once the drop settled (2)"

# No lister at all must DEGRADE LOUDLY, not pass quietly: the cosmetics still
# install (a missing tool is no reason to refuse), but the run says so.
LSFS=absent-lsinitramfs; LSRD=absent-lsinitrd
rm -f "$BTD/bootique.script"
out=$(run install 2>&1) || fail "install failed with no initramfs lister"
printf '%s' "$out" | grep -q 'composition NOT checked' \
  || fail "guard skipped the composition check without saying so"
LSFS=lsinitramfs; LSRD=absent-lsinitrd

# --- KMS generator switch: initramfs-tools mode uses the hook, not the conf --
USES_DRACUT=0
run install >/dev/null 2>&1 || fail "install (initramfs-tools mode) non-zero"
cmp -s "$HERE/plymouth/bootique-kms" "$HOOK" || fail "early-KMS hook not placed"
[ -x "$HOOK" ] || fail "early-KMS hook not executable"
[ -e "$DCONF" ] && fail "dracut conf must be removed in initramfs-tools mode"
run check >/dev/null 2>&1 || fail "check drifted in initramfs-tools mode"
USES_DRACUT=1; GPU=
run install >/dev/null 2>&1 || fail "install (non-xe GPU) non-zero"
[ -e "$DCONF" ] && fail "dracut KMS conf must be absent for a non-xe GPU"
[ -e "$HOOK" ] && fail "initramfs-tools hook must be absent for a non-xe GPU"
run check >/dev/null 2>&1 || fail "check drifted for a non-xe GPU"
GPU=xe; run install >/dev/null 2>&1

# --- uninstall: drop-ins + theme dirs gone -----------------------------------
run uninstall >/dev/null 2>&1 || fail "uninstall exited non-zero"
[ -e "$GDROP" ] && fail "grub drop-in not removed on uninstall"
[ -e "$BDROP" ] && fail "splash drop-in not removed on uninstall"
[ -d "$GAD" ] && fail "grub theme dir not removed on uninstall"
[ -d "$BTD" ] && fail "plymouth theme dir not removed on uninstall"

pass "install + idempotent + check + KMS shapes + uninstall"
