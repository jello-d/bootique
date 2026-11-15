#!/bin/bash
# shellcheck disable=SC2154  # moddir, initdir, SYSTEMCTL...: dracut sets them
# bootique-heads, the dracut module: carries /usr/libexec/bootique-heads and
# its unit into the initramfs, pulled in by plymouth-start (see the unit).
# Only when asked for (bootique's dracut conf adds it) and only in a systemd
# initramfs: elsewhere nothing changes, so the screen stays mirrored.

# called by dracut
check() {
    return 255
}

# called by dracut
depends() {
    echo plymouth systemd
}

# called by dracut
install() {
    inst_multiple cat head grep sed sleep mkdir cp mount
    inst_script "$moddir/bootique-heads" /usr/libexec/bootique-heads
    inst_simple "$moddir/bootique-heads.service" \
        "$systemdsystemunitdir/bootique-heads.service"
    $SYSTEMCTL -q --root "$initdir" enable bootique-heads.service
}
