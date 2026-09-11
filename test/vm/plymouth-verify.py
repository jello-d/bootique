#!/usr/bin/env python3
# test/vm/plymouth-verify.py - ASSERT that the captured plymouth frames actually
# rendered the expected elements, so a splash that renders nothing (or renders
# in a corner) FAILS the harness instead of being eyeballed. Turns the capture
# into a test. Exits non-zero if any assertion fails.
#
#   plymouth-verify.py <shots-dir>
#
# PLYVM_UNLOCK_MODE (local|remote, default remote) selects which unlock-prompt
# behaviour to assert; plymouth-vmcheck derives it from the theme it injected,
# so the two can never disagree.
#
# Uses ImageMagick (convert/identify) via subprocess; no python image deps.
import os, sys, subprocess

OUT = sys.argv[1]
MODE = os.environ.get("PLYVM_UNLOCK_MODE", "remote")
fails = []


def _dims(png):
    r = subprocess.run(["identify", "-format", "%w %h", "%s/%s" % (OUT, png)],
                       capture_output=True, text=True)
    w, h = r.stdout.split()
    return int(w), int(h)


def _fx(png, expr, crop=None):
    # evaluate an ImageMagick %[fx:...] expression over png (optionally a crop),
    # returns a float. crop is a PIXEL WxH+X+Y geometry (see region()).
    args = ["convert", "%s/%s" % (OUT, png)]
    if crop:
        args += ["-crop", crop, "+repage"]
    args += ["-format", "%[fx:" + expr + "]", "info:"]
    r = subprocess.run(args, capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return -1.0


def green_frac(png, crop):
    # fraction of pixels in crop that are BRIGHT GREEN the way the theme's
    # shutdown label and scroll are (0.20/0.92/0.38). Used instead of a
    # band-vs-band colour comparison where the BACKGROUND itself varies a lot
    # across the frame -- on the radial warp field, brightness at the centre
    # and at the edge have nothing to do with each other, so any spatial
    # reference measures the background, not the text. Requiring green to lead
    # BOTH other channels clearly excludes the warp's cyan rays (g~b) and its
    # white ones (g~r).
    args = ["convert", "%s/%s" % (OUT, png), "-crop", crop, "+repage",
            "-fx", "(g>0.6 && g>r+0.3 && g>b+0.3) ? 1 : 0",
            "-format", "%[fx:mean]", "info:"]
    r = subprocess.run(args, capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return -1.0


def region(dims, wf, hf, xf, yf):
    # PIXEL crop geometry from fractions of the frame (dims=(w,h)). ImageMagick
    # crop OFFSETS are pixels, not percent, so resolve them here.
    w, h = dims
    return "%dx%d+%d+%d" % (int(wf * w), int(hf * h), int(xf * w), int(yf * h))


def check(name, cond, detail=""):
    # The measured value is PRINTED alongside every verdict, not just kept for
    # a failure. These are colour deltas a few thousandths wide, so the numbers
    # are how a threshold gets re-calibrated after a layout change -- without
    # them the only way to retune is to re-run and instrument by hand.
    line = ("  PASS " if cond else "  FAIL ") + name
    if detail:
        line += "   [" + detail + "]"
    print(line, flush=True)
    if not cond:
        fails.append(name)


def exists(png):
    import os
    return os.path.isfile("%s/%s" % (OUT, png))


# --- the LUKS prompt frame: bg must fill, and the prompt must be present ------
luks = "01-luks-empty.png"
if not exists(luks):
    check("luks frame exists", False)
else:
    D = _dims(luks)
    # not blank (something rendered, not an all-black screen)
    check("luks: not blank (mean > 0.05)", _fx(luks, "mean") > 0.05)
    # background FILLS the screen: all four corners are non-black. This is the
    # resize/stranded-bg detector -- a splash shrunk to a corner leaves the
    # opposite corners black.
    br = _fx(luks, "mean", region(D, 0.12, 0.12, 0.85, 0.85))
    bl = _fx(luks, "mean", region(D, 0.12, 0.12, 0.03, 0.85))
    check("luks: bg fills (bottom corners non-black)", br > 0.05 and bl > 0.05)
    # the PROMPT rendered: the pill sits centred at ~0.44H; that band should be
    # GREENISH (the light-green pill), i.e. green clearly above red/blue. An
    # empty splash (the bug that shipped) shows only the warm pale bg here
    # (red >= green) -> fails.
    band = region(D, 0.4, 0.06, 0.3, 0.44)
    g = _fx(luks, "mean.g", band)
    r = _fx(luks, "mean.r", band)
    b = _fx(luks, "mean.b", band)
    check("luks: prompt pill present (green band at centre)",
          g > r + 0.04 and g > b + 0.06)

# --- a post-unlock boot frame: bg still fills, something still drawn ----------
boot = None
for i in range(6, 16):
    c = "boot-%02d.png" % i
    if exists(c):
        boot = c
        break
if boot is None:
    check("a boot frame exists", False)
else:
    BD = _dims(boot)
    check("boot: not blank (mean > 0.05)", _fx(boot, "mean") > 0.05)
    br = _fx(boot, "mean", region(BD, 0.12, 0.12, 0.85, 0.85))
    check("boot: bg fills (bottom-right non-black)", br > 0.05)

# --- the LATCH: no prompt may come back after the unlock ----------------------
# Once the root fs is mounted the theme latches the prompt shut, because
# plymouth REPLAYS its password state onto a renderer that attaches late -- a
# discrete GPU whose driver loads after switch-root, with the splash still up --
# and the theme counted that replay as a second attempt, putting a pill reading
# "incorrect passphrase" over a boot that had already succeeded.
#
# EVERY post-unlock frame is checked, not just one: a replay lands whenever the
# driver happens to load, so sampling a single frame would miss it by timing.
# The detector is the same light-green pill band the capture uses to FIND the
# prompt, so a pill that is visible enough to drive the capture is visible
# enough to fail this.
shots = sorted(f for f in os.listdir(OUT)
               if f.startswith("boot-") and f.endswith(".png"))
# A frame with nothing drawn in it cannot show a pill, so counting it as a pass
# would be a silent lie -- and the late-renderer frames are exactly where that
# can happen (if plymouth declines to attach the second DRM device, gpu1 stays
# blank). Split them out and REPORT them instead of quietly banking a green.
live = [f for f in shots if _fx(f, "mean") >= 0.05]
blank = [f for f in shots if f not in live]
late_live = [f for f in live if f.startswith("boot-late")]
late_all = [f for f in shots if f.startswith("boot-late")]
if not live:
    check("latch: post-unlock frames exist and rendered", False)
else:
    worst, worst_f = -9.0, None
    for f in live:
        pb = region(_dims(f), 0.4, 0.06, 0.3, 0.44)
        # score it as the WEAKER of the two margins, so one number answers
        # "is there a pill here" the same way the capture's detector does.
        s = min(_fx(f, "mean.g-mean.r", pb) - 0.04,
                _fx(f, "mean.g-mean.b", pb) - 0.06)
        if s > worst:
            worst, worst_f = s, f
    check("latch: no pill in any of the %d post-unlock frames" % len(live),
          worst < 0, "worst %.4f in %s (want < 0)" % (worst, worst_f))
if blank:
    print("  INFO  %d post-unlock frame(s) rendered nothing, so they assert"
          " nothing: %s" % (len(blank), ", ".join(blank)), flush=True)
# The late renderer is the whole point of the second display device, so say
# plainly whether it was exercised. A run where plymouth never adopted it has
# NOT tested the replay path, however green the rest of the output looks.
if not late_all:
    print("  INFO  no late-renderer frames captured this run", flush=True)
elif late_live:
    print("  INFO  late renderer ADOPTED by plymouth (%d of %d frames drew);"
          " the replay path was exercised"
          % (len(late_live), len(late_all)), flush=True)
else:
    print("  INFO  late renderer NOT adopted (all %d frames blank); the"
          " replay path was NOT exercised this run" % len(late_all),
          flush=True)

# --- the unlock prompt's three states -----------------------------------------
# bootique keeps the pill live and carries the state in the block AROUND it.
# While an auto-unlock is running it owns the headline HIGH on the screen (with
# a progress track under it) and the pill is demoted to a labelled alternative;
# once the window closes, or a passphrase is refused, the headline drops back to
# its plain slot and the amber copy appears under the pill. So the states are
# told apart by WHICH BAND carries text, not by one band changing colour.
#
# Every measurement is red-vs-green against the SAME band in the post-unlock
# frame, where the latch guarantees nothing is drawn -- so the baseline is this
# run's own bare photo rather than a number baked in here. Measured on real
# frames: the photo scores 0.024, green text 0.014, amber 0.032, i.e. green
# pulls the band DOWN by ~0.010 and amber pushes it UP by ~0.008.
#
# GEOMETRY: these fractions mirror bootique.script's compute_geometry (net_y
# 0.330, title_y 0.390, and the hint at pill_y + pill_h + 0.015 = 0.505). Move
# one and the other must follow.
RACE, REQ, REJ = "01-luks-empty.png", "03-required.png", "04-rejected.png"
if not (exists(RACE) and exists(REQ) and exists(REJ)):
    check("prompt state frames exist (racing/required/rejected)", False)
elif boot is None:
    check("a post-unlock frame exists (the photo baseline)", False)
else:
    # Bands are kept TIGHT around the text/sprites they measure. A generous band
    # is mostly background, which dilutes the signal into the noise: the same
    # rejected hint scored +0.0064 in a 0.60-wide band and +0.0257 in this one,
    # i.e. the loose band passed its threshold by 1.3x and this one by 2.5x.
    # Every threshold below is a measured value with margin, not a guess.
    PD = _dims(RACE)
    net = region(PD, 0.70, 0.030, 0.15, 0.3280)    # auto-unlock headline
    ttl = region(PD, 0.45, 0.030, 0.275, 0.3880)   # plain-state headline
    hnt = region(PD, 0.24, 0.020, 0.38, 0.5020)    # amber line under the pill
    trk = region(PD, 0.18, 0.014, 0.41, 0.3755)    # the progress track row

    def rg(png, band):
        return _fx(png, "mean.r-mean.g", band)

    b_net, b_ttl, b_hnt = rg(boot, net), rg(boot, ttl), rg(boot, hnt)
    b_trk = rg(boot, trk)
    if MODE == "remote":
        # racing: the auto-unlock headline is UP and green. This is the whole
        # point of the promoted layout -- a boot that is waiting on the network
        # must SAY so, prominently, not bury it in a line under the pill.
        d = b_net - rg(RACE, net)
        check("prompt: racing shows the green auto-unlock headline",
              d > 0.020, "green delta %.4f (want > 0.020)" % d)
        # and it must GIVE UP on its own: headline gone from the racing slot,
        # amber copy in the plain slot. A racing headline that never escalated
        # would promise an auto-unlock forever on a box whose anchor is down.
        gone = abs(rg(REQ, net) - b_net)
        amber = rg(REQ, ttl) - b_ttl
        check("prompt: racing headline clears when the window closes",
              gone < 0.005, "residual %.4f (want < 0.005)" % gone)
        check("prompt: required state states it in amber",
              amber > 0.010, "amber delta %.4f (want > 0.010)" % amber)
        # The TRACK has to be present while racing and GONE once the window
        # closes -- a progress bar left over a state it no longer describes is
        # worse than none.
        tp = b_trk - rg(RACE, trk)
        tg = abs(rg(REQ, trk) - b_trk)
        check("track: present while racing", tp > 0.008,
              "green delta %.4f (want > 0.008)" % tp)
        check("track: gone once the window closes", tg < 0.004,
              "residual %.4f (want < 0.004)" % tg)
        # ...and it must actually ADVANCE. This is the claim the whole promoted
        # layout rests on: the row says the wait is PROGRESSING, so a track that
        # renders but never fills would be a lie the other checks cannot catch.
        # Measured across one racing window: -0.017 -> -0.024 -> -0.031 ->
        # -0.039 as cells land, then 0 at the escalation.
        seq = []
        for f in sorted(os.listdir(OUT)):
            if f.startswith("race-") and f.endswith(".png"):
                v = b_trk - _fx(f, "mean.r-mean.g",
                                region(_dims(f), 0.18, 0.014, 0.41, 0.3755))
                if v > 0.008:            # the track is still on screen here
                    seq.append((f, v))
        if len(seq) < 2:
            check("track: advances as the window elapses", False,
                  "only %d racing frame(s) showed a track" % len(seq))
        else:
            grew = seq[-1][1] - seq[0][1]
            check("track: advances as the window elapses", grew > 0.004,
                  "grew %.4f over %d frames, %s -> %s (want > 0.004)"
                  % (grew, len(seq), seq[0][0], seq[-1][0]))
    else:
        # local mode: nothing races the human here, so the auto-unlock headline
        # must NEVER appear and the state must never escalate. This is the mode
        # split earning its keep -- a box with no auto-unlock must not make a
        # promise it cannot keep, in any frame of any boot.
        claim = abs(rg(RACE, net) - b_net)
        check("prompt: local mode never claims to be auto-unlocking",
              claim < 0.005, "headline delta %.4f (want < 0.005)" % claim)
        moved = abs(rg(REQ, ttl) - rg(RACE, ttl))
        check("prompt: local mode never escalates (nothing to wait for)",
              moved < 0.004, "drift %.4f (want < 0.004)" % moved)
    # a refused passphrase is amber under the pill in BOTH modes.
    rej = rg(REJ, hnt) - b_hnt
    check("prompt: a refused passphrase switches the hint to amber",
          rej > 0.010, "amber delta %.4f (want > 0.010)" % rej)
    # And the prompt must be GONE once the disk is open -- in BOTH headline
    # slots. plymouth leaves a sprite's last pixels on screen when its image is
    # cleared to NULL, which once left the title painted over the whole boot, so
    # a boot that succeeded could still read "incorrect passphrase". Since the
    # theme now also LATCHES the prompt shut at root-mounted, this doubles as
    # the check that a replayed password request cannot put the pill back.
    band = region(_dims(boot), 0.5, 0.034, 0.25, 0.3844)
    stale = _fx(boot, "mean.g-mean.r", band)
    check("prompt: cleared after unlock (no stale title over the boot)",
          stale < -0.010, "green score %.4f (want < -0.010)" % stale)

# --- shutdown / reboot: the other half of the theme ---------------------------
# One theme serves boot AND shutdown, branched on Plymouth.GetMode(). The is_off
# half swaps the forest photo for the warp field, centres the scroll in bright
# green and puts a bold mode label above it. It had NO automated coverage until
# now: it was checked by hand-editing is_off=1 and running the BOOT harness,
# which exercises the LAYOUT but never the branch that selects it -- so the one
# thing that could not be tested was whether a real shutdown picks it at all.
#
# The background is the discriminator and it is not a close call: the warp
# scores mean 0.23 where the forest scores 0.77.
sd = sorted(f for f in os.listdir(OUT)
            if f.startswith("shutdown-") and f.endswith(".png"))
if not sd:
    check("shutdown: frames captured", False)
else:
    # A BLACK frame is dark, so "dark means the warp is up" would be satisfied
    # by a display that had already been torn down -- which is exactly what the
    # first run caught (one frame, mean 0.000, and a cheerful pass). Only frames
    # that actually rendered can answer anything, so they are selected FIRST.
    means = [(f, _fx(f, "mean")) for f in sd]
    drew = [(f, v) for f, v in means if v >= 0.05]
    if not drew:
        check("shutdown: the splash rendered before the guest powered off",
              False, "%d frame(s), all blank (darkest %.3f) -- the splash was"
              " missed or never came up" % (len(sd), min(v for _, v in means)))
    else:
        darkest, dv = min(drew, key=lambda t: t[1])
        check("shutdown: the warp background replaced the forest", dv < 0.45,
              "darkest rendered %.3f in %s (%d of %d frames drew, want < 0.45)"
              % (dv, darkest, len(drew), len(sd)))
        # The bold mode label ("Shutting down" / "Rebooting") sits centred just
        # above the scroll, at tail_bottom - 8*tail_gap - 0.06H = 0.344H. It is
        # found by COUNTING bright-green pixels, which separates cleanly where
        # a band comparison did not: measured 0.1224 in this band on every
        # shutdown frame that drew the label, against EXACTLY 0.0000 on every
        # control -- the boot splash, a boot-scroll frame, and the warp itself
        # away from the label. Checked across all rendered frames because the
        # earliest ones can predate the label being drawn.
        lab = region(_dims(darkest), 0.24, 0.035, 0.38, 0.3450)
        best, best_f = -1.0, None
        for f, _v in drew:
            g = green_frac(f, lab)
            if g > best:
                best, best_f = g, f
        check("shutdown: the bold mode label is on screen in green",
              best > 0.02, "green pixels %.4f in %s (want > 0.02)"
              % (best, best_f))

if fails:
    print("VERIFY FAILED: " + ", ".join(fails), flush=True)
    sys.exit(1)
print("VERIFY OK", flush=True)
