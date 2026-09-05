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


def check(name, cond):
    print(("  PASS " if cond else "  FAIL ") + name, flush=True)
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
# bootique keeps the pill live and carries the state in the HINT under it: calm
# green while an auto-unlock may still answer, amber once the timer says nothing
# else is coming, amber again for a refused passphrase. The test compares the
# hint band's red-vs-green BETWEEN frames rather than against a fixed number,
# because all three share an identical background so the only difference is the
# text colour. An absolute threshold would be worthless here: measured on real
# frames, the bare forest photo scores 0.024 and sits BETWEEN the green text
# (0.014) and the amber (0.032).
RACE, REQ, REJ = "01-luks-empty.png", "03-required.png", "04-rejected.png"
if not (exists(RACE) and exists(REQ) and exists(REJ)):
    check("prompt state frames exist (racing/required/rejected)", False)
else:
    PD = _dims(RACE)
    hint = region(PD, 0.6, 0.033, 0.2, 0.4978)
    w_race = _fx(RACE, "mean.r-mean.g", hint)
    w_req = _fx(REQ, "mean.r-mean.g", hint)
    w_rej = _fx(REJ, "mean.r-mean.g", hint)
    if MODE == "remote":
        # The required state MUST arrive on its own: a racing hint that never
        # escalated would leave "an auto-unlock may still answer" up forever.
        check("prompt: racing hint escalates to the amber required hint",
              w_req - w_race > 0.010)
    else:
        # local mode: nothing races the human here, so the hint must NOT
        # escalate and no boot may ever claim to be auto-unlocking. The whole
        # point of the mode split is that such a box waits for nothing.
        check("prompt: local mode never escalates (nothing to wait for)",
              abs(w_req - w_race) < 0.004)
    check("prompt: a refused passphrase switches the hint to amber",
          w_rej - w_race > 0.008)
    # And the prompt must be GONE once the disk is open. plymouth leaves a
    # sprite's last pixels on screen when its image is cleared to NULL, which
    # left the title and hint painted over the whole boot -- so a boot that
    # succeeded could still read "incorrect passphrase". The title band is a
    # clean detector: green text scores +0.004 there, the bare photo -0.024.
    if boot is not None:
        title_band = region(_dims(boot), 0.5, 0.034, 0.25, 0.3844)
        check("prompt: cleared after unlock (no stale title over the boot)",
              _fx(boot, "mean.g-mean.r", title_band) < -0.010)

if fails:
    print("VERIFY FAILED: " + ", ".join(fails), flush=True)
    sys.exit(1)
print("VERIFY OK", flush=True)
