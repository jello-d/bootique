# VM render harness (heavy, manual)

This renders the actual Plymouth splash headlessly in a KVM guest and dumps
frames, so the theme's real DRM look (the LUKS prompt with bullets, three-state
unlock hint, the dense boot scroll) is verified WITHOUT rebooting a box. It is
SEPARATE from the fast stub suite (`test/run`): it needs KVM + a full LUKS OS
install, so it is run by hand, not on every change.

## Pieces

- `build-luks-base` -- builds the base image the render runs against: boots a
  noble cloud image as an installer and runs `tackdisk install` onto a blank
  disk. EXTERNAL DEP: `tackdisk` (the day-zero disk installer) lives in a
  separate checkout; point `TACKDISK_REPO` at it (default `$HOME/src/tackup`).
  This is the one piece that reaches outside bootique -- installing a bootable
  LUKS OS is the installer's job, not the theme's.
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

## Run

    # once: drop a noble cloud image in the scratch dir
    #   /var/tmp/plyvm/noble-server-cloudimg-amd64.img
    sh test/vm/build-luks-base                 # ~5-8 min, needs TACKDISK_REPO
    sh test/vm/plymouth-vmcheck \
        /var/tmp/plyvm/base-target.qcow2 testpass123

PNG frames land in `/var/tmp/plyvm/shots`. Needs `kvm`, `qemu-system-x86_64`,
`OVMF`, `python3`, `imagemagick`, `socat`, `xorriso`. Host-side, NO sudo (the
guest is root). Re-run at a second resolution (`PLYVM_XRES`/`PLYVM_YRES`) to
exercise the fraction-based layout scaling.
