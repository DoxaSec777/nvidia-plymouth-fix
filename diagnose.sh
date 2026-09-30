#!/bin/sh
set -u

printf '%s\n' 'NVIDIA Plymouth race diagnostic'
printf 'date: '; date --iso-8601=seconds 2>/dev/null || date
printf 'kernel: '; uname -r
printf 'command line: '; cat /proc/cmdline

printf '\n%s\n' 'Plymouth:'
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    printf '  selected theme: '
    plymouth-set-default-theme 2>/dev/null || printf '%s\n' unknown
else
    printf '%s\n' '  plymouth-set-default-theme: unavailable'
fi
if command -v plymouthd >/dev/null 2>&1; then
    printf '  plymouthd: %s\n' "$(command -v plymouthd)"
else
    printf '%s\n' '  plymouthd: not installed'
fi

printf '\n%s\n' 'DRM cards:'
found=0
for card_path in /sys/class/drm/card[0-9] /sys/class/drm/card[0-9][0-9]; do
    [ -e "$card_path" ] || continue
    found=1
    card=${card_path##*/}
    driver=$(readlink -f "$card_path/device/driver" 2>/dev/null) || driver=unknown
    if [ -e "/dev/dri/$card" ]; then node=yes; else node=no; fi
    printf '  %s: driver=%s device-node=%s\n' "$card" "${driver##*/}" "$node"
done
[ "$found" -eq 1 ] || printf '%s\n' '  none found'

printf '\n%s\n' 'Initramfs generator:'
kernel=$(uname -r)
image="/boot/initrd.img-$kernel"
if command -v lsinitrd >/dev/null 2>&1 && [ -r "$image" ] && lsinitrd -m "$image" 2>/dev/null | grep -q 'dracut modules'; then
    printf '%s\n' '  dracut'
elif command -v update-initramfs >/dev/null 2>&1; then
    printf '%s\n' '  initramfs-tools'
elif command -v dracut >/dev/null 2>&1; then
    printf '%s\n' '  dracut (inferred from installed command)'
else
    printf '%s\n' '  unsupported or unknown'
fi

printf '\n%s\n' 'Fix status:'
if [ -r /etc/default/nvidia-plymouth-race-fix ]; then
    printf '%s\n' '  configuration:'
    while IFS= read -r line; do printf '    %s\n' "$line"; done < /etc/default/nvidia-plymouth-race-fix
else
    printf '%s\n' '  not installed'
fi
if [ -r /run/nvidia-plymouth-race-fix/nvidia-drm-wait-status ]; then
    printf '  current boot wait result: '
    cat /run/nvidia-plymouth-race-fix/nvidia-drm-wait-status
fi

printf '\n%s\n' 'Known failure signature in current journal:'
if command -v journalctl >/dev/null 2>&1; then
    journalctl -b --no-pager 2>/dev/null | grep -E 'could not open rendering device|No renderer plugins installed|already using text splash|open failed: No such file or directory' || printf '%s\n' '  signature not present (debug logging may be disabled)'
else
    printf '%s\n' '  journalctl unavailable'
fi

printf '\n%s\n' 'Note: EFI stub messages happen before Plymouth starts and are outside this fix.'
