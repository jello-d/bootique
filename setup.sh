#!/bin/sh
# setup.sh - bootique: the boot-cosmetics suite. A GRUB menu theme + a Plymouth
# boot splash + the shared forest photo, styled to match each other and the
# desktop. Unlike a ~/.local gadget this is a "theme pack with a SYSTEM
# installer": it installs to /boot/grub/themes/bootique and /usr/share/plymouth/
# themes/bootique (root, sudo) and rebuilds the initramfs + grub.cfg. The SINGLE
# entry point a consumer or provisioning layer uses.
#
#   ./setup.sh install    place both themes + early-KMS; regen initramfs + grub
#   ./setup.sh uninstall  remove the themes + drop-ins; regen back to plain boot
#   ./setup.sh check      audit; [OK]/[FAIL]/[WARN] markers; non-zero on drift
#   ./setup.sh test       run the in-repo suite (test/run)
#   ./setup.sh version    the packaged version
#
# POSIX sh. sudo for privileged steps. Each piece is cmp/size/stamp-gated, so a
# settled box is a no-op; the initramfs/grub regenerate only on a change.
# Every system path is overridable (the in-repo test drives it against a scratch
# tree with a stubbed sudo). Deps: grub-mkfont + ImageMagick `convert` (grub
# theme), DejaVu Sans Mono TTFs, plymouth; each missing piece degrades with a
# note. NOT fused with the remote-unlock mechanism (a separate, boot-critical
# owner); its dracut drop-ins just compose with this one's via update-initramfs.
set -eu

PKG=bootique
VERSION=0.1.0
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RC=0
NEED_GRUB= NEED_INITRAMFS=

# marker contract: plain [OK]/[FAIL]/[WARN] an integrator styles in its palette;
# self-coloured at a terminal, plain when piped or under NO_COLOR.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[32m'); _R=$(printf '\033[31m')
  _Y=$(printf '\033[33m'); _O=$(printf '\033[0m')
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

# The shared photo: the grub theme's desktop-image AND the plymouth background.
_bg_src="$_root/background.png"

# =========================== GRUB menu theme ================================
# A GRUB THEME (not the 16-colour menu_color knob) so colours are exact hex:
# deep-purple menu text, a light-green selection bar, a purple frame near the
# screen edges, light labels over the dark foliage. Fonts are GENERATED on the
# box (grub-mkfont from DejaVu Sans Mono), the bar + frame with ImageMagick.
GRUB_FONT_SIZE=${GRUB_FONT_SIZE:-24}       # menu items
GRUB_LABEL_SIZE=${GRUB_LABEL_SIZE:-24}     # bottom timeout + help labels
_dj=/usr/share/fonts/truetype/dejavu
GRUB_TTF_REG=${GRUB_TTF_REG:-$_dj/DejaVuSansMono.ttf}
GRUB_TTF_BOLD=${GRUB_TTF_BOLD:-$_dj/DejaVuSansMono-Bold.ttf}
# The selection bar colour (one flat green). 1px slice: gfxmenu draws the styled
# box at item_height + 2*slice, so a fat slice bleeds into neighbour rows.
GRUB_SELECT_BG=${GRUB_SELECT_BG:-#CBEBA6}
GRUB_SELECT_PX=${GRUB_SELECT_PX:-1}
# The menu frame: a GRUB_FRAME_PX edge in GRUB_FRAME_BG, transparent centre.
GRUB_FRAME_BG=${GRUB_FRAME_BG:-#8A6FD0}
GRUB_FRAME_PX=${GRUB_FRAME_PX:-4}
GRUB_ASSETDIR=${GRUB_ASSETDIR:-/boot/grub/themes/bootique}
GRUB_BG_DST=${GRUB_BG_DST:-$GRUB_ASSETDIR/background.png}
GRUB_THEME_DST=${GRUB_THEME_DST:-$GRUB_ASSETDIR/theme.txt}
GRUB_SELECT_STAMP=${GRUB_SELECT_STAMP:-$GRUB_ASSETDIR/.sel.bg}
GRUB_FRAME_STAMP=${GRUB_FRAME_STAMP:-$GRUB_ASSETDIR/.frame.spec}
GRUB_DROPIN_DST=${GRUB_DROPIN_DST:-/etc/default/grub.d/bootique.cfg}
GRUB_CFG=${GRUB_CFG:-/boot/grub/grub.cfg}
GRUB_MKCONFIG=${GRUB_MKCONFIG:-grub-mkconfig}
# Ubuntu's 10_linux hardcodes quiet_boot="1", suppressing the post-selection
# "Loading Linux ..." echoes on the default entry; on a long-POST box that reads
# as HUNG before plymouth appears. quiet_boot="0" restores them.
GRUB_10LINUX=${GRUB_10LINUX:-/etc/grub.d/10_linux}
GRUB_MKFONT=${GRUB_MKFONT:-grub-mkfont}
IM_CONVERT=${IM_CONVERT:-convert}
_gtheme_src="$_root/grub/theme.txt"
_gdropin_src="$_root/grub/bootique.cfg"

# The four menu fonts: "basename ttf-var weight size". A .pf2 embeds
# "<weight> <size>" in its name, so the artifact says what it is (no stamp).
_fonts() {
  printf '%s\n' \
    "mono.pf2 $GRUB_TTF_REG Regular $GRUB_FONT_SIZE" \
    "mono-bold.pf2 $GRUB_TTF_BOLD Bold $GRUB_FONT_SIZE" \
    "mono-sm.pf2 $GRUB_TTF_REG Regular $GRUB_LABEL_SIZE" \
    "mono-sm-bold.pf2 $GRUB_TTF_BOLD Bold $GRUB_LABEL_SIZE"
}
_sel_slices() { echo c n s e w nw ne sw se; }
_has_grub() { command -v "$GRUB_MKCONFIG" >/dev/null 2>&1; }
_font_ok() { [ -f "$1" ] && grep -aqE "$2 $3([^0-9]|\$)" "$1"; }
# ':rgba' recipe tag: bumping the generation recipe invalidates old-way slices.
_bar_spec()   { printf '%s:%s:rgba' "$GRUB_SELECT_BG" "$GRUB_SELECT_PX"; }
_frame_spec() { printf '%s:%s:rgba' "$GRUB_FRAME_BG" "$GRUB_FRAME_PX"; }
_bar_ok() {
  [ -f "$GRUB_ASSETDIR/sel_c.png" ] \
    && [ "$(cat "$GRUB_SELECT_STAMP" 2>/dev/null)" = "$(_bar_spec)" ]
}
_frame_ok() {
  [ -f "$GRUB_ASSETDIR/frame_c.png" ] \
    && [ "$(cat "$GRUB_FRAME_STAMP" 2>/dev/null)" = "$(_frame_spec)" ]
}

# _place <src> <dst> <mode> <label>: install src at dst when it differs, root-
# owned at <mode>; a no-op note otherwise. Any change flags a grub regen.
_place() {
  if cmp -s "$1" "$2" 2>/dev/null; then
    echo "$PKG: $4 current"
  else
    sudo install -D -m "$3" -o root -g root "$1" "$2"
    echo "$PKG: wrote $4"; NEED_GRUB=1
  fi
}

gen_fonts() {
  command -v "$GRUB_MKFONT" >/dev/null 2>&1 \
    || { echo "$PKG: grub-mkfont absent; skipping fonts"; return 0; }
  while read -r _base _ttf _wt _sz; do
    [ -n "$_base" ] || continue
    _dst="$GRUB_ASSETDIR/$_base"
    if _font_ok "$_dst" "$_wt" "$_sz"; then
      echo "$PKG: font $_base current (DejaVu Sans Mono $_wt $_sz)"; continue
    fi
    [ -f "$_ttf" ] \
      || { echo "$PKG: TTF absent ($_ttf); skipping $_base"; continue; }
    _tmp=$(mktemp)
    "$GRUB_MKFONT" -s "$_sz" -o "$_tmp" "$_ttf" \
      || { rm -f "$_tmp"; echo "$PKG: grub-mkfont failed ($_base)" >&2; \
           return 1; }
    sudo install -D -m 0644 -o root -g root "$_tmp" "$_dst"
    rm -f "$_tmp"
    echo "$PKG: generated font $_base (DejaVu Sans Mono $_wt $_sz)"; NEED_GRUB=1
  done <<EOF
$(_fonts)
EOF
}

# gen_bar: the selected-item bar -- one flat GRUB_SELECT_BG tile copied to all 9
# slices. -alpha on is LOAD-BEARING: gfxmenu draws NOTHING for a slice
# with no alpha channel (VM-verified, GPU-independent).
gen_bar() {
  if _bar_ok; then echo "$PKG: selection bar current"; return 0; fi
  command -v "$IM_CONVERT" >/dev/null 2>&1 \
    || { echo "$PKG: convert absent; skipping selection bar"; return 0; }
  _tmp=$(mktemp --suffix=.png)
  "$IM_CONVERT" -size "${GRUB_SELECT_PX}x${GRUB_SELECT_PX}" \
    "xc:$GRUB_SELECT_BG" -alpha on PNG32:"$_tmp" \
    || { rm -f "$_tmp"; echo "$PKG: convert failed" >&2; return 1; }
  for _s in $(_sel_slices); do
    sudo install -D -m 0644 -o root -g root "$_tmp" "$GRUB_ASSETDIR/sel_$_s.png"
  done
  rm -f "$_tmp"
  _bar_spec | sudo tee "$GRUB_SELECT_STAMP" >/dev/null
  echo "$PKG: generated selection bar ($GRUB_SELECT_BG)"; NEED_GRUB=1
}

# gen_frame: the menu frame's 9 slices -- a GRUB_FRAME_PX edge in GRUB_FRAME_BG,
# transparent centre (alpha PNG; the photo shows inside). Every slice needs an
# alpha channel or gfxmenu draws nothing.
gen_frame() {
  if _frame_ok; then echo "$PKG: menu frame current"; return 0; fi
  command -v "$IM_CONVERT" >/dev/null 2>&1 \
    || { echo "$PKG: convert absent; skipping menu frame"; return 0; }
  _t=$GRUB_FRAME_PX; _d=$(mktemp -d)
  "$IM_CONVERT" -size 2x2 xc:none PNG32:"$_d/c.png"
  "$IM_CONVERT" -size "8x$_t" "xc:$GRUB_FRAME_BG" -alpha on PNG32:"$_d/h.png"
  "$IM_CONVERT" -size "${_t}x8" "xc:$GRUB_FRAME_BG" -alpha on PNG32:"$_d/v.png"
  "$IM_CONVERT" -size "${_t}x$_t" "xc:$GRUB_FRAME_BG" -alpha on \
    PNG32:"$_d/k.png"
  for _m in c:c n:h s:h e:v w:v nw:k ne:k sw:k se:k; do
    sudo install -D -m 0644 -o root -g root "$_d/${_m#*:}.png" \
      "$GRUB_ASSETDIR/frame_${_m%:*}.png"
  done
  rm -rf "$_d"
  _frame_spec | sudo tee "$GRUB_FRAME_STAMP" >/dev/null
  echo "$PKG: generated menu frame ($GRUB_FRAME_BG, ${GRUB_FRAME_PX}px)"
  NEED_GRUB=1
}

manage_quiet_boot() {
  [ -f "$GRUB_10LINUX" ] \
    || { echo "$PKG: $GRUB_10LINUX absent; skipping quiet_boot"; return 0; }
  if grep -q '^quiet_boot="0"' "$GRUB_10LINUX"; then
    echo "$PKG: post-selection loading messages already on"; return 0
  fi
  grep -q '^quiet_boot="1"' "$GRUB_10LINUX" \
    || { echo "$PKG: quiet_boot line not found in 10_linux; skipping"
         return 0; }
  sudo sed -i 's/^quiet_boot="1"/quiet_boot="0"/' "$GRUB_10LINUX"
  echo "$PKG: enabled post-selection loading messages (quiet_boot=0)"
  NEED_GRUB=1
}

grub_install() {
  _place "$_bg_src" "$GRUB_BG_DST" 0644 "grub background"
  gen_fonts
  gen_bar
  gen_frame
  _place "$_gtheme_src" "$GRUB_THEME_DST" 0644 "grub theme"
  _place "$_gdropin_src" "$GRUB_DROPIN_DST" 0644 "grub theme drop-in"
  manage_quiet_boot
}

grub_check() {
  cmp -s "$_bg_src" "$GRUB_BG_DST" 2>/dev/null \
    && ok "grub background installed" \
    || bad "grub background missing or stale (install)"
  while read -r _base _ttf _wt _sz; do
    [ -n "$_base" ] || continue
    if _font_ok "$GRUB_ASSETDIR/$_base" "$_wt" "$_sz"; then
      ok "grub font $_base ($_wt $_sz)"
    else bad "grub font $_base missing or wrong weight/size (install)"; fi
  done <<EOF
$(_fonts)
EOF
  _bar_ok && ok "grub selection bar ($GRUB_SELECT_BG)" \
    || bad "grub selection bar missing or wrong colour (install)"
  _frame_ok && ok "grub menu frame ($GRUB_FRAME_BG/${GRUB_FRAME_PX}px)" \
    || bad "grub menu frame missing or wrong spec (install)"
  cmp -s "$_gtheme_src" "$GRUB_THEME_DST" 2>/dev/null \
    && ok "grub theme current" || bad "grub theme missing or stale (install)"
  cmp -s "$_gdropin_src" "$GRUB_DROPIN_DST" 2>/dev/null \
    && ok "grub theme drop-in current (GRUB_THEME set)" \
    || bad "grub theme drop-in missing or stale (install)"
  if [ ! -f "$GRUB_10LINUX" ]; then ok "10_linux absent; quiet_boot n/a"
  elif grep -q '^quiet_boot="0"' "$GRUB_10LINUX"; then
    ok "post-selection loading messages on (quiet_boot=0)"
  else bad "post-selection loading messages suppressed (install)"; fi
  return 0
}

# =========================== Plymouth boot splash ===========================
# plymouth's graphical screen from the LUKS passphrase prompt through systemd to
# the greetd handoff. A 'script' theme (forest photo, a green unlock pill,
# a rolling boot-log). Selected via the default.plymouth alternative; enabled by
# a grub 'quiet splash' drop-in; the theme is BAKED INTO THE INITRAMFS (the
# rebuild). EARLY-KMS forces the GPU driver + firmware into the initramfs so the
# panel is native BEFORE the first frame (post-unlock resize fix; xe/dracut).
BS_THEMEDIR=${BS_THEMEDIR:-/usr/share/plymouth/themes/bootique}
BS_ALT_LINK=${BS_ALT_LINK:-/usr/share/plymouth/themes/default.plymouth}
BS_ALT_NAME=${BS_ALT_NAME:-default.plymouth}
BS_DROPIN=${BS_DROPIN:-/etc/default/grub.d/splash.cfg}
BS_CMDLINE=${BS_CMDLINE:-quiet splash}
BS_HOOK_DST=${BS_HOOK_DST:-/etc/initramfs-tools/hooks/bootique-kms}
BS_DRACUT_CONF=${BS_DRACUT_CONF:-/etc/dracut.conf.d/90-bootique-kms.conf}
BS_FW_ROOT=${BS_FW_ROOT:-/lib/firmware}
UPDATE_INITRAMFS=${UPDATE_INITRAMFS:-update-initramfs}
UPDATE_ALTERNATIVES=${UPDATE_ALTERNATIVES:-update-alternatives}
_pkroot="$_root/plymouth"
_hook_src="$_pkroot/bootique-kms"
_alt_target=$BS_THEMEDIR/bootique.plymouth

# GRUB_GFXMODE for the plymouth drop-in: the native mode of the first connected
# panel (resolves headless). Menu cosmetics; the real resize fix is early-KMS.
_native_mode() {
  for _c in /sys/class/drm/*/status; do
    [ "$(cat "$_c" 2>/dev/null)" = connected ] || continue
    _md=${_c%/status}/modes
    [ -s "$_md" ] && { head -n1 "$_md"; return 0; }
  done
}
BS_GFXMODE=${BS_GFXMODE:-$(_native_mode)}

# Theme files into BS_THEMEDIR: "<dst-name> <src-path>". background.png is
# the shared photo (same source as the grub desktop-image).
_theme_files() {
  printf '%s\n' \
    "bootique.plymouth $_pkroot/bootique.plymouth" \
    "bootique.script $_pkroot/bootique.script" \
    "pill.png $_pkroot/pill.png" \
    "dot.png $_pkroot/dot.png" \
    "shutdown-bg.png $_pkroot/shutdown-bg.png" \
    "scrim.png $_pkroot/scrim.png" \
    "background.png $_bg_src"
}
_has_plymouth() {
  command -v "$UPDATE_ALTERNATIVES" >/dev/null 2>&1 \
    && [ -d "$(dirname "$BS_THEMEDIR")" ]
}
_alt_is_bootique() {
  [ "$("$UPDATE_ALTERNATIVES" --query "$BS_ALT_NAME" 2>/dev/null \
      | awk '/^Value:/{print $2}')" = "$_alt_target" ]
}

# _place_theme <src> <dst> <label>: install a theme file (root 0644) when it
# differs; a change flags an initramfs rebuild (the LUKS-prompt theme lives
# there).
_place_theme() {
  if cmp -s "$1" "$2" 2>/dev/null; then echo "$PKG: $3 current"
  else sudo install -D -m 0644 -o root -g root "$1" "$2"
       echo "$PKG: wrote $3"; NEED_INITRAMFS=1; fi
}
place_theme() {
  while read -r _name _srcpath; do
    [ -n "$_name" ] || continue
    _place_theme "$_srcpath" "$BS_THEMEDIR/$_name" "plymouth theme $_name"
  done <<EOF
$(_theme_files)
EOF
}
select_theme() {
  if _alt_is_bootique; then
    echo "$PKG: default.plymouth already bootique"; return 0
  fi
  sudo "$UPDATE_ALTERNATIVES" --install "$BS_ALT_LINK" "$BS_ALT_NAME" \
    "$_alt_target" 200
  sudo "$UPDATE_ALTERNATIVES" --set "$BS_ALT_NAME" "$_alt_target"
  echo "$PKG: selected default.plymouth -> bootique"; NEED_INITRAMFS=1
}
place_dropin() {
  _tmp=$(mktemp)
  printf '%s\n' \
    '# Enable the bootique plymouth splash. Overrides the base' \
    '# GRUB_CMDLINE_LINUX_DEFAULT; remove + update-grub to revert to a text' \
    '# boot. GFXMODE + GFXPAYLOAD=keep make plymouth render at native res, so' \
    '# no low->high switch strands the bg in a corner.' \
    "GRUB_CMDLINE_LINUX_DEFAULT=\"$BS_CMDLINE\"" \
    'GRUB_GFXPAYLOAD_LINUX=keep' > "$_tmp"
  [ -n "$BS_GFXMODE" ] \
    && printf 'GRUB_GFXMODE=%s,auto\n' "$BS_GFXMODE" >> "$_tmp"
  if cmp -s "$_tmp" "$BS_DROPIN" 2>/dev/null; then
    echo "$PKG: splash cmdline drop-in current"
  else
    sudo install -D -m 0644 -o root -g root "$_tmp" "$BS_DROPIN"
    echo "$PKG: wrote splash cmdline drop-in ($BS_CMDLINE)"; NEED_GRUB=1
  fi
  rm -f "$_tmp"
}
_gpu_driver() {
  [ -n "${BS_GPU_DRIVER+x}" ] && { printf '%s' "$BS_GPU_DRIVER"; return 0; }
  for _d in /sys/class/drm/card*/device/driver; do
    [ -e "$_d" ] || continue
    [ "$(basename "$(readlink -f "$_d")")" = xe ] && { printf xe; return 0; }
  done
}
_uses_dracut() {
  case "${BS_USES_DRACUT:-auto}" in 1) return 0 ;; 0) return 1 ;; esac
  command -v dracut >/dev/null 2>&1 && [ -d /etc/dracut.conf.d ]
}
_rm_managed() {
  [ -e "$1" ] || return 0
  sudo rm -f "$1"; echo "$PKG: removed $2"; NEED_INITRAMFS=1
}
_dracut_conf() {
  printf '%s\n' \
    '# bootique early-KMS. Load the GPU driver early so the panel is native' \
    '# BEFORE the splash draws -- no low->native modeset to strand/zoom it.' \
    'force_drivers+=" xe "'
  _items=
  for _f in i915/xe2lpd_dmc.bin xe/lnl_guc_70.bin xe/lnl_huc.bin \
            xe/lnl_gsc_1.bin; do
    for _c in "$BS_FW_ROOT/$_f" "$BS_FW_ROOT/$_f.zst"; do
      [ -e "$_c" ] && _items="$_items $_c"
    done
  done
  [ -n "$_items" ] && printf 'install_items+="%s "\n' "$_items"
}
place_hook() {
  if cmp -s "$_hook_src" "$BS_HOOK_DST" 2>/dev/null; then
    echo "$PKG: early-KMS initramfs hook current"
  else
    sudo install -D -m 0755 -o root -g root "$_hook_src" "$BS_HOOK_DST"
    echo "$PKG: wrote early-KMS initramfs hook"; NEED_INITRAMFS=1
  fi
}
place_kms() {
  if _uses_dracut; then
    _rm_managed "$BS_HOOK_DST" "stale initramfs-tools hook (dracut box)"
    if [ "$(_gpu_driver)" = xe ]; then
      _tmp=$(mktemp); _dracut_conf > "$_tmp"
      if cmp -s "$_tmp" "$BS_DRACUT_CONF" 2>/dev/null; then
        echo "$PKG: dracut early-KMS conf current"
      else
        sudo install -D -m 0644 -o root -g root "$_tmp" "$BS_DRACUT_CONF"
        echo "$PKG: wrote dracut early-KMS conf (force xe)"; NEED_INITRAMFS=1
      fi
      rm -f "$_tmp"
    else
      _rm_managed "$BS_DRACUT_CONF" "dracut early-KMS conf (non-xe GPU)"
    fi
  else
    _rm_managed "$BS_DRACUT_CONF" "dracut early-KMS conf (non-dracut box)"
    place_hook
  fi
}

plymouth_install() {
  place_theme
  select_theme
  place_dropin
  place_kms
}

plymouth_check() {
  while read -r _name _srcpath; do
    [ -n "$_name" ] || continue
    cmp -s "$_srcpath" "$BS_THEMEDIR/$_name" 2>/dev/null \
      && ok "plymouth theme $_name current" \
      || bad "plymouth theme $_name missing or stale (install)"
  done <<EOF
$(_theme_files)
EOF
  _alt_is_bootique && ok "default.plymouth -> bootique" \
    || bad "default.plymouth not set to bootique (install)"
  grep -qE 'GRUB_CMDLINE_LINUX_DEFAULT=.*splash' "$BS_DROPIN" 2>/dev/null \
    && ok "splash cmdline drop-in enables splash" \
    || bad "splash cmdline drop-in missing or not enabling splash (install)"
  if _uses_dracut; then
    if [ "$(_gpu_driver)" = xe ]; then
      grep -qE 'force_drivers.*\bxe\b' "$BS_DRACUT_CONF" 2>/dev/null \
        && ok "dracut early-KMS conf forces xe" \
        || bad "dracut early-KMS conf missing or not forcing xe (install)"
      if [ -e "$BS_HOOK_DST" ]; then
        bad "stale initramfs-tools hook on a dracut box (install)"; fi
    else ok "early-KMS not applicable (GPU is not xe)"; fi
  else
    cmp -s "$_hook_src" "$BS_HOOK_DST" 2>/dev/null \
      && ok "early-KMS initramfs hook current" \
      || bad "early-KMS initramfs hook missing or stale (install)"
  fi
  return 0
}

# =========================== shared regen + dispatch ========================
regen() {
  if [ -n "$NEED_INITRAMFS" ]; then
    echo "$PKG: rebuilding initramfs (theme or early-KMS changed)"
    sudo "$UPDATE_INITRAMFS" -u
  fi
  if [ -n "$NEED_GRUB" ]; then
    echo "$PKG: regenerating grub.cfg (menu or cmdline changed)"
    sudo "$GRUB_MKCONFIG" -o "$GRUB_CFG"
  fi
  [ -n "$NEED_INITRAMFS$NEED_GRUB" ] \
    && echo "$PKG: boot cosmetics changed -- reboot to see them."
  return 0
}

do_install() {
  _did=
  if _has_grub; then grub_install; _did=1
  else echo "$PKG: grub-mkconfig absent; skipping the grub theme"; fi
  if _has_plymouth; then plymouth_install; _did=1
  else echo "$PKG: plymouth absent; skipping the boot splash"; fi
  [ -n "$_did" ] || { echo "$PKG: neither grub nor plymouth here; nothing"
                      return 0; }
  regen
}

do_uninstall() {
  for _f in "$GRUB_DROPIN_DST" "$BS_DROPIN" "$BS_DRACUT_CONF" "$BS_HOOK_DST"; do
    [ -e "$_f" ] && { sudo rm -f "$_f"; echo "$PKG: removed $_f"; }
  done
  _has_plymouth && _alt_is_bootique && {
    sudo "$UPDATE_ALTERNATIVES" --remove "$BS_ALT_NAME" "$_alt_target" \
      2>/dev/null || :; echo "$PKG: removed default.plymouth alternative"; }
  [ -d "$GRUB_ASSETDIR" ] && { sudo rm -rf "$GRUB_ASSETDIR"
                              echo "$PKG: removed $GRUB_ASSETDIR"; }
  [ -d "$BS_THEMEDIR" ] && { sudo rm -rf "$BS_THEMEDIR"
                            echo "$PKG: removed $BS_THEMEDIR"; }
  NEED_GRUB=1 NEED_INITRAMFS=1
  _has_grub && regen
  echo "$PKG: uninstalled (reverts to a plain boot on the next rebuild)."
}

do_check() {
  echo "== $PKG (boot cosmetics: grub menu + plymouth splash) =="
  _any=
  if _has_grub; then grub_check; _any=1
  else ok "grub-mkconfig absent; boot-menu styling not applicable"; fi
  if _has_plymouth; then plymouth_check; _any=1
  else ok "plymouth absent; boot splash not applicable"; fi
  [ -n "$_any" ] || ok "neither grub nor plymouth present"
}

_U="usage: setup.sh [install|uninstall|check|test|version]"
case "${1:-install}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   echo "$PKG $VERSION" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
