#!/bin/sh
set -eu
umask 022

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=${NPRF_ROOT:-}
ALLOW_NON_ROOT=${NPRF_ALLOW_NON_ROOT:-0}
SKIP_REBUILD=${NPRF_SKIP_REBUILD:-0}
DRY_RUN=0
GENERATOR=auto
TIMEOUT_VALUE=8
MIN_DURATION_VALUE=0
ALL_KERNELS=0
FORCE_LOAD=0

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]

Options:
  --timeout SECONDS        Wait this long for a usable NVIDIA DRM card (default: 8)
  --min-duration SECONDS   Keep Plymouth visible this long after DRM is ready (default: 0)
  --generator NAME         auto, dracut, or initramfs-tools (default: auto)
  --force-load             Force NVIDIA DRM modules to load in the initramfs
  --all-kernels            Rebuild every installed initramfs instead of the running kernel
  --dry-run                Print the plan without writing anything; root is not required
  -h, --help               Show this help
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --timeout)
            [ "$#" -ge 2 ] || die "--timeout requires a value"
            TIMEOUT_VALUE=$2
            shift 2
            ;;
        --min-duration)
            [ "$#" -ge 2 ] || die "--min-duration requires a value"
            MIN_DURATION_VALUE=$2
            shift 2
            ;;
        --generator)
            [ "$#" -ge 2 ] || die "--generator requires a value"
            GENERATOR=$2
            shift 2
            ;;
        --force-load)
            FORCE_LOAD=1
            shift
            ;;
        --all-kernels)
            ALL_KERNELS=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$TIMEOUT_VALUE" in
    ''|*[!0-9]*) die "timeout must be a non-negative integer" ;;
esac
case "$MIN_DURATION_VALUE" in
    ''|*[!0-9]*) die "minimum duration must be a non-negative integer" ;;
esac
[ "$TIMEOUT_VALUE" -le 120 ] || die "timeout must not exceed 120 seconds"
[ "$MIN_DURATION_VALUE" -le 120 ] || die "minimum duration must not exceed 120 seconds"
case "$GENERATOR" in
    auto|dracut|initramfs-tools) ;;
    *) die "generator must be auto, dracut, or initramfs-tools" ;;
esac

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

current_initramfs() {
    kernel=$(uname -r)
    if [ -e "/boot/initrd.img-$kernel" ]; then
        printf '/boot/initrd.img-%s\n' "$kernel"
    elif [ -e "/boot/initramfs-$kernel.img" ]; then
        printf '/boot/initramfs-%s.img\n' "$kernel"
    else
        printf '%s\n' ''
    fi
}

detect_generator() {
    image=$(current_initramfs)
    if command_exists lsinitrd && [ -n "$image" ] && [ -r "$image" ] && lsinitrd -m "$image" 2>/dev/null | grep -q 'dracut modules'; then
        printf '%s\n' dracut
    elif command_exists update-initramfs; then
        printf '%s\n' initramfs-tools
    elif command_exists dracut; then
        printf '%s\n' dracut
    else
        die "could not detect dracut or initramfs-tools"
    fi
}

if [ "$GENERATOR" = auto ]; then
    GENERATOR=$(detect_generator)
fi

printf '%s\n' "nvidia-plymouth-race-fix installation plan"
printf '  generator: %s\n' "$GENERATOR"
printf '  timeout: %s\n' "$TIMEOUT_VALUE"
printf '  minimum splash duration: %s\n' "$MIN_DURATION_VALUE"
printf '  force early NVIDIA loading: %s\n' "$(if [ "$FORCE_LOAD" -eq 1 ]; then echo yes; else echo no; fi)"
printf '  kernels: %s\n' "$(if [ "$ALL_KERNELS" -eq 1 ]; then echo all; else uname -r; fi)"
printf '%s\n' '  selected Plymouth theme: unchanged'

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' 'Dry run: no files were changed.'
    exit 0
fi

if [ "$(id -u)" -ne 0 ] && [ "$ALLOW_NON_ROOT" != 1 ]; then
    die "run as root (for example: sudo ./install.sh)"
fi

if [ -z "$ROOT" ]; then
    command_exists systemctl || die "systemd is required"
    command_exists plymouthd || die "Plymouth is not installed"
    command_exists udevadm || die "udevadm is required"
    command_exists sha256sum || die "sha256sum is required"
    if ! command_exists modinfo || ! modinfo nvidia_drm >/dev/null 2>&1; then
        [ -d /sys/module/nvidia_drm ] || die "the NVIDIA DRM kernel module was not found"
    fi
    case "$GENERATOR" in
        dracut)
            command_exists dracut || die "dracut is not installed"
            image=$(current_initramfs)
            if [ -n "$image" ] && command_exists lsinitrd; then
                unit_text=$(lsinitrd -f /usr/lib/systemd/system/plymouth-start.service "$image" 2>/dev/null || true)
                [ -n "$unit_text" ] || die "this dracut image is not systemd-based; the automated dracut backend is unsupported"
            fi
            ;;
        initramfs-tools) command_exists update-initramfs || die "update-initramfs is not installed" ;;
    esac
fi

STATE_VIRTUAL=/var/lib/nvidia-plymouth-race-fix
STATE_DIR="$ROOT$STATE_VIRTUAL"
MANIFEST="$STATE_DIR/installed-files.tsv"
CHECKSUMS="$STATE_DIR/installed-checksums.tsv"
METADATA="$STATE_DIR/metadata"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$STATE_DIR/backups/$STAMP"
mkdir -p "$STATE_DIR"
: > "$STATE_DIR/.write-test"
rm -f "$STATE_DIR/.write-test"
touch "$MANIFEST" "$CHECKSUMS"

metadata_value() {
    key=$1
    [ -r "$METADATA" ] || return 1
    awk -F '=' -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$METADATA"
}

previous_generator=$(metadata_value GENERATOR 2>/dev/null || true)
if [ -n "$previous_generator" ] && [ "$previous_generator" != "$GENERATOR" ]; then
    die "already installed for $previous_generator; uninstall before switching generators"
fi

{
    printf 'GENERATOR=%s\n' "$GENERATOR"
    printf 'INSTALLED_KERNEL=%s\n' "$(uname -r)"
    printf 'KERNEL_SCOPE=%s\n' "$(if [ "$ALL_KERNELS" -eq 1 ]; then echo all; else echo current; fi)"
    printf 'FORCE_LOAD=%s\n' "$FORCE_LOAD"
} > "$METADATA"

is_recorded() {
    virtual=$1
    awk -F '\t' -v path="$virtual" '$1 == path { found=1 } END { exit found ? 0 : 1 }' "$MANIFEST"
}

record_target() {
    virtual=$1
    target="$ROOT$virtual"
    is_recorded "$virtual" && return 0
    backup=
    if [ -e "$target" ] || [ -L "$target" ]; then
        backup="$BACKUP_DIR${virtual}"
        mkdir -p "$(dirname -- "$backup")"
        cp -a "$target" "$backup"
    fi
    printf '%s\t%s\n' "$virtual" "$backup" >> "$MANIFEST"
}

checksum_target() {
    target=$1
    if [ -L "$target" ]; then
        printf 'symlink:%s\n' "$(readlink "$target")"
    elif [ -f "$target" ]; then
        sha256sum "$target" | awk '{ print $1 }'
    else
        printf '%s\n' missing
    fi
}

record_checksum() {
    virtual=$1
    target="$ROOT$virtual"
    value=$(checksum_target "$target")
    temp="$CHECKSUMS.tmp.$$"
    awk -F '\t' -v path="$virtual" '$1 != path' "$CHECKSUMS" > "$temp"
    printf '%s\t%s\n' "$virtual" "$value" >> "$temp"
    mv -f "$temp" "$CHECKSUMS"
}

install_file() {
    source=$1
    virtual=$2
    mode=$3
    target="$ROOT$virtual"
    record_target "$virtual"
    mkdir -p "$(dirname -- "$target")"
    temp="$target.tmp.$$"
    cp "$source" "$temp"
    chmod "$mode" "$temp"
    mv -f "$temp" "$target"
    record_checksum "$virtual"
}

install_generated_config() {
    virtual=/etc/default/nvidia-plymouth-race-fix
    target="$ROOT$virtual"
    record_target "$virtual"
    mkdir -p "$(dirname -- "$target")"
    temp="$target.tmp.$$"
    {
        printf '%s\n' '# Managed by nvidia-plymouth-race-fix.'
        printf 'TIMEOUT=%s\n' "$TIMEOUT_VALUE"
        printf 'MIN_DURATION=%s\n' "$MIN_DURATION_VALUE"
        printf 'FORCE_LOAD=%s\n' "$FORCE_LOAD"
    } > "$temp"
    chmod 0644 "$temp"
    mv -f "$temp" "$target"
    record_checksum "$virtual"
}

install_generated_dracut_config() {
    virtual=/etc/dracut.conf.d/90-nvidia-plymouth-race-fix.conf
    target="$ROOT$virtual"
    record_target "$virtual"
    mkdir -p "$(dirname -- "$target")"
    temp="$target.tmp.$$"
    readlink_path=$(command -v readlink || printf '%s' /usr/bin/readlink)
    sleep_path=$(command -v sleep || printf '%s' /usr/bin/sleep)
    udevadm_path=$(command -v udevadm || printf '%s' /usr/bin/udevadm)
    {
        printf '%s\n' '# Managed by nvidia-plymouth-race-fix.'
        if [ "$FORCE_LOAD" -eq 1 ]; then
            printf '%s\n' 'force_drivers+=" nvidia nvidia_modeset nvidia_drm "'
        else
            printf '%s\n' 'add_drivers+=" nvidia nvidia_modeset nvidia_drm "'
        fi
        printf 'install_items+=" /etc/default/nvidia-plymouth-race-fix /etc/systemd/system/plymouth-start.service.d/10-wait-for-nvidia-drm.conf /usr/local/libexec/plymouth-wait-for-nvidia-drm %s %s %s "\n' "$readlink_path" "$sleep_path" "$udevadm_path"
    } > "$temp"
    chmod 0644 "$temp"
    mv -f "$temp" "$target"
    record_checksum "$virtual"
}

install_symlink() {
    link_virtual=$1
    link_target=$2
    link="$ROOT$link_virtual"
    record_target "$link_virtual"
    mkdir -p "$(dirname -- "$link")"
    rm -f "$link"
    ln -s "$link_target" "$link"
    record_checksum "$link_virtual"
}

install_generated_config
install_file "$PROJECT_DIR/src/plymouth-wait-for-nvidia-drm" /usr/local/libexec/plymouth-wait-for-nvidia-drm 0755
install_file "$PROJECT_DIR/src/plymouth-minimum-duration" /usr/local/libexec/plymouth-minimum-duration 0755
install_file "$PROJECT_DIR/src/10-wait-for-nvidia-drm.conf" /etc/systemd/system/plymouth-start.service.d/10-wait-for-nvidia-drm.conf 0644
install_file "$PROJECT_DIR/src/plymouth-minimum-duration.service" /etc/systemd/system/plymouth-minimum-duration.service 0644
install_symlink /etc/systemd/system/multi-user.target.wants/plymouth-minimum-duration.service ../plymouth-minimum-duration.service

case "$GENERATOR" in
    dracut)
        install_generated_dracut_config
        ;;
    initramfs-tools)
        install_file "$PROJECT_DIR/src/initramfs-tools-hook" /etc/initramfs-tools/hooks/nvidia-plymouth-race-fix 0755
        install_file "$PROJECT_DIR/src/initramfs-tools-init-top" /etc/initramfs-tools/scripts/init-top/00-nvidia-plymouth-wait 0755
        ;;
esac

if [ -z "$ROOT" ]; then
    systemctl daemon-reload
fi

if [ "$SKIP_REBUILD" != 1 ] && [ -z "$ROOT" ]; then
    case "$GENERATOR" in
        dracut)
            if [ "$ALL_KERNELS" -eq 1 ]; then
                dracut --regenerate-all --force
            else
                kernel=$(uname -r)
                image=$(current_initramfs)
                if [ -n "$image" ]; then
                    dracut --force "$image" "$kernel"
                else
                    dracut --force
                fi
            fi
            image=$(current_initramfs)
            if [ -n "$image" ] && command_exists lsinitrd; then
                [ -n "$(lsinitrd -f /usr/local/libexec/plymouth-wait-for-nvidia-drm "$image" 2>/dev/null || true)" ] || die "rebuilt initramfs is missing the wait helper"
                [ -n "$(lsinitrd -f /etc/systemd/system/plymouth-start.service.d/10-wait-for-nvidia-drm.conf "$image" 2>/dev/null || true)" ] || die "rebuilt initramfs is missing the Plymouth drop-in"
            fi
            ;;
        initramfs-tools)
            if [ "$ALL_KERNELS" -eq 1 ]; then
                update-initramfs -u -k all
            else
                update-initramfs -u -k "$(uname -r)"
            fi
            ;;
    esac
fi

printf '%s\n' 'Installation complete.'
printf '  state and backups: %s\n' "$STATE_VIRTUAL"
printf '%s\n' '  reboot required: yes'
