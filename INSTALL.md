# Installation and rollback details

## Before installation

Run:

```bash
./diagnose.sh
./install.sh --dry-run
```

Confirm that the machine uses systemd, Plymouth, NVIDIA DRM, and either dracut or initramfs-tools. Keep a bootable older kernel or recovery entry available whenever changing an initramfs.

## Installed files

Common files:

```text
/etc/default/nvidia-plymouth-race-fix
/etc/systemd/system/plymouth-start.service.d/10-wait-for-nvidia-drm.conf
/etc/systemd/system/plymouth-minimum-duration.service
/etc/systemd/system/multi-user.target.wants/plymouth-minimum-duration.service
/usr/local/libexec/plymouth-wait-for-nvidia-drm
/usr/local/libexec/plymouth-minimum-duration
/var/lib/nvidia-plymouth-race-fix/
```

Dracut adds:

```text
/etc/dracut.conf.d/90-nvidia-plymouth-race-fix.conf
```

initramfs-tools adds:

```text
/etc/initramfs-tools/hooks/nvidia-plymouth-race-fix
/etc/initramfs-tools/scripts/init-top/00-nvidia-plymouth-wait
```

## Backups

Before replacing an existing path, the installer copies it below:

```text
/var/lib/nvidia-plymouth-race-fix/backups/TIMESTAMP/
```

The state directory contains:

- `installed-files.tsv`: remove-versus-restore decisions and backup paths.
- `installed-checksums.tsv`: hashes or symlink targets written by the installer.
- `metadata`: selected generator, kernel, scope, and force-load setting.

Uninstall checks the recorded checksum before removing a managed target. It stops on local modifications unless `--force` is supplied.

## Initramfs rebuild

The default rebuilds the running kernel only:

- dracut: `dracut --force <detected-current-image> $(uname -r)`
- initramfs-tools: `update-initramfs -u -k $(uname -r)`

Use `--all-kernels` to request a complete installation rebuild. The optional `--force-load` flag switches from module inclusion to early forced loading; it should be used only when the normal boot policy does not initialize NVIDIA DRM in the initramfs.

## Rollback

Preview:

```bash
sudo ./uninstall.sh --dry-run
```

Apply:

```bash
sudo ./uninstall.sh
sudo reboot
```

Uninstall uses the recorded generator and rebuilds all of its initramfs images to remove stale embedded copies. If it reports a modified managed file, review that file first; `sudo ./uninstall.sh --force` explicitly permits discarding the modification.

If the normal system cannot boot, select an older or recovery kernel, mount the root filesystem, remove the installed unit drop-in and generator integration, and rebuild the affected initramfs from the recovery environment.

## Test-only environment variables

The automated tests use an isolated root and skip privileged host operations:

```text
NPRF_ROOT
NPRF_ALLOW_NON_ROOT
NPRF_SKIP_REBUILD
```

These variables are intended for repository tests and packaging validation, not normal installation.
