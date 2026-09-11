# VM render harness (heavy, manual)

This renders the actual Plymouth splash headlessly in a KVM guest and dumps
frames, so the theme's real DRM look (the LUKS prompt with bullets, three-state
unlock hint, the dense boot scroll) is verified WITHOUT rebooting a box. It is
SEPARATE from the fast stub suite (`test/run`): it needs KVM + a full LUKS OS
install, so it is run by hand, not on every change.

## Pieces

- `build-luks-base` -- builds the base image the render runs against: boots an
  Ubuntu cloud image as an installer and runs `tackdisk install` onto a blank
  disk. `PLYVM_SUITE` picks the release (default `noble`) for both the installer
  image and the debootstrapped suite, so they always match. EXTERNAL DEP:
  `tackdisk` (the day-zero disk installer) lives in a separate checkout; point
  `TACKDISK_REPO` at it (default `$HOME/src/tackup`). This is the one piece that
  reaches outside bootique -- installing a bootable LUKS OS is the installer's
  job, not the theme's.
- `plymouth-vmcheck` -- the driver: injects THIS repo's theme (`plymouth/` +
  `background.png`) into an overlay on the base, boots, and screendumps. Reads
  the theme from the repo root by default (override `PLYVM_BOOTIQUE`).
- `plymouth-prep.sh` -- runs in the guest: installs plymouth, injects the theme,
  rebuilds the initramfs.
- `plymouth-capture.py` -- drives the boot over the qemu monitor/serial and
  screendumps the key frames, including the racing -> required -> rejected
  unlock states.
- `plymouth-verify.py` -- asserts the frames rendered the expected elements
  (background fills every corner; the prompt pill is present); turns the harness
  from a screenshot tool into a pass/fail test.
- `vmexpect` -- a generic expect-over-serial-socket driver.

## The late renderer

The capture VM carries a SECOND display device (`bochs-display`) whose driver is
held back by a modprobe.d blacklist and loaded by `late-renderer.service` a few
seconds into the splash hold. That reproduces the event this harness was
otherwise blind to, and it is the event behind the worst bug the theme has had:
a DRM device appearing while plymouthd is ALREADY RUNNING, after the unlock, so
plymouth attaches a new renderer and replays its password state onto it.

What is late is the DRIVER, not the hardware -- which is the faithful model,
since on the real box the GPU was never absent, only its module was late. It is
done this way because qemu refuses to hotplug a display device at all
(`Device 'virtio-gpu-pci' does not support hotplugging`).

The gpu1 frames are named `boot-late-*` so the post-unlock "no pill" assertion
covers them with the rest. `plymouth-verify.py` reports whether plymouth
actually ADOPTED the renderer, because a run where it did not has not tested the
replay path however green the rest of the output looks -- and a blank frame
would otherwise bank a free pass on the one assertion that matters most.

KNOWN, and visible in the `boot-late-*` frames: the second display renders at
its own size (1280x800) while the layout was computed for the primary
(1440x900), so the boot-log scroll sits partly off its left edge. A `script`
theme has ONE coordinate space and plymouth draws every sprite to every
renderer, so a two-display guest of MIXED sizes cannot have both right. It is
not known to affect the fleet (one GPU driving several outputs is a different
case) and is not asserted on; treat these frames as evidence about the PROMPT,
not about scroll placement.

## Initramfs generator: `PLYVM_INITRD`

`initramfs-tools` (the default) is the path this harness verifies today, and it
passes. `dracut` switches the guest to dracut, which matters because it is what
a real box here runs AND it changes who asks for the passphrase: systemd-
cryptsetup and systemd-ask-password, rather than initramfs-tools calling
`plymouth ask-for-password`. The theme's rejected state depends on how that path
sequences `display_normal`, so it deserves its own pass.

Both modes pass, but the dracut one only on a base matching the target release,
which is what `PLYVM_SUITE` is for:

    PLYVM_SUITE=resolute sh test/vm/build-luks-base
    PLYVM_INITRD=dracut sh test/vm/plymouth-vmcheck \
        /var/tmp/plyvm/base-resolute-target.qcow2 testpass123

On a NOBLE base the dracut mode proves nothing, and it is worth knowing why
before trusting a green run there. noble ships dracut 060, whose plymouth module
gates on a Fedora-ism Debian and Ubuntu never shipped, so the module is skipped
and the initramfs gets no splash (`plymouth-prep.sh` shims that check; the shim
is a harmless no-op on a release that does not need it). Even shimmed, that
guest brings up no DRM device in the initramfs, so plymouth falls back to TEXT
mode, the `script` plugin never loads, and no theme state can be observed at
all. resolute ships dracut 110, which checks for `plymouth-populate-initrd`
instead and works.

## Run

    # once per suite: drop its cloud image in the scratch dir, from
    #   https://cloud-images.ubuntu.com/<suite>/current/
    sh test/vm/build-luks-base                 # ~5-8 min, needs TACKDISK_REPO
    sh test/vm/plymouth-vmcheck \
        /var/tmp/plyvm/base-noble-target.qcow2 testpass123

    # the dracut pass, on a base matching the release a real box runs
    PLYVM_SUITE=resolute sh test/vm/build-luks-base
    PLYVM_INITRD=dracut sh test/vm/plymouth-vmcheck \
        /var/tmp/plyvm/base-resolute-target.qcow2 testpass123

PNG frames land in `/var/tmp/plyvm/shots`. Needs `kvm`, `qemu-system-x86_64`,
`OVMF`, `python3`, `imagemagick`, `socat`, `xorriso`. Host-side, NO sudo (the
guest is root). Re-run at a second resolution (`PLYVM_XRES`/`PLYVM_YRES`) to
exercise the fraction-based layout scaling.
