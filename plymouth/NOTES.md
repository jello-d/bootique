# bootique boot splash (plymouth) -- design notes

The plymouth splash for the whole post-grub boot: initramfs -> LUKS passphrase
prompt -> systemd startup -> greetd handoff, styled to match the grub 'bootique'
menu and the greeter. Deployed + enabled by `modules/boot-splash` (theme files
here, plus the default.plymouth alternative, a quiet-splash grub.d drop-in, and
an initramfs rebuild). The naming wall: nothing deployed says tackup.

## Files
- `bootique.plymouth`  theme manifest (ModuleName=script).
- `bootique.script`    the theme (plymouth `script` plugin). Sizes/positions are
                       FRACTIONS of the panel, so it is resolution-independent
                       and the half-res VM preview is faithful.
- `pill.png`           the rounded light-green prompt pill (alpha PNG, generated
                       at the display aspect so scaling keeps clean corners).
- background.png is NOT here: the module copies the shared photo from
  deploy/grub/background.png (single source of truth).

## Layout / colour zones
- green in the MIDDLE: bold "Unlock disk to continue", the pill (dark-green
  passphrase bullets), and the green hint.
- dark PURPLE at the top: the current boot phase (systemd unit).
- lavender at the BOTTOM: the rolling boot-log scroll, fading up toward the
  treeline (~76% down, where the photo turns light); "Esc: full log" bottom-
  right in green, baseline-aligned with the newest scroll line.

## The scroll data-flow (verified in the VM, not guessable)
- The DENSE per-unit log flows through `SetUpdateStatusFunction`; the theme
  feeds each update into the rolling tail, so the tail is the boot log.
- `SetMessageFunction` carries only sparse notices (cryptsetup, fsck, failures);
  they interleave into the same tail.
- The full raw console log lives behind Esc (plymouth's own detail viewer).
- GOTCHA: `feed()` MUST be defined BEFORE `on_status` -- plymouth-script binds
  free names at DEFINITION time, so a later definition is unbound in on_status.

## Verifying the look
`test/vm/plymouth-vmcheck` renders the real DRM splash headlessly in a VM
(virtio-gpu-pci, plymouth.ignore-serial-consoles, sendkey unlock) and
screendumps the LUKS prompt, the bullets, and the dense scroll -- no reboot.
Only the actual Intel `xe` smoothness is left for a real boot.

It is a TEST, not just a screenshot tool -- it fails loud, so a regression
cannot slip through as it did once (a no-render splash shipped because the run
was eyeballed, not asserted):
- `plymouth-capture.py` ABORTS (rc 2) if the LUKS prompt never appears, rather
  than proceeding to screendump plausible garbage.
- `plymouth-verify.py` then ASSERTS the frames actually rendered: the bg fills
  the screen (all corners non-black -- the resize/stranded-corner detector),
  and the prompt pill is present (a green band at centre). The no-prompt bug
  that shipped fails this check; a black frame fails all of them.
- `vmcheck` exits non-zero (PASS/FAIL line) if either gate trips.
Calibrated against known-good / no-prompt / black frame sets: good -> PASS,
the other two -> FAIL.

NOT reproducible in qemu (so still real-boot-only): the post-unlock RESIZE.
On the Intel box the `xe` GPU driver loads ~35s in and modesets low-EFI-GOP ->
native, stranding the bg in a corner; qemu's virtio_gpu always sets native
immediately (three fb configs tried, none reproduce the late modeset), so this
harness cannot catch a resize regression -- verify's corner check would flag it
IF a run ever produced one, but a clean qemu run does not exercise the modeset.

## The post-unlock resize (fix: xe in the initramfs)

Root cause, confirmed from manifold's own boot log: simpledrm binds the low-res
EFI framebuffer at ~0s and renders the whole early boot; `xe` (the Lunar Lake
GPU driver) only loads ~35s in, from the ROOT fs via udev, and its modeset to
native 2880x1800 strands the bg in a corner. The old GRUB_GFXMODE pin can't fix
it: the firmware GOP never exposes native to grub.

The fix is to force xe (+ firmware) into the initramfs so native is up BEFORE
plymouth's first frame. The MECHANISM depends on the initramfs generator, which
`modules/boot-splash` detects:
- DRACUT (this fleet's btrfs standard -- manifold uses it): a generated drop-in
  `/etc/dracut.conf.d/90-bootique-kms.conf` with `force_drivers+=" xe "` (dracut
  turns this into `rd.driver.pre=xe` on the kernel cmdline) + `install_items`
  for the firmware xe requests at bind time (DMC + GuC are device-selected, NOT
  in modinfo, so listed explicitly; prefer the on-disk .zst).
- initramfs-tools (fallback): the self-gating hook deploy/plymouth/bootique-kms
  (`force_load xe`). NOTE dracut IGNORES this hook entirely -- it is why the
  first attempt never landed (I built an initramfs-tools hook on a dracut box;
  the btrfs memory's "dracut, NOT initramfs-tools; verify lsinitrd" said so).
Only the mechanism matching the generator is placed; the other is removed. xe-
only for now (the firmware list is xe/Lunar-Lake specific).

CONFIRMED clean on manifold (2026-08-13): the dracut test boot's journal shows
`rd.driver.pre=xe`, xedrmfb primary at 2.08s -- BEFORE cryptsetup starts (2.46s,
the unlock prompt) and 12s before Switching root -- so xe is at native before
the first splash frame. No late modeset, no churn.

Live verification needs a reboot (qemu can't reproduce the late modeset). The
safe path is the temp-grub-entry harness: build a separate test initramfs with
xe forced in (dracut --force-drivers xe --install <fw>), add a TEMP grub entry
that boots it, leave the default entry + its initramfs untouched. Verify xe
landed with `lsinitrd` (NOT lsinitramfs) before trusting the reboot. Handoff
scripts staged in /var/tmp (/tmp auto-wipes within minutes on this box).

### Why A is the ONLY reliable fix (the transition can't be tamed)

Established live, with plymouth.debug=file logging read back after each boot
(the diagnostic captured the whole modeset). On a LIVE low-res -> native
modeset, plymouth CHURNS renderers -- DRM(card0, simpledrm 1440x900) ->
frame-buffer(/dev/fb0, 2880x1800, re-inited twice) -> DRM(card1, xe) -- and
`Window.GetWidth()` MIS-REPORTS during it (returned 2880 while the scanout was
still 1440). Every theme/plymouth-side approach was tried live and FAILED:
- B relayout: trusted the reported 2880, laid out at 2880 on a 1440 buffer ->
  ZOOM. (The relayout logic itself is correct -- the logged readout showed
  exactly R1 1440x900 then R2 2880x1800, laid==live -- but the reported size is
  a lie, so correct logic still zooms.)
- plymouth.use-simpledrm: IGNORED under LUKS (the option even logs "Ignoring
  UseSimpledrmNoLuks because of LUKS use"); plymouth still switched to xe
  2880x1800 and churned. So a no-relayout theme strands and a relayout theme
  zooms -- neither wins.
So the transition is intractable from above. A (native up BEFORE plymouth's
first frame) is the fix precisely because it removes the transition: no
simpledrm phase to hand off from, no churn, no size lie. B stays as the
committed FALLBACK for a box where A is not active -- it drives the layout to
the correct FINAL size (fills the screen) rather than leaving it permanently
stranded in a corner; on an A box it never fires (no resize) and is inert.

### A on OTHER hardware (not yet generalized)

`bootique-kms` is xe-specific (hardcoded xe + its firmware) and self-gates, so
it only HELPS xe boxes and is inert elsewhere. A different GPU that shows the
same late-modeset needs its own driver + firmware forced early (the fiddly part:
device-runtime-selected blobs like xe's DMC are not in modinfo). Generalizable
by detecting the bound driver and harvesting the firmware it actually loaded
from the boot log at build time, but forcing an arbitrary GPU driver early is a
boot-risk to validate per box, so it stays targeted (xe today). manifestor
(Nvidia) has NOT been checked for this resize; it likely lacks it (discrete GPU,
its own POST) but confirm before assuming.

## Shutdown / reboot

One theme serves boot AND shutdown/reboot, branched on `Plymouth.GetMode()`
(`is_off`). On shutdown/reboot: the **warp** field (`shutdown-bg.png`) replaces
the forest, the scroll moves to **centre** in bright green (fed by the same
`on_status`/`on_message` with the stopping units), a soft dark **scrim.png**
sits behind it for contrast, and a bold **"Shutting down" / "Rebooting"** label
(from the mode) sits above. The unlock pill, top phase line, and Esc affordance
are boot-only. Verified in the VM by temporarily forcing `is_off=1` so the boot
harness renders the shutdown layout.
