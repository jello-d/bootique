#!/bin/sh
# test/vm/plymouth-prep.sh - runs as root IN the guest (via a 9p share) to make
# a clean LUKS+btrfs target render the bootique plymouth splash, so
# plymouth-vmcheck can screendump it. Brings up the qemu user-net, installs
# plymouth, copies the REPO theme from the share, enables the splash, rebuilds
# the initramfs, and powers off. The cmdline knobs here are TEST-ONLY (the
# bootique pkg's setup.sh uses a plain "quiet splash"):
#   console=ttyS0                    drive the LUKS prompt over serial
#   plymouth.ignore-serial-consoles  render GRAPHICALLY despite the serial
#                                    console (else plymouth forces text mode)
#   MODULES=most                     put the qemu DRM driver in the initramfs
#                                    (else the LUKS-stage splash is blank)
#   plyhold.service                  keep the splash up ~25s (this VM reaches
#                                    login in ~5s, too fast to screendump)
#
# INITRD GENERATOR: read from /mnt/h/initrd-mode, default initramfs-tools.
# `dracut` switches the guest to dracut, which is what a real box here runs, and
# it is NOT a cosmetic difference: dracut brings the systemd module, so the LUKS
# prompt comes from systemd-cryptsetup and systemd-ask-password rather than
# initramfs-tools calling `plymouth ask-for-password`. The theme's rejected
# state depends on how that path sequences display_normal, so it has to be
# exercised on both.
set -eux
echo "PLYPREP_START"
# qemu user-net is 10.0.2.15/24, gw .2, dns .3 (no DHCP client configured here).
IFACE=$(ip -o link show | awk -F': ' '$2 ~ /^en/{print $2; exit}')
nmcli device set "$IFACE" managed no 2>/dev/null || true
ip addr add 10.0.2.15/24 dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up
ip route add default via 10.0.2.2 2>/dev/null || true
rm -f /etc/resolv.conf                     # drop the systemd stub symlink first
printf 'nameserver 10.0.2.3\n' > /etc/resolv.conf
getent hosts archive.ubuntu.com >/dev/null \
  || { echo "PLYPREP_NET_FAIL iface=$IFACE"; sleep 2; poweroff; }
echo "PLYPREP_NET_OK iface=$IFACE"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y plymouth plymouth-label

DEST=/usr/share/plymouth/themes/bootique
install -d "$DEST"
_tf="bootique.plymouth bootique.script pill.png dot.png"
_tf="$_tf shutdown-bg.png scrim.png background.png"
for f in $_tf; do
  install -m0644 "/mnt/h/theme/$f" "$DEST/$f"
done
update-alternatives --install /usr/share/plymouth/themes/default.plymouth \
  default.plymouth "$DEST/bootique.plymouth" 200
update-alternatives --set default.plymouth "$DEST/bootique.plymouth"

_cl='GRUB_CMDLINE_LINUX_DEFAULT="quiet splash console=ttyS0'
_cl="$_cl plymouth.ignore-serial-consoles\""
printf '%s\n' "$_cl" > /etc/default/grub.d/zz-splash.cfg

cat > /etc/systemd/system/plyhold.service <<'U'
[Unit]
Description=hold plymouth splash for capture
After=plymouth-start.service
Before=plymouth-quit.service plymouth-quit-wait.service
[Service]
Type=oneshot
ExecStart=/bin/sleep 25
[Install]
WantedBy=multi-user.target
U
systemctl enable plyhold.service

# --- the LATE RENDERER ---------------------------------------------------
# Reproduce the one event this harness was blind to: a DRM device appearing
# while plymouthd is ALREADY RUNNING, after the unlock. On a discrete-GPU box
# the display driver loads after switch-root, plymouth attaches the new
# renderer and REPLAYS its password state onto it -- which the theme once read
# as a second password attempt and captioned "incorrect passphrase" over a boot
# that had already succeeded.
#
# The capture VM carries a SECOND display device (bochs-display) for this. What
# is late is the DRIVER, not the hardware, which is exactly the real case: the
# GPU was always in the machine, its module just loaded late. A plain
# modprobe.d blacklist is the right lever -- it suppresses the udev ALIAS
# auto-load (including inside the initramfs) while leaving an explicit
# `modprobe bochs` working, so the load happens when this unit says so and not
# a moment earlier.
printf 'blacklist bochs\n' > /etc/modprobe.d/vmtest-late-renderer.conf

cat > /etc/systemd/system/late-renderer.service <<'U'
[Unit]
Description=attach a second DRM device late, under the running splash
After=plymouth-start.service
Before=plymouth-quit.service plymouth-quit-wait.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sleep 6; modprobe bochs; sleep 2; \
  { echo LATE_RENDERER_DRI: $(ls /dev/dri 2>&1); } > /dev/ttyS0 2>&1 || true'
[Install]
WantedBy=multi-user.target
U
systemctl enable late-renderer.service

# Hold the SHUTDOWN splash the way plyhold holds the boot one. A guest with
# nothing to stop powers off in about a second, which is not long enough to
# screendump -- the first attempt caught a single already-black frame.
#
# The ordering is the whole trick. plymouth-poweroff.service runs LATE in the
# shutdown transaction (it is ordered Before=systemd-poweroff.service), so the
# usual "slow ExecStop on a normal unit" delay happens while units are still
# being stopped, which is BEFORE the shutdown splash exists. This unit instead
# sits in the same late window: after plymouth has put the splash up, before
# the thing that actually cuts power.
cat > /etc/systemd/system/sdhold.service <<'U'
[Unit]
Description=hold the shutdown splash for capture
DefaultDependencies=no
After=plymouth-poweroff.service plymouth-reboot.service
Before=systemd-poweroff.service systemd-reboot.service
# Only on the CAPTURE boot. This script's own poweroff happens seconds after
# the unit is enabled, and holding THAT shutdown delays the "Power down" the
# prep driver waits for, close enough to the boundary to fail intermittently.
# The cmdline is the honest discriminator between the two boots: update-grub
# runs at the END of this script, so the prep boot is still on the base
# cmdline and only the capture boot carries the splash knobs.
ConditionKernelCommandLine=plymouth.ignore-serial-consoles
[Service]
Type=oneshot
ExecStart=/bin/sleep 18
[Install]
WantedBy=poweroff.target reboot.target
U
systemctl enable sdhold.service

INITRD=$(cat /mnt/h/initrd-mode 2>/dev/null || echo initramfs-tools)
echo "PLYPREP_INITRD=$INITRD"
if [ "$INITRD" = dracut ]; then
  # Installing dracut REPLACES initramfs-tools (both provide the initramfs
  # tool), which is the point: this guest should generate its boot image the way
  # a real box does. hostonly picks up this system's crypt/root layout, but its
  # GPU guess would be wrong -- the prep VM runs plain VGA while the capture VM
  # runs virtio-gpu -- so the DRM driver is forced in by name. Without it the
  # LUKS-stage splash renders nothing, the same trap MODULES=most avoids on the
  # initramfs-tools side.
  # A debootstrapped base carries only `main`, and dracut lives in universe.
  . /etc/os-release
  printf 'deb http://archive.ubuntu.com/ubuntu %s universe\n' \
    "$VERSION_CODENAME" > /etc/apt/sources.list.d/vmtest-universe.list
  apt-get update -y
  # Fail FAST and loud rather than letting set -e kill the script silently and
  # leave the driver waiting out its whole timeout for a PLYPREP_DONE.
  apt-get install -y dracut || { echo "PLYPREP_NO_DRACUT"; sync; poweroff -f; }
  # noble ships dracut 060, whose plymouth module gates on a FEDORA-ism
  # (plymouth-set-default-theme) that Debian and Ubuntu have never shipped, so
  # the module is silently skipped and the initramfs gets no splash at all. A
  # later dracut (110, what a current box runs) checks for plymouth-populate-
  # initrd instead and includes it fine. This shim satisfies the old check so
  # the guest exercises the path the real box takes; it prints the default theme
  # name, which is all that command is asked for here.
  if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
    printf '#!/bin/sh\necho bootique\n' > /usr/sbin/plymouth-set-default-theme
    chmod 0755 /usr/sbin/plymouth-set-default-theme
  fi
  mkdir -p /etc/dracut.conf.d
  # hostonly is what makes dracut embed THIS system's crypt layout. Without it
  # the initrd knows nothing about the LUKS root (there is no rd.luks.* on the
  # cmdline, because initramfs-tools never needed one), so it reaches
  # cryptsetup.target vacuously, never prompts, and hangs waiting for a device
  # nobody unlocked. A real box here builds hostonly, so this matches it.
  # add_drivers is still needed on top: hostonly would bake in the PREP VM's
  # GPU (plain VGA) while the capture VM runs virtio-gpu, leaving plymouth with
  # no DRM device and a text-mode boot.
  printf 'hostonly=yes\nadd_drivers+=" virtio_gpu virtio_dma_buf "\n' \
    > /etc/dracut.conf.d/90-vmtest.conf
  KVER=$(ls /boot/vmlinuz-* | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
  dracut --force "/boot/initrd.img-$KVER" "$KVER"
  lsinitrd "/boot/initrd.img-$KVER" | grep -c bootique || true
else
  sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
  update-initramfs -u
fi
update-grub
sync
echo "PLYPREP_DONE"
poweroff
