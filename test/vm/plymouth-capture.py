#!/usr/bin/env python3
# test/vm/plymouth-capture.py - drives one boot of a plymouth-prepped guest to
# screendump the splash. Talks to the guest serial socket AND the qemu monitor
# socket, so it can screendump the framebuffer at chosen moments as it unlocks.
#
#   plymouth-capture.py <serial-sock> <monitor-sock> <outdir> <passphrase>
#
# Writes <outdir>/{01-luks-empty,02-luks-bullets,boot-NN,99-login}.ppm, plus the
# unlock-prompt state frames: race-NNs (a series across the racing window),
# 03-required (the hint after it escalates), 04-rejected (after a refused
# passphrase). The
# passphrase is typed via qemu `sendkey` (real key events reach plymouth's
# keyboard grab; serial input does not once plymouth owns the prompt), which
# also fills the pill with bullets. screendump targets the virtio-gpu device by
# id (gpu0) so it captures plymouth's scanout, not the stale firmware surface.
import socket, time, sys, re, subprocess

SER, MON, OUT, PASS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]


def connect(path, tries=90):
    for _ in range(tries):
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(path)
            return s
        except OSError:
            time.sleep(1)
    raise SystemExit("could not connect " + path)


def mon(cmd):
    s = connect(MON)
    try:
        s.settimeout(2)
        try:
            s.recv(8192)
        except OSError:
            pass
        s.sendall((cmd + "\n").encode())
        time.sleep(0.25)
        try:
            s.recv(8192)
        except OSError:
            pass
    finally:
        s.close()


def shot(name):
    mon("screendump %s/%s.ppm gpu0 0" % (OUT, name))
    print("[shot %s]" % name, flush=True)


def typestr(s):
    for ch in s:
        mon("sendkey " + ch)
        time.sleep(0.12)


ser = connect(SER)
buf = b""


def readuntil(pat, timeout):
    global buf
    end = time.time() + timeout
    rx = re.compile(pat.encode(), re.I)
    while time.time() < end:
        if rx.search(buf):
            return True
        ser.settimeout(1.0)
        try:
            d = ser.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            time.sleep(0.5)
            continue
        if d:
            buf += d
            sys.stdout.write(d.decode("latin1"))
            sys.stdout.flush()
    return False


def pill_on_screen():
    # Is the splash showing the unlock pill? Screendump a probe frame and look
    # for the light-green pill band at the centre (~0.44 of the height, where
    # the theme puts it). Detecting the prompt from the FRAME rather than from
    # the serial console is not a refinement, it is required: the guest boots
    # `quiet splash`, so the passphrase request goes to plymouth and NOTHING
    # about it is ever echoed to ttyS0. Waiting on the serial log for it hung
    # here until the timeout while the splash sat there, correctly rendered.
    p = "%s/probe.ppm" % OUT
    mon("screendump %s gpu0 0" % p)
    d = subprocess.run(["identify", "-format", "%w %h", p],
                       capture_output=True, text=True).stdout.split()
    if len(d) != 2:
        return False
    w, h = int(d[0]), int(d[1])
    crop = "%dx%d+%d+%d" % (int(0.4 * w), int(0.06 * h),
                            int(0.3 * w), int(0.44 * h))
    args = ["convert", p, "-crop", crop, "+repage",
            "-format", "%[fx:mean.g] %[fx:mean.r] %[fx:mean.b]", "info:"]
    r = subprocess.run(args, capture_output=True, text=True)
    try:
        g, rr, b = [float(x) for x in r.stdout.split()]
    except ValueError:
        return False
    return g > rr + 0.04 and g > b + 0.06


# 1) LUKS prompt blocks for input: capture the empty pill. FAIL LOUD if it
# never appears -- a run that did not reach its states is a failure, not a pass
# (silently proceeding produced plausible garbage frames before).
deadline = time.time() + 180
while time.time() < deadline and not pill_on_screen():
    time.sleep(2.0)
if time.time() >= deadline:
    print("CAPTURE FAILED: unlock pill never rendered", flush=True)
    sys.exit(2)
print("[unlock pill detected]", flush=True)
time.sleep(3.0)
shot("01-luks-empty")

# 1b) the RACING -> REQUIRED transition. bootique's theme starts a password
# request in the racing state ("an auto-unlock may still answer") and escalates
# the hint to required on its own after ~race_ticks refreshes. Shooting a SERIES
# rather than one frame past the deadline measures WHEN it flips, which is the
# only way to check the tick-rate assumption baked into race_ticks -- and the
# transition itself is the property the design must guarantee, so it gets its
# own frames rather than being inferred.
RACE_STEP, RACE_UNTIL = 4, 40
t = 3
while t < RACE_UNTIL:
    time.sleep(RACE_STEP)
    t += RACE_STEP
    shot("race-%02ds" % t)
shot("03-required")

# 1c) the REJECTED state: a deliberately wrong passphrase, then the re-prompt.
# Costs one of cryptsetup's tries (default 3), leaving enough for the real one.
# It runs AFTER the required capture because the rejected hint outranks the
# other two, so once it is showing the earlier states cannot be observed.
typestr("wrongpassphrase")
mon("sendkey ret")
time.sleep(8.0)
shot("04-rejected")

# 2) type most of the passphrase so bullets show, capture, then submit the rest
split = max(1, len(PASS) - 3)
typestr(PASS[:split])
time.sleep(1.0)
shot("02-luks-bullets")
typestr(PASS[split:])
mon("sendkey ret")

# 3) plyhold keeps the splash up ~25s; shoot the post-unlock dense scroll
for i in range(18):
    time.sleep(1.4)
    shot("boot-%02d" % i)

# 4) settle
readuntil(r"login:", 40)
shot("99-login")
print("CAPTURE DONE", flush=True)
