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

## The unlock prompt: three states, two modes

The problem is that a password request carries NO "the human is needed" signal.
`systemd-cryptsetup` issues one ask-password; plymouth is told to display it and
`clevis-luks-askpass` reacts to the same file, concurrently. The theme's
callback gets only `(prompt, bullets)`: no requester identity, no attempt state,
and the prompt string is systemd's own either way. There is no runtime
discriminator, so any answer here is either baked in at install time or pushed
in over the message channel.

An earlier design used the PILL ITSELF as the signal, hiding it behind a long
grace so it appeared only once an auto-unlock had plainly failed. That made the
timer load-bearing: the pill gated the user's ability to act, so a wrong guess
cost real time (measured at ~30s per boot on a box that had no auto-unlock at
all). Worse, the quiet state could linger indefinitely.

Now the pill is LIVE from the first frame in both modes. That is not a new
capability: plymouthd owns the entry buffer, so a blind-typed passphrase always
worked, and whichever answer lands first (typed or clevis) unlocks the disk.
What changes is the block AROUND it: `racing` -> `required` on a ~20s timer, or
`rejected` when a second request means the first answer was refused. Because
the pill no longer gates anything, the timer is COSMETIC, which is the whole
reason a heuristic is tolerable here.

In `racing` the auto-unlock OWNS THE HEADLINE and the pill is demoted to a
labelled alternative underneath it, because that is the honest hierarchy: the
thing actually happening is a network unlock, and a caption under a pill read
as a footnote to a prompt that appeared to be waiting on the human. Under the
headline is a progress track -- one cell per racing second, sprites rather than
a text bar (a proportional font gives its glyphs different advance widths, so a
text bar visibly JITTERS as it fills, and a block-drawing glyph may not even be
in the font set plymouth carries into the initramfs) -- with the frontier cell
pulsing at 2Hz. The pulse is load-bearing for the UX: a cell lands only once a
second, which is far too slow on its own to read as activity rather than as a
hang. The racing window and the tick rate it is counted in are ONE declaration
each (`race_secs`, `tps`) with `race_ticks` DERIVED, so the countdown on screen
and the moment the state escalates cannot drift apart.

`unlock_mode` ("remote" where something races, "local" where typing is the only
way in) is GENERATED into the installed theme by `setup.sh`, autodetected from
the box and overridable. A local-mode box never shows `racing` and never claims
to be auto-unlocking.

### The post-unlock latch (the phase-2 pill)

The prompt is LATCHED SHUT at root-mounted: after that, `on_password` draws
nothing for the rest of the boot. Without it a pill reading "incorrect
passphrase" appeared during the POST-SWITCH-ROOT half of the boot, over a boot
that had already succeeded -- the single most confusing thing the splash could
possibly say.

What manifestor's journal establishes (boots of Sep 9/10/11, all identical):

- `plymouthd` is the SAME PROCESS either side of switch-root (PID 475 from
  16.7s in the initramfs to 34.3s at quit). It is not restarted, so every
  script global -- `attempt` above all -- carries into phase 2.
- systemd issues EXACTLY ONE ask-password. `systemd-ask-password-plymouth`
  deactivates at 27.5s and never starts again, and there is one LUKS volume in
  crypttab. So nothing legitimately asks for a passphrase in phase 2.
- `nvidia-drm` loads at 28.9s and takes fb0 at 30.4s -- AFTER switch-root
  (26.4s), while the splash is still up (quits 34.2s). A late renderer arrives
  under a running theme.

So the request that drove `attempt` from 1 to 2 was plymouth REPLAYING its
state onto the new renderer, not a real second prompt. The latch is the fix,
and it is the right shape independent of the cause: once the root fs is
mounted, the disk is open, and no further password request is this theme's to
draw.

It is NOTED in the boot scroll ("ignoring a password request after unlock")
rather than swallowed, and that line is also the DISCRIMINATOR for the one
remaining possibility: if a pill ever shows up after the unlock WITHOUT that
line, no callback fired and the cause is a stale framebuffer re-blit on the
modeset instead -- which no theme can fix, and which needs the GPU driver in
the initramfs (early-KMS, today xe-only).

VERIFIED 2026-09-11, both ways round. On HARDWARE: two manifestor reboots with
zero parser errors, the replay window genuinely exercised (nvidia-drm took fb0
at 30.6s, splash up until 34.8s), and no pill reported. In the VM: the harness
now MAKES a renderer attach late (a second DRM device whose driver is loaded
under the running splash, see test/vm/README.md), plymouth adopted it, and the
splash it drew on that renderer carries no prompt. The assertion was also
negative-controlled -- dropping a pill frame into the post-unlock set fails it,
naming the frame -- so it is a test that can actually fail, not a green light.

### VM-verified (2026-09-04), and what the run taught

Both modes rendered and behaved correctly under tackup's
`test/vm/plymouth-vmcheck` on real DRM. Three findings that were NOT guessable:

- `SetImage(NULL)` DOES NOT ERASE A SPRITE. Plymouth repaints a sprite's region
  when given a new image, but a NULL one repaints nothing, so the last pixels
  stay on screen. `hide_prompt` cleared the pill and dots (opacity) while the
  title and hint sat over the entire boot. That is a PRE-EXISTING bug, visible
  in archived frames from before this work, and it got worse here because the
  lingering line could read "incorrect passphrase" on a boot that succeeded.
  Hide with `SetOpacity(0)`, and pair it with `SetOpacity(1)` in `centre()`.
- The refresh rate assumption is now MEASURED, not inferred. Shooting a frame
  every 4s across the racing window put the escalation between 15s and 19s for
  `race_ticks = 1000`, which is the ~50/s the value was written against.
- `display_normal` fires three times per boot (at startup, at a rejected
  passphrase, and after a successful unlock) and root-mounted once after the
  unlock. So the rejected state's "a second request means the first was
  refused" assumption holds.

The layout also passes at a second resolution (1920x1200), which exercises the
fraction-based geometry and the verifier's fraction-resolved crop regions.

BOTH ASKPASS PATHS are covered. The above is initramfs-tools, where the prompt
comes from `plymouth ask-for-password`. The same three states also pass under
dracut 110 + systemd-cryptsetup + systemd-ask-password, which is what a real box
here runs, on a base built from the matching release (`PLYVM_SUITE=resolute`,
see `test/vm/README.md` for why a noble base cannot answer this). That settles
the one assumption this design rested on: `display_normal` DOES fire between a
refused passphrase and the re-prompt on the systemd path, so `rejected` shows
there too.

Still worth building when convenient: `clevis-luks-askpass` knows the moment
every binding has failed, and a `plymouth display-message` there would arrive in
`on_message` and make `required` an EVENT instead of a timer. That lives in the
initramfs, so it belongs to whatever owns the unlock mechanism, not here.

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

AUTOMATED 2026-09-11. This half used to be verified by temporarily forcing
`is_off=1` so the BOOT harness rendered the shutdown layout -- which tests the
layout but never the branch that SELECTS it, leaving "does a real shutdown pick
this at all" untestable. The harness now presses the ACPI power button at the
end of the capture and screendumps the actual shutdown, holding the splash with
a unit ordered after plymouth-poweroff and before the poweroff itself (see
test/vm/README.md). Verified: the warp background replaces the forest and the
bold "Shutting down" label renders, both negative-controlled.

One theme serves boot AND shutdown/reboot, branched on `Plymouth.GetMode()`
(`is_off`). On shutdown/reboot: the **warp** field (`shutdown-bg.png`) replaces
the forest, the scroll moves to **centre** in bright green (fed by the same
`on_status`/`on_message` with the stopping units), a soft dark **scrim.png**
sits behind it for contrast, and a bold **"Shutting down" / "Rebooting"** label
(from the mode) sits above. The unlock pill, top phase line, and Esc affordance
are boot-only. Verified in the VM by temporarily forcing `is_off=1` so the boot
harness renders the shutdown layout.
