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
# shellcheck source=test/harness_lib
. "$(dirname "$0")/harness_lib"
harness_init setup

mkdir -p "$T/sbin" "$T/boot/grub" "$T/etc/default/grub.d" "$T/etc/grub.d" \
  "$T/plymouth-themes"
# scratch destinations
GAD=$T/boot/grub/themes/bootique         # grub asset dir
# Pinned into $T like BS_MODE_FILE, and for the same reason: unpinned, the
# suite would read the DEVELOPER's /etc/bootique/font-size and a box that had
# been sized for its panel would fail the 24px assertions below.
FONTFILE=$T/font-size                    # absent => the built-in 24
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
OWNER=
SCRIPT=
USES_DRACUT=1; GPU=xe
UMODE=auto; CLEVIS_BIN=absent-clevis; MODEFILE=$T/etc/bootique/unlock-mode
# Which initramfs lister the guard may find. Both are pinned so the host's real
# tools can never leak in and decide which branch the suite exercises.
LSFS=lsinitramfs; LSRD=absent-lsinitrd
# Pinned too, so a test can make the generator ABSENT by name rather
# than by moving a stub and hoping the host has no real one.
UPD=update-initramfs
DMODS=$T/dracut-mods; mkdir -p "$DMODS"
run() {
  env -i PATH="$T/sbin:/usr/bin:/bin" NO_COLOR=1 ALT_STATE="$ALT_STATE" \
    BS_UNLOCK_MODE="$UMODE" BS_CLEVIS_BIN="$CLEVIS_BIN" \
    BS_MODE_FILE="$MODEFILE" BS_DRACUT_MODDIR="$DMODS" \
    BS_INITRD_DIR="$T/boot" LSINITRAMFS="$LSFS" LSINITRD="$LSRD" \
    UPDATE_INITRAMFS="$UPD" \
    GRUB_ASSETDIR="$GAD" GRUB_BG_DST="$GAD/background.png" \
    GRUB_THEME_DST="$GAD/theme.txt" GRUB_DROPIN_DST="$GDROP" \
    GRUB_SELECT_STAMP="$GAD/.sel.bg" GRUB_FRAME_STAMP="$GAD/.frame.spec" \
    GRUB_TTF_REG="$TTF_REG" GRUB_TTF_BOLD="$TTF_BOLD" GRUB_10LINUX="$L10" \
    GRUB_CFG="$T/boot/grub/grub.cfg" GRUB_FONT_FILE="$FONTFILE" \
    ${GRUB_FONT_SIZE:+GRUB_FONT_SIZE="$GRUB_FONT_SIZE"} \
    ${GRUB_LABEL_SIZE:+GRUB_LABEL_SIZE="$GRUB_LABEL_SIZE"} \
    BS_THEMEDIR="$BTD" BS_DROPIN="$BDROP" BS_GFXMODE="1440x900" \
    BS_OWNER="${OWNER:-$(id -un)}" \
    BS_USES_DRACUT="$USES_DRACUT" BS_GPU_DRIVER="$GPU" \
    BS_DRACUT_CONF="$DCONF" BS_FW_ROOT="$FWROOT" BS_HOOK_DST="$HOOK" \
    sh "${SCRIPT:-$HERE/setup.sh}" "$@"
}

# --- install: grub theme + plymouth theme + both regens ----------------------
run install >/dev/null 2>&1 || fail "install exited non-zero"
# grub side
cmp -s "$HERE/background.png" "$GAD/background.png" || fail "grub bg not placed"
for _f in mono.pf2 mono-bold.pf2 mono-sm.pf2 mono-sm-bold.pf2; do
  [ -f "$GAD/$_f" ] || fail "grub font $_f not generated"
done
grep -q 'Bold 24' "$GAD/mono-bold.pf2" || fail "grub bold font wrong name"

# --- the font size comes from a FILE, so a bare-env caller agrees ------------
# THE BUG THIS PINS: the size was first plumbed as an env var an integrator
# passed. `check` is run with a bare environment by more callers than anyone
# counts: the consumer module, a human in the repo, and the pkg machinery's
# installed-probe -- so any caller that did not set it compared the live .pf2
# against the DEFAULT and reported drift it could not explain. On a real box
# the fonts were correctly regenerated at 32 and the sweep then said
# `bootique: uninstalled`. Same precedence, and the same reasoning, as
# BS_MODE_FILE: explicit env > persistent file > default.
printf '32\n' > "$FONTFILE"
run install >/dev/null 2>&1 || fail "install failed with a font-size file"
grep -q 'Regular 32' "$GAD/mono.pf2" \
  || fail "the font-size file did not reach grub-mkfont"
grep -q 'Bold 32' "$GAD/mono-bold.pf2" || fail "bold font ignored the file"
# The whole point: check agrees WITHOUT being handed the size.
run check >/dev/null 2>&1 || fail "check drifted against the size it installed"

# An explicit env still wins over the file (tests, one-offs).
GRUB_FONT_SIZE=40 GRUB_LABEL_SIZE=40 run install >/dev/null 2>&1 \
  || fail "install failed with an explicit size"
grep -q 'Regular 40' "$GAD/mono.pf2" || fail "env did not override the file"

# Garbage in the file leaves the DEFAULT standing rather than handing
# grub-mkfont a nonsense size.
printf 'not-a-number\n' > "$FONTFILE"
run install >/dev/null 2>&1 || fail "install failed on a garbage font-size"
grep -q 'Regular 24' "$GAD/mono.pf2" \
  || fail "a garbage font-size must fall back to the default"
rm -f "$FONTFILE"
run install >/dev/null 2>&1 || fail "install failed restoring the default"
grep -q 'Regular 24' "$GAD/mono.pf2" || fail "no file must mean the default"
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
# full manifest first, because the drop above is PERSISTENT (that is the point:
# the
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

# --- root-input OWNERSHIP + MODE ---------------------------------------------
# plymouthd INTERPRETS bootique.script as root, dracut SOURCES the KMS conf as
# shell, grub-mkconfig sources the grub drop-in. A copy of any of them that
# someone else can write is arbitrary code in a root context at boot or at
# image-build time. install writes them root-owned; nothing asserted they STAYED
# that way until now.
chmod g+w "$BTD/bootique.script"
run check >/dev/null 2>&1 && fail "check passed with a group-writable theme"
run check 2>&1 | grep -q 'group- or world-writable' \
  || fail "check did not name the writable theme script"
chmod g-w "$BTD/bootique.script"
run check >/dev/null 2>&1 || fail "check still dirty after fixing the mode"
chmod o+w "$BDROP"
run check >/dev/null 2>&1 && fail "check passed with a world-writable drop-in"
chmod o-w "$BDROP"
# a file owned by someone ELSE than the expected identity
OWNER=nobody-at-all
run check >/dev/null 2>&1 && fail "check passed with every root input mis-owned"
run check 2>&1 | grep -q 'not nobody-at-all' \
  || fail "check did not flag a file owned by the wrong identity"
OWNER=
run check >/dev/null 2>&1 || fail "check dirty after the ownership probe"

# --- the initramfs must be NEWER than what it was built from -----------------
# The splash that actually runs at the LUKS prompt is the copy baked INTO the
# initramfs. Every content check can pass while the boot still shows the
# previous theme: a failed regen, a hand-edited theme, or a /boot rolled back
# by a snapshot. A WARN, not a failure: mtime is a proxy.
touch "$BTD/bootique.script"
run check 2>&1 | grep -q 'NEWER than' \
  || fail "a theme newer than the initramfs was not reported"
run check >/dev/null 2>&1 || fail "a stale initramfs must WARN, not fail"
touch "$T/boot/initrd.img-6.8.0-31-generic"
run check 2>&1 | grep -q 'NEWER than' \
  && fail "still reported stale after the initramfs was rebuilt"

# --- uninstall: drop-ins + theme dirs gone -----------------------------------
run uninstall >/dev/null 2>&1 || fail "uninstall exited non-zero"
[ -e "$GDROP" ] && fail "grub drop-in not removed on uninstall"
[ -e "$BDROP" ] && fail "splash drop-in not removed on uninstall"
[ -d "$GAD" ] && fail "grub theme dir not removed on uninstall"
[ -d "$BTD" ] && fail "plymouth theme dir not removed on uninstall"
# install EDITS a file it does not own (/etc/grub.d/10_linux, quiet_boot
# 1 -> 0). It is the only change bootique makes outside its own paths, so
# it is the one uninstall must put back, because otherwise "uninstalled" leaves
# a
# distro-managed file permanently modified and the closing message is false.
grep -q '^quiet_boot="1"' "$L10" \
  || fail "uninstall left 10_linux at quiet_boot=0; it edited it, it reverts it"

# --- uninstall must NOT revert a quiet_boot it never set ---------------------
# manage_quiet_boot returns early on an already-0 file, so "it is 0" proves
# nothing about who made it 0. Only the stamp does. A box that had the messages
# on before bootique arrived must keep them after bootique leaves.
printf 'quiet_boot="0"\n' > "$L10"
run install >/dev/null 2>&1
[ -e "$GAD/.quiet_boot" ] && fail "stamped a quiet_boot flip it never made"
run uninstall >/dev/null 2>&1
grep -q '^quiet_boot="0"' "$L10" \
  || fail "uninstall clobbered a quiet_boot=0 that bootique never set"
printf 'quiet_boot="1"\n' > "$L10"

# --- the :rgba recipe tag regenerates PRE-ALPHA slices -----------------------
# A styled-box slice with no alpha channel renders as NOTHING in gfxmenu, so
# boxes carrying old-way slices must be upgraded even though colour and size
# are unchanged. The tag in the stamp is the only thing that can tell.
run install >/dev/null 2>&1
printf '%s:%s' '#CBEBA6' '1' > "$GAD/.sel.bg"      # the pre-alpha stamp format
run check >/dev/null 2>&1 \
  && fail "check passed on a pre-alpha selection bar"
run install >/dev/null 2>&1
grep -q ':rgba$' "$GAD/.sel.bg" || fail "install did not re-stamp the bar"
printf '%s:%s' '#8A6FD0' '4' > "$GAD/.frame.spec"
run check >/dev/null 2>&1 && fail "check passed on a pre-alpha menu frame"
run install >/dev/null 2>&1
grep -q ':rgba$' "$GAD/.frame.spec" || fail "install did not re-stamp the frame"

# --- a reflowed unlock_mode marker must STOP the install --------------------
# _gen_script rewrites that ONE line. If it is ever renamed or wrapped, install
# would otherwise ship the repo default to a box that needs the other mode --
# silently, which is the whole reason that guard exists.
mkdir -p "$T/repo/plymouth" "$T/repo/grub"
cp "$HERE/setup.sh" "$T/repo/"; cp "$HERE/background.png" "$T/repo/"
cp "$HERE"/plymouth/* "$T/repo/plymouth/"; cp "$HERE"/grub/* "$T/repo/grub/"
sed -i 's/^unlock_mode = "remote";/unlock_mode =\n  "remote";/' \
  "$T/repo/plymouth/bootique.script"
SCRIPT="$T/repo/setup.sh"
run install >/dev/null 2>&1 && fail "install accepted a theme with no marker"
run install 2>&1 | grep -q "no 'unlock_mode = ' line" \
  || fail "install did not name the missing unlock_mode marker"
SCRIPT=
run install >/dev/null 2>&1 || fail "install broken after the marker probe"

# --- a GRUBLESS box installs the splash and does not die on grub-mkconfig ----
# THE BUG THIS PINS: do_install called regen unconditionally while
# do_uninstall guarded it, so on a box with no grub, install printed
# "skipping the grub theme" and then exited 127 running the very command it
# had just called absent. The splash half is what got it there: its cmdline
# drop-in lives under /etc/default/grub.d, so it sets NEED_GRUB even when the
# grub half never ran. Both the README and the man page promise this box
# "simply skips that half", and an integrator reads a 127 as a hard failure.
run uninstall >/dev/null 2>&1
mkdir -p "$T/stash"; mv "$T/sbin/grub-mkconfig" "$T/stash/"
run install >"$T/out" 2>&1 || fail "install died on a box with no grub"
[ -d "$BTD" ] || fail "the splash half did not install on a grubless box"
[ -d "$GAD" ] && fail "the grub half installed on a box with no grub"
# Read from the FIRST install: a second one is idempotent, so NEED_GRUB is
# empty and there is nothing for it to report either way.
grep -q 'nothing to regenerate' "$T/out" \
  || fail "install did not say why it skipped the grub.cfg regen"
# and uninstall must STILL rebuild the initramfs there: the theme is baked
# into the image, so skipping the rebuild leaves it on screen at the next
# boot. This is what the old `_has_grub && regen` got wrong in the other
# direction once the gate moved inside regen.
rm -f "$IMARK"
run uninstall >/dev/null 2>&1 || fail "uninstall failed on a grubless box"
[ -f "$IMARK" ] || fail "uninstall skipped the initramfs rebuild"
mv "$T/stash/grub-mkconfig" "$T/sbin/"

# --- an absent initramfs generator FAILS, and says so ------------------------
# The other half of the same question, and the opposite answer: no grub means
# nothing to regenerate, but no generator with a theme change pending means
# the change silently will not take effect. That is a failure, and the bare
# version of it is a 127 out of sudo with no explanation.
run uninstall >/dev/null 2>&1
UPD=absent-update-initramfs
run install >"$T/out" 2>&1 && fail "install passed with no initramfs generator"
grep -q 'CANNOT be rebuilt' "$T/out" \
  || fail "install did not name the absent initramfs generator"
UPD=update-initramfs
run install >/dev/null 2>&1 \
  || fail "install broken after the generator probe"

# --- check exits 0 or 1, NEVER anything else ---------------------------------
# A CONTRACT with the integrator, not a preference: tackup's modules/bootique
# folds this code into its own verdict and reads anything else as drift, so a
# stray `exit 2` from a future edit would surface as an unexplainable failure
# about installation rather than about what was wrong.
_rc=0; run check >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 0 ] || fail "check on a clean install exited $_rc, want 0"
run uninstall >/dev/null 2>&1
_rc=0; run check >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 1 ] || fail "check on an uninstalled box exited $_rc, want 1"

# --- uninstall is idempotent -------------------------------------------------
# Running it twice must be the same as running it once: the second pass has
# nothing to remove and must still exit 0, or a provisioning layer that
# re-applies reads a clean box as a failure.
run uninstall >/dev/null 2>&1 || fail "a second uninstall exited non-zero"
[ -d "$GAD" ] && fail "a second uninstall resurrected the grub theme dir"
[ -d "$BTD" ] && fail "a second uninstall resurrected the plymouth theme dir"
run install >/dev/null 2>&1 || fail "install broken after the double uninstall"

# --- a font size that is NUMERIC but out of range falls back ------------------
# The garbage case above covers the non-numeric branch; this covers the range
# check, which is a separate line and was never exercised. 4px is unreadable
# and 9999px would hand grub-mkfont something it cannot do, so both must leave
# the default standing rather than be trusted.
for _px in 4 9999; do
  printf '%s\n' "$_px" > "$FONTFILE"
  run install >/dev/null 2>&1 || fail "install failed on font-size $_px"
  grep -q 'Regular 24' "$GAD/mono.pf2" \
    || fail "an out-of-range font size ($_px) was not rejected"
done
# ...and the bounds themselves are INCLUSIVE, which is the other half of a
# range check and the half that is usually off by one.
for _px in 8 128; do
  printf '%s\n' "$_px" > "$FONTFILE"
  run install >/dev/null 2>&1 || fail "install failed on font-size $_px"
  grep -q "Regular $_px" "$GAD/mono.pf2" \
    || fail "font size $_px is in range and must be honoured"
done
rm -f "$FONTFILE"

pass "install + idempotent + check + KMS shapes + revert + uninstall"
