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
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

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

update-initramfs -u
update-grub
sync
echo "PLYPREP_DONE"
poweroff
