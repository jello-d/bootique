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
    PD = _dims(RACE)
    net = region(PD, 0.70, 0.030, 0.15, 0.3280)    # auto-unlock headline
    ttl = region(PD, 0.45, 0.030, 0.275, 0.3880)   # plain-state headline
    hnt = region(PD, 0.60, 0.033, 0.20, 0.4978)    # amber line under the pill
    trk = region(PD, 0.32, 0.020, 0.34, 0.3730)    # the progress track row

    def rg(png, band):
        return _fx(png, "mean.r-mean.g", band)

    b_net, b_ttl, b_hnt = rg(boot, net), rg(boot, ttl), rg(boot, hnt)
    if MODE == "remote":
        # racing: the auto-unlock headline is UP and green. This is the whole
        # point of the promoted layout -- a boot that is waiting on the network
        # must SAY so, prominently, not bury it in a line under the pill.
        d = b_net - rg(RACE, net)
        check("prompt: racing shows the green auto-unlock headline",
              d > 0.006, "green delta %.4f (want > 0.006)" % d)
        # and it must GIVE UP on its own: headline gone from the racing slot,
        # amber copy in the plain slot. A racing headline that never escalated
        # would promise an auto-unlock forever on a box whose anchor is down.
        gone = abs(rg(REQ, net) - b_net)
        amber = rg(REQ, ttl) - b_ttl
        check("prompt: racing headline clears when the window closes",
              gone < 0.005, "residual %.4f (want < 0.005)" % gone)
        check("prompt: required state states it in amber",
              amber > 0.005, "amber delta %.4f (want > 0.005)" % amber)
        # INFO, not an assertion: the track is 20 small sprites over a wide
        # band, so its colour signal is far weaker than text and has never been
        # measured on a real frame. Printed so the first real run calibrates it;
        # promote to a check once there is a number to set a threshold from.
        print("  INFO  track row green delta %.4f (racing)"
              % (b_ttl - rg(RACE, trk)), flush=True)
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
          rej > 0.005, "amber delta %.4f (want > 0.005)" % rej)
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

if fails:
    print("VERIFY FAILED: " + ", ".join(fails), flush=True)
    sys.exit(1)
print("VERIFY OK", flush=True)
