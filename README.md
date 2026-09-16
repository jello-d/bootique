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
  "unlock disk" pill with passphrase bullets, a three-state unlock prompt (see
  below), and a rolling boot-log. One theme serves boot and shutdown, branched
  on `Plymouth.GetMode()`.
- **Early-KMS** — forces the GPU driver + firmware into the initramfs so the
  panel is at native resolution *before* Plymouth's first frame, killing the
  post-unlock resize/zoom. Self-gating: a dracut `force_drivers` drop-in on a
  dracut box with an `xe` GPU, the initramfs-tools hook otherwise, nothing on a
  non-xe box. Composes with other initramfs drop-ins (e.g. an early-boot ssh
  server for remote unlock) via `update-initramfs -u`.

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

`uninstall` removes everything it placed. It also reverts the one file bootique
edits but does not own (`/etc/grub.d/10_linux`), and *only* where a stamp
records that the edit was bootique's — where the setting already matched, it
cannot tell its own change from your preference, so it leaves it alone.

Tunables are environment variables read by `setup.sh` (font sizes, the selection
and frame colours, and every system path — the last so the test can drive it
against a scratch tree).

## The unlock prompt

Where a network auto-unlock (clevis/Tang) exists it races the human for the
*same* passphrase request: Plymouth is told to prompt at the instant clevis
starts trying, and nothing in the protocol says which one is expected. So the
pill is live from the first frame in either mode (typing has always worked;
the theme used to hide that), and the block around it carries the state:

| state    | what the screen says                                          |
| -------- | ------------------------------------------------------------- |
| racing   | **Unlocking automatically over the home network** as the       |
|          | headline, a progress track counting its window down, and the   |
|          | pill below under *or type your passphrase*                     |
| required | amber **Auto-unlock did not answer** + *type your passphrase   |
|          | to continue*                                                   |
| rejected | amber *incorrect passphrase, type it again* under the pill     |

While an auto-unlock is actually running it owns the headline, because that is
the thing happening — a boot waiting on the network should say so rather than
bury it in a caption. The track fills one cell per second with a pulsing head,
so the wait reads as *active* rather than hung, and the seconds beside it say
how long the racing copy has left.

`required` arrives on a timer (~20s), so the racing copy can never linger on a
box whose anchor is unreachable. Since the pill no longer gates the ability to
type, that timer is cosmetic: guessing wrong relabels early or late, it can
never delay an unlock. The window and the tick rate it is counted in are one
declaration each, with the escalation derived from them, so the countdown on
screen and the state change can never disagree.

Once the root filesystem is mounted the prompt is **latched shut** for the rest
of the boot. Plymouth replays its state to the theme when a late-loading GPU
driver brings up a new renderer, which happens after switch-root on a discrete
GPU; without the latch the theme read that replay as a second attempt and put a
pill reading "incorrect passphrase" over a boot that had already succeeded.

A box with no auto-unlock skips `racing` altogether and never claims to be
auto-unlocking. That is the whole point of the mode being a per-box fact:

- `remote` — *expect a network unlock attempt.* Show the auto-unlock headline
  and its track, and escalate to amber if nothing answers.
- `local` — *never attempt, never imply one.* No racing state, no track, no
  headline about a home network. A box that cannot auto-unlock must not make a
  promise it cannot keep, so this is enforced in the theme rather than left to
  copy: in `local` the racing state is closed before the first frame.

Either way the pill is live and typeable, so the mode only ever changes what
the screen *claims*, never what you can do. Which mode a box gets is baked into
the theme at install time, because the Plymouth script language can read
neither a file nor the kernel command line:

    ./setup.sh install                        # autodetect (is clevis here?)
    BS_UNLOCK_MODE=remote ./setup.sh install  # override, this run only
    echo remote | sudo tee /etc/bootique/unlock-mode   # persistent override

The file is the hook for a provisioning layer: it is read by `check` too, which
an environment variable would not be, so a box pinned by policy audits clean
instead of reporting drift it cannot explain. Pin it explicitly on any box
whose answer must not depend on detection — autodetection asks the cheap,
sudo-free question ("does this box carry clevis?"), which is not the same as
"is this disk actually bound to it".

`check` compares the installed theme against what *this* box should have, so a
box that gains or loses its auto-unlock reports drift instead of passing with
stale copy.

## Not the unlock mechanism

bootique is deliberately **just the look**. It is not fused with the disk-unlock
mechanism (clevis / dracut-sshd remote unlock) — that is a separate,
boot-critical security path with a different owner. bootique only *reads*
whether such a mechanism is present, to pick its prompt copy; its early-KMS
drop-in *composes* with that setup's own initramfs drop-ins.

## Development

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once
per clone:

    git config core.hooksPath .githooks

## License

Apache-2.0.
