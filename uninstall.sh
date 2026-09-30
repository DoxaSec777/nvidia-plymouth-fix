#!/bin/sh
set -eu
umask 022

ROOT=${NPRF_ROOT:-}
ALLOW_NON_ROOT=${NPRF_ALLOW_NON_ROOT:-0}
SKIP_REBUILD=${NPRF_SKIP_REBUILD:-0}
DRY_RUN=0
GENERATOR=auto
FORCE=0

usage() {
    cat <<'EOF'
Usage: sudo ./uninstall.sh [options]

Options:
  --generator NAME   auto, dracut, or initramfs-tools (default: installation metadata)
  --force            Discard post-install modifications to managed files
  --dry-run          Show tracked files without changing them
  -h, --help         Show this help

Uninstall rebuilds every initramfs for the recorded generator so no future
kernel keeps stale copies of the helper or unit drop-in.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --generator)
            [ "$#" -ge 2 ] || die "--generator requires a value"
            GENERATOR=$2
            shift 2
            ;;
        --force)
            FORCE=1
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

case "$GENERATOR" in
    auto|dracut|initramfs-tools) ;;
    *) die "generator must be auto, dracut, or initramfs-tools" ;;
esac

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

STATE_VIRTUAL=/var/lib/nvidia-plymouth-race-fix
STATE_DIR="$ROOT$STATE_VIRTUAL"
MANIFEST="$STATE_DIR/installed-files.tsv"
CHECKSUMS="$STATE_DIR/installed-checksums.tsv"
METADATA="$STATE_DIR/metadata"
[ -r "$MANIFEST" ] || die "no installation state found at $STATE_VIRTUAL"

metadata_value() {
    key=$1
    [ -r "$METADATA" ] || return 1
    awk -F '=' -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$METADATA"
}

detect_generator() {
    recorded=$(metadata_value GENERATOR 2>/dev/null || true)
    if [ -n "$recorded" ]; then
        printf '%s\n' "$recorded"
    elif command_exists update-initramfs; then
        printf '%s\n' initramfs-tools
    elif command_exists dracut; then
        printf '%s\n' dracut
    else
        die "could not determine the installed initramfs generator"
    fi
}

recorded_generator=$(metadata_value GENERATOR 2>/dev/null || true)
if [ "$GENERATOR" = auto ]; then
    GENERATOR=$(detect_generator)
elif [ -n "$recorded_generator" ] && [ "$GENERATOR" != "$recorded_generator" ]; then
    die "installation metadata records generator $recorded_generator, not $GENERATOR"
fi

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

expected_checksum() {
    virtual=$1
    [ -r "$CHECKSUMS" ] || return 1
    awk -F '\t' -v path="$virtual" '$1 == path { print $2; exit }' "$CHECKSUMS"
}

CONFLICTS="$STATE_DIR/modified-files"
: > "$CONFLICTS"
TAB=$(printf '\t')
while IFS="$TAB" read -r virtual _backup; do
    [ -n "$virtual" ] || continue
    target="$ROOT$virtual"
    expected=$(expected_checksum "$virtual" 2>/dev/null || true)
    [ -n "$expected" ] || continue
    current=$(checksum_target "$target")
    if [ "$current" != missing ] && [ "$current" != "$expected" ]; then
        printf '%s\n' "$virtual" >> "$CONFLICTS"
    fi
done < "$MANIFEST"

if [ -s "$CONFLICTS" ] && [ "$FORCE" -ne 1 ]; then
    printf '%s\n' 'error: managed files were modified after installation:' >&2
    while IFS= read -r path; do printf '  %s\n' "$path" >&2; done < "$CONFLICTS"
    printf '%s\n' 'review them, then rerun with --force to discard those modifications' >&2
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'Uninstall plan (generator: %s; all kernels):\n' "$GENERATOR"
    awk -F '\t' '{ printf "  %s%s\n", $1, ($2 != "" ? " (restore backup)" : " (remove)") }' "$MANIFEST"
    if [ -s "$CONFLICTS" ]; then
        printf '%s\n' 'Modified managed files that --force would discard:'
        while IFS= read -r path; do printf '  %s\n' "$path"; done < "$CONFLICTS"
    fi
    printf '%s\n' 'Dry run: no files were changed.'
    exit 0
fi

if [ "$(id -u)" -ne 0 ] && [ "$ALLOW_NON_ROOT" != 1 ]; then
    die "run as root (for example: sudo ./uninstall.sh)"
fi

reversed="$STATE_DIR/installed-files.reversed.tsv"
awk '{ lines[NR]=$0 } END { for (i=NR; i>=1; i--) print lines[i] }' "$MANIFEST" > "$reversed"
while IFS="$TAB" read -r virtual backup; do
    [ -n "$virtual" ] || continue
    target="$ROOT$virtual"
    rm -f "$target"
    if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
        mkdir -p "$(dirname -- "$target")"
        cp -a "$backup" "$target"
    fi
done < "$reversed"

if [ -z "$ROOT" ]; then
    systemctl daemon-reload
fi

if [ "$SKIP_REBUILD" != 1 ] && [ -z "$ROOT" ]; then
    case "$GENERATOR" in
        dracut) dracut --regenerate-all --force ;;
        initramfs-tools) update-initramfs -u -k all ;;
    esac
fi

rm -rf "$STATE_DIR"
rmdir "$ROOT/etc/systemd/system/plymouth-start.service.d" 2>/dev/null || true
rmdir "$ROOT/etc/systemd/system/multi-user.target.wants" 2>/dev/null || true
rmdir "$ROOT/etc/dracut.conf.d" 2>/dev/null || true
rmdir "$ROOT/etc/initramfs-tools/hooks" 2>/dev/null || true
rmdir "$ROOT/etc/initramfs-tools/scripts/init-top" 2>/dev/null || true

printf '%s\n' 'Uninstall complete. Previous files were restored where backups existed.'
printf '%s\n' 'All initramfs images were rebuilt; a reboot is recommended.'
