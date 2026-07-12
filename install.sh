export ZIPFILE="$ZIPFILE"
export TMPDIR="$TMPDIR"

# source our functions
unzip -o "$ZIPFILE" 'META-INF/*' -d $TMPDIR >&2
. "$TMPDIR/META-INF/com/google/android/util_functions.sh"

SKIPMOUNT=false
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

print_modname() {
    echo "  _   _ _             _        "
    echo " | | | | |__ _  _ _ _| |_ _  _ "
    echo " | |_| | '_ | || | ' |  _| || |"
    echo "  \___/|_.__/\_,_|_||_\__|\_,_|"
    echo "  / __| |_  _ _ ___ ___| |_    "
    echo " | (__| ' \| '_/ _ / _ |  _|   "
    echo "  \___|_||_|_| \___\___/\__|   "
    echo "                               "
    echo "       by @ravindu644          "
    echo " "
}

on_install() {
    # Detect root method and show warnings
    detect_root

    # Extract web interface files
    unzip -o "$ZIPFILE" 'webroot/*' -d $MODPATH >&2
    unzip -oj "$ZIPFILE" 'service.sh' -d $MODPATH >&2
    unzip -oj "$ZIPFILE" 'update.json' -d $MODPATH >&2

    # Extract and setup chroot components
    setup_chroot
    setup_ota
    extract_rootfs
    create_droidian_cmd

    # Show update message if this is an update ZIP (check for marker file)
    if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "\.is_update"; then
        echo -e "\n[UPDATER] Update the Chroot from the WebUI once rebooted the device\n"
    fi

    # Clear package cache to avoid conflicts
    rm -rf /data/system/package_cache/*
}

set_permissions() {
    # Set permissions for module files
    set_perm_recursive $MODPATH 0 0 0755 0644

    # Set permissions for chroot scripts
    set_perm "/data/local/droidian/chroot.sh" 0 0 0755
    set_perm "/data/local/droidian/post_exec.sh" 0 0 0755
    set_perm "/data/local/droidian/start-hotspot" 0 0 0755
    set_perm "/data/local/droidian/update-status.sh" 0 0 0755
    set_perm "/data/local/droidian/ota" 0 0 0755
    set_perm "/data/local/droidian/ota/updater.sh" 0 0 0755
    set_perm "/data/local/droidian/ota/updates.sh" 0 0 0755
    set_perm "/data/local/droidian/sparsemgr.sh" 0 0 0755

    # Set permissions for module service script
    set_perm "$MODPATH/service.sh" 0 0 0755
}
