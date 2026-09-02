# bootique

**One boot look, from the GRUB menu through the LUKS prompt to the greeter.**

bootique is a boot-cosmetics suite: a GRUB menu theme and a Plymouth boot
splash that share one forest photo and one palette, so a machine looks like
itself from power-on to login. Unlike a `~/.local` gadget it is a *theme pack
with a system installer* — its `setup.sh` installs to `/boot/grub/themes/
bootique` and `/usr/share/plymouth/themes/bootique` (root, sudo) and rebuilds
the initramfs + `grub.cfg`.

- **GRUB menu theme** — a photo background, generated DejaVu Sans Mono fonts (at
  the box's native-res boot), deep-purple menu text, a light-green selection
  bar, and a purple frame near the screen edges. A real GRUB theme (not the
  16-colour `menu_color` knob) so the colours are exact hex.
- **Plymouth boot splash** — a `script`-plugin theme: the forest photo, a green
  "unlock disk" pill with passphrase bullets and a long grace (so the pill never
  flashes on an auto-unlock), and a rolling boot-log. One theme serves boot and
  shutdown, branched on `Plymouth.GetMode()`.
- **Early-KMS** — forces the GPU driver + firmware into the initramfs so the
  panel is at native resolution *before* Plymouth's first frame, killing the
  post-unlock resize/zoom. Self-gating: a dracut `force_drivers` drop-in on a
  dracut box with an `xe` GPU, the initramfs-tools hook otherwise, nothing on a
  non-xe box. Composes with other initramfs drop-ins (e.g. a remote-unlock
  dropbear) via `update-initramfs -u`.

## Install

    ./setup.sh install     # place both themes + early-KMS; regen initramfs+grub
    ./setup.sh uninstall   # remove the themes + drop-ins; back to a plain boot
    ./setup.sh check       # audit; [OK]/[FAIL] markers; non-zero on drift
    ./setup.sh test        # the in-repo stub suite (no root, nothing touched)

`install` is idempotent — every piece is cmp/size/stamp-gated, so a settled box
is a no-op and the initramfs/`grub.cfg` regenerate only on a change. It needs
sudo for the system installs. Each missing dependency degrades with a note:
`grub-mkfont` + ImageMagick `convert` (the GRUB fonts, selection bar, frame),
the DejaVu Sans Mono TTFs, and Plymouth. A box without GRUB or without Plymouth
simply skips that half.

Tunables are environment variables read by `setup.sh` (font sizes, the selection
and frame colours, and every system path — the last so the test can drive it
against a scratch tree).

## Not the unlock mechanism

bootique is deliberately **just the look**. It is not fused with the disk-unlock
mechanism (clevis / dracut-sshd remote unlock) — that is a separate,
boot-critical security path with a different owner. bootique's early-KMS drop-in
just *composes* with such a setup's own initramfs drop-ins.

## Development

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once
per clone:

    git config core.hooksPath .githooks

## License

Apache-2.0.
