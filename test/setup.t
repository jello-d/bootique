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
printf '#!/bin/sh\n: > "%s"\n' "$IMARK" > "$T/sbin/update-initramfs"
cat > "$T/sbin/grub-mkconfig" <<EOF
#!/bin/sh
out=
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2 ;; *) shift ;; esac
done
: > "$GMARK"
[ -n "\$out" ] && echo '# generated' > "\$out"
EOF
chmod +x "$T/sbin"/*

USES_DRACUT=1; GPU=xe
run() {
  env -i PATH="$T/sbin:/usr/bin:/bin" NO_COLOR=1 ALT_STATE="$ALT_STATE" \
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
# plymouth side
cmp -s "$HERE/plymouth/bootique.script" "$BTD/bootique.script" \
  || fail "plymouth script not placed"
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
