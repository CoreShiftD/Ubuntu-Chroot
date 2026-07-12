#!/system/bin/sh

# Ubuntu Chroot Installation Functions
# Clean, minimal implementation

TMPDIR=/dev/tmp
CHROOT_DIR="/data/local/droidian"
VERSION_FILE="$CHROOT_DIR/version"

# Detect root method and SELinux context, then generate sepolicy.rule
detect_root() {
    if command -v magisk >/dev/null 2>&1; then
        ROOT_METHOD="magisk"
        echo -e "- Magisk detected\n"
        echo "- WARNING: You may face various terminal bugs with Magisk."
        echo -e "- You can try downgrading your Magisk version to v28 or v29.\n"
    elif command -v ksud >/dev/null 2>&1; then
        ROOT_METHOD="kernelsu"
        echo -e "- KernelSU detected\n"
    elif command -v apd >/dev/null 2>&1; then
        ROOT_METHOD="apatch"
        echo -e "- Apatch detected\n"
    else
        ROOT_METHOD="unknown"
        echo -e "- Unknown root method detected. Proceed with caution.\n"
    fi

    # Check for SuSFS compatibility
    if zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_KSU_SUSFS=y" || [ -d /data/adb/modules/susfs4ksu ]; then
        echo -e "WARNING: SuSFS detected. You may encounter mounting issues with \"/proc\".\n"
        echo -e "Fix: Disable \"HIDE SUS MOUNTS FOR ALL PROCESSES\" in SuSFS4KSU settings.\n"
    fi

    # Detect SELinux context and generate sepolicy.rule
    generate_sepolicy
}

detect_selinux_context() {
    # Try reading current process context first
    local ctx
    ctx=$(cat /proc/$$/attr/current 2>/dev/null | tr -d '\n')

    # If that looks wrong, try via su (installer may run in different domain)
    if [ -z "$ctx" ] || ! echo "$ctx" | grep -q 'u:r:'; then
        ctx=$(su -c 'cat /proc/self/attr/current' 2>/dev/null | tr -d '\n')
    fi

    # Fallback: map known root methods to their typical domains
    if [ -z "$ctx" ] || ! echo "$ctx" | grep -q 'u:r:'; then
        case "$ROOT_METHOD" in
            kernelsu) ctx="u:r:ksu:s0" ;;
            magisk)   ctx="u:r:magisk:s0" ;;
            apatch)   ctx="u:r:apatch:s0" ;;
            *)        ctx="u:r:su:s0" ;;
        esac
    fi

    echo "$ctx"
}

generate_sepolicy() {
    local ctx
    local domain

    ctx=$(detect_selinux_context)
    # Extract domain from context (e.g., "u:r:ksu:s0" -> "ksu")
    domain=$(echo "$ctx" | sed 's/u:r:\([^:]*\).*/\1/')
    [ -z "$domain" ] && domain="su"

    echo "- Detected SELinux context: $ctx"
    echo "- Generating sepolicy.rule for domain: $domain"

    cat > "$MODPATH/sepolicy.rule" << EOF
# Droidian chroot SELinux policy
# Auto-generated for domain: $domain (context: $ctx)

# Allow mount operations for all filesystem types used by chroot
allow $domain proc:filesystem mount;
allow $domain proc_type:filesystem mount;
allow $domain sysfs:filesystem mount;
allow $domain tmpfs:filesystem mount;
allow $domain devpts:filesystem mount;
allow $domain devtmpfs:filesystem mount;
allow $domain cgroup:filesystem mount;
allow $domain binfmt_misc:filesystem mount;
allow $domain labeledfs:filesystem mount;

# Allow bind mounting
allow $domain tmpfs:dir mounton;
allow $domain devtmpfs:dir mounton;
allow $domain proc:dir mounton;
allow $domain sysfs:dir mounton;

# Loop device access (for mounting sparse images)
allow $domain loop_control_device:chr_file rw_file_perms;
allow $domain loop_device:blk_file rw_file_perms;

# Block device access (for IMAGES raw device mount)
allow $domain block_device:blk_file rw_file_perms;

# Namespace operations (unshare/nsenter)
allow $domain domain:process { transition setrlimit };
allow $domain self:capability sys_admin;

# Sysctl and /proc/sys access (hostname, ping, ip_forward, etc.)
allow $domain proc_net:file write;
allow $domain proc_net:tcp_socket read;
allow $domain proc_type:file write;
allow $domain sysctl_kernel:file write;
allow $domain sysctl_net:file write;
allow $domain sysctl_vm:file write;

# /sys access (firmware path, USB authorization, thermal)
allow $domain sysfs:file write;
allow $domain sysfs:dir write;

# SELinux state access
allow $domain selinuxfs:file { read write open };

# /dev access
allow $domain device:chr_file { read write open };
EOF

    echo "- sepolicy.rule generated for $domain"
    chmod 644 "$MODPATH/sepolicy.rule"
}

setup_busybox() {
    mkdir -p "$CHROOT_DIR/bin"

    if unzip -oj "$ZIPFILE" 'tools/bin/busybox' -d "$CHROOT_DIR/bin" >&2 \
        && chmod 755 "$CHROOT_DIR/bin/busybox"; then
        echo "- Busybox extracted successfully" >&2
        export BUSYBOX="$CHROOT_DIR/bin/busybox"
    else
        echo "- Failed to extract busybox, falling back to system busybox" >&2
        if ! command -v busybox >/dev/null 2>&1; then
            echo "- System busybox not found. Aborting." >&2
            exit 1
        fi
        export BUSYBOX="busybox"
    fi
}

# Extract core chroot files
setup_chroot() {
    mkdir -p "$CHROOT_DIR"
    setup_busybox
    unzip -oj "$ZIPFILE" 'tools/chroot.sh' -d "$CHROOT_DIR" >&2
    unzip -oj "$ZIPFILE" 'tools/start-hotspot' -d "$CHROOT_DIR" >&2
    unzip -oj "$ZIPFILE" 'tools/sparsemgr.sh' -d "$CHROOT_DIR" >&2
    unzip -oj "$ZIPFILE" 'tools/forward-nat.sh' -d "$CHROOT_DIR" >&2
    unzip -oj "$ZIPFILE" 'tools/update-status.sh' -d "$CHROOT_DIR" >&2
    mkdir -p "$CHROOT_DIR/initd"
    unzip -oj "$ZIPFILE" 'tools/initd/initd' -d "$CHROOT_DIR/initd" >&2 2>/dev/null
    unzip -oj "$ZIPFILE" 'tools/initd/systemctl' -d "$CHROOT_DIR/initd" >&2 2>/dev/null
    chmod 755 "$CHROOT_DIR/initd/initd" "$CHROOT_DIR/initd/systemctl" 2>/dev/null
    echo "- Core chroot files extracted"
}

# Setup OTA system
setup_ota() {
    mkdir -p "$CHROOT_DIR/ota"
    unzip -oj "$ZIPFILE" 'tools/updater.sh' -d "$CHROOT_DIR/ota" >&2
    unzip -oj "$ZIPFILE" 'tools/updates.sh' -d "$CHROOT_DIR/ota" >&2

    # Record version for OTA updates
    if [ ! -f "$VERSION_FILE" ]; then
        local version_code

        # Check if module was previously installed
        if [ -f "/data/adb/modules/droidian/module.prop" ]; then
            # Record OLD version from existing installation for proper OTA tracking
            version_code=$(grep "^versionCode=" "/data/adb/modules/droidian/module.prop" | cut -d'=' -f2)
            echo "- Recording previous version $version_code for OTA updates"
        else
            # Fresh install - record version from zip file
            unzip -oj "$ZIPFILE" 'module.prop' -d "$TMPDIR" >&2
            version_code=$(grep "^versionCode=" "$TMPDIR/module.prop" | cut -d'=' -f2)
            echo "- Fresh install - version $version_code recorded"
        fi

        echo "$version_code" > "$VERSION_FILE"
    fi
}

# Find rootfs file in ZIP
find_rootfs_file() {
    unzip -l "$ZIPFILE" 2>/dev/null | grep -E '\.tar\.gz$' | head -1 | while read -r line; do
        # Extract filename from the last field (handles spaces correctly)
        echo "$line" | rev | cut -d' ' -f1 | rev
    done
}

# Extract rootfs
extract_rootfs() {
    echo "- Setting up Ubuntu rootfs..."

    # Extract experimental config
    if unzip -oj "$ZIPFILE" 'experimental.conf' -d "$MODPATH" >&2 2>/dev/null; then
        true  # Config loaded silently
    fi
    # Also place it where chroot.sh can find it at runtime
    mkdir -p "$CHROOT_DIR"
    if [ -f "$MODPATH/experimental.conf" ]; then
        cp "$MODPATH/experimental.conf" "$CHROOT_DIR/experimental.conf" 2>/dev/null || true
    fi

    # Determine extraction method
    local use_sparse=false
    local use_premade=false
    if [ -f "$MODPATH/experimental.conf" ]; then
        . "$MODPATH/experimental.conf" 2>/dev/null
        if [ "$USE_SPARSE_IMAGE_METHOD" = "true" ]; then
            use_sparse=true
            echo "- Sparse image method enabled"
        fi
        if [ "$USE_PREMADE_IMAGE" = "true" ]; then
            use_premade=true
            echo "- Pre-made image mode enabled, skipping rootfs extraction"
        fi
    fi

    # If IMAGES is set, check if any entry provides the rootfs
    # (no mountpoint or mountpoint is /). If so, skip extraction.
    # Otherwise, IMAGES entries are sub-mounts that coexist with rootfs.img.
    if [ -n "$IMAGES" ]; then
        local _has_root=false
        for _entry in $IMAGES; do
            _dev="${_entry%%:*}"
            _mnt="${_entry#*:}"
            [ "$_mnt" = "$_dev" ] && _mnt=""
            if [ -z "$_mnt" ] || [ "$_mnt" = "/" ]; then
                _has_root=true
                echo "- IMAGES root device: $_dev"
                if [ -b "$_dev" ] || [ -f "$_dev" ]; then
                    echo "- Root device accessible at install time"
                else
                    echo "- WARNING: Root device not accessible at install time: $_dev"
                    echo "- It must be available at runtime"
                fi
            else
                echo "- IMAGES sub-mount: $_dev -> /$_mnt (will mount inside chroot)"
            fi
        done
        if [ "$_has_root" = true ]; then
            echo "- Skipping rootfs extraction (using IMAGES for rootfs)"
            return 0
        else
            echo "- IMAGES entries are all sub-mounts, proceeding with rootfs extraction"
        fi
    fi

    # If using a pre-made image, skip extraction entirely
    if [ "$use_premade" = true ]; then
        if [ -f "$CHROOT_DIR/rootfs.img" ]; then
            echo "- Found existing rootfs.img at $CHROOT_DIR/rootfs.img"
            echo "- Skipping rootfs extraction"
            return 0
        else
            echo "- WARNING: USE_PREMADE_IMAGE=true but no rootfs.img found at $CHROOT_DIR"
            echo "- You must place your ext4 or f2fs image at $CHROOT_DIR/rootfs.img"
            echo "- Proceeding with normal setup..."
        fi
    fi

    # Find rootfs file
    local rootfs_file
    rootfs_file=$(find_rootfs_file)

    if [ -z "$rootfs_file" ]; then
        echo "- No rootfs file found in ZIP archive..Skipping extraction..."
        return 0
    fi

    echo "- Found rootfs file: $rootfs_file"

    if [ "$use_sparse" = true ]; then
        extract_sparse "$rootfs_file"
    else
        extract_traditional "$rootfs_file"
    fi
}

# Extract to traditional directory
extract_traditional() {
    local rootfs_file="$1"
    local rootfs_dir="$CHROOT_DIR/rootfs"

    # Check if already exists
    if [ -d "$rootfs_dir" ]; then
        echo "- Rootfs directory already exists. Skipping extraction..."
        return 0
    fi

    echo "- Extracting Ubuntu rootfs..."

    # Create directory and extract
    mkdir -p "$rootfs_dir" "$TMPDIR"
    if unzip -oq "$ZIPFILE" "$rootfs_file" -d "$TMPDIR" && tar -xpf "$TMPDIR/$rootfs_file" -C "$rootfs_dir"; then
        unzip -oj "$ZIPFILE" 'tools/post_exec.sh' -d "$CHROOT_DIR" >&2
        echo "- Ubuntu rootfs extracted successfully"
        return 0
    else
        echo "- Rootfs extraction failed"
        rm -rf "$rootfs_dir"
        return 1
    fi
}

# Extract to sparse image
extract_sparse() {
    local rootfs_file="$1"
    local img_file="$CHROOT_DIR/rootfs.img"
    local rootfs_dir="$CHROOT_DIR/rootfs"

    # Check if image already exists
    if [ -f "$img_file" ]; then
        echo "- Sparse image already exists. Skipping setup..."
        return 0
    fi

    # Get size and fstype from config
    SPARSE_IMAGE_SIZE=${SPARSE_IMAGE_SIZE:-8}
    SPARSE_IMAGE_FSTYPE=${SPARSE_IMAGE_FSTYPE:-ext4}
    echo -e "- Creating sparse image: ${SPARSE_IMAGE_SIZE}GB (${SPARSE_IMAGE_FSTYPE})\n"

    # Create and format sparse image
    if ! truncate -s "${SPARSE_IMAGE_SIZE}G" "$img_file"; then
        echo "- Built-in truncate failed, trying busybox truncate..."
        "${BUSYBOX}" truncate -s "${SPARSE_IMAGE_SIZE}G" "$img_file" || return 1
    fi

    if [ "$SPARSE_IMAGE_FSTYPE" = "ext4" ]; then
        mkfs.ext4 -F -L "droidian" "$img_file" || {
            rm -f "$img_file"
            return 1
        }
    elif [ "$SPARSE_IMAGE_FSTYPE" = "f2fs" ]; then
        if command -v mkfs.f2fs >/dev/null 2>&1; then
            mkfs.f2fs -l "droidian" "$img_file" || {
                rm -f "$img_file"
                return 1
            }
        else
            echo "- mkfs.f2fs not available, falling back to ext4"
            mkfs.ext4 -F -L "droidian" "$img_file" || {
                rm -f "$img_file"
                return 1
            }
        fi
    fi

    # Mount and extract
    mkdir -p "$rootfs_dir"
    mount -t "$SPARSE_IMAGE_FSTYPE" -o loop,rw,noatime,nodiratime "$img_file" "$rootfs_dir" || {
        rm -f "$img_file"
        return 1
    }

    # Extract rootfs
    mkdir -p "$TMPDIR"
    echo -e "\n- Extracting rootfs to sparse image..."
    if unzip -oq "$ZIPFILE" "$rootfs_file" -d "$TMPDIR" && tar -xpf "$TMPDIR/$rootfs_file" -C "$rootfs_dir"; then
        echo "- Ubuntu rootfs extracted to sparse image"
        umount "$rootfs_dir"
        unzip -oj "$ZIPFILE" 'tools/post_exec.sh' -d "$CHROOT_DIR" >&2
        echo "- Sparse image setup completed"
        return 0
    else
        echo "- Sparse image extraction failed"
        umount "$rootfs_dir" 2>/dev/null
        rm -f "$img_file"
        return 1
    fi
}

# Create droidian command (copy instead of symlink to avoid broken links)
create_droidian_cmd() {
    mkdir -p "$MODPATH/system/bin"
    if cp "$CHROOT_DIR/chroot.sh" "$MODPATH/system/bin/droidian" && chmod 755 "$MODPATH/system/bin/droidian"; then
        echo "- Created 'droidian' command"
    else
        echo "- Failed to create 'droidian' command"
        exit 1
    fi
}
