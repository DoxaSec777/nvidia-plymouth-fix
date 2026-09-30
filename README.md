# NVIDIA Plymouth Race Fix

A Theme-agnostic workaround for a Plymouth/NVIDIA DRM startup race that can make an otherwise valid graphical boot theme fall back to scrolling text.

The project does **not** install, select, or modify a Plymouth theme. It works with any correctly installed theme because it fixes the renderer timing underneath the theme.

## Symptom

This project targets a specific failure pattern:

1. Plymouth starts while NVIDIA DRM is still initializing.
2. A `/dev/dri/cardN` udev event arrives before the device node is usable.
3. Plymouth tries to open that card and receives `No such file or directory`.
4. Plymouth permanently selects its text/details renderer.
5. Later DRM events are ignored because Plymouth is already using text mode.

Typical debug lines include:

```text
open failed: No such file or directory
could not find suitable rendering plugin
No renderer plugins installed, creating non-graphical devices
ignoring since we're already using text splash for local console
```

If your logs do not show this sequence, diagnose the real cause before installing this workaround.

## What it changes

- Installs a small wait helper that finds the usable NVIDIA DRM card by driver name instead of assuming `card0` or `card1`.
- Adds an `ExecStartPre=` drop-in to `plymouth-start.service`.
- Includes the helper, configuration, and NVIDIA DRM modules in the initramfs.
- Optionally keeps the splash visible for a minimum number of seconds after graphics become usable.
- Leaves the selected Plymouth theme unchanged.
- Records every managed path, installed checksum, and selected generator for guarded rollback.

## Supported initramfs generators

| Generator | Status | Integration |
|---|---|---|
| systemd-based dracut | Supported and hardware-tested | systemd unit drop-in embedded in the initramfs |
| initramfs-tools | Supported, fixture-tested | init-top wait script plus initramfs hook |
| mkinitcpio | Not automated | See Limitations |

Required runtime components:

- Linux with systemd
- Plymouth
- Proprietary or open NVIDIA kernel modules (`nvidia_drm` module; sysfs DRM driver name `nvidia`)
- `udevadm`
- Either dracut or initramfs-tools

## Quick start

First inspect the machine:

```bash
./diagnose.sh
```

### Dry run

A Dry run does not require root and does not write files:

```bash
./install.sh --dry-run
```

Install with an 8-second DRM readiness timeout:

```bash
sudo ./install.sh --timeout 8
sudo reboot
```

Keep the graphical splash visible for at least five seconds after NVIDIA DRM becomes usable:

```bash
sudo ./install.sh --timeout 8 --min-duration 5
sudo reboot
```

The installer automatically detects dracut or initramfs-tools. Override only when detection is wrong:

```bash
sudo ./install.sh --generator dracut
sudo ./install.sh --generator initramfs-tools
```

Use `--all-kernels` if every installed initramfs must be rebuilt. The default rebuilds only the running kernel.

If the NVIDIA modules are present in the initramfs but are not loaded there by the existing boot policy, opt in to forced early loading:

```bash
sudo ./install.sh --force-load
```

Forced early module loading changes boot policy and can affect hibernation on some NVIDIA configurations. Use it only when the normal installation still times out.

## Configuration

The installer writes:

```text
/etc/default/nvidia-plymouth-race-fix
```

Example:

```text
TIMEOUT=8
MIN_DURATION=5
FORCE_LOAD=0
```

Re-run `install.sh` after changing options so the initramfs is rebuilt consistently.

## Verification

After reboot:

```bash
./diagnose.sh
cat /run/nvidia-plymouth-race-fix/nvidia-drm-wait-status
```

A successful wait normally reports a dynamic card name such as:

```text
ready:card1
```

The number is intentionally not hardcoded.

For deeper Plymouth debugging, temporarily add Plymouth's debug options according to your distribution documentation, reproduce one boot, and look for the failure signature shown above. Remove verbose debugging afterward because it can itself produce visible boot text.

## Uninstall

Preview rollback:

```bash
sudo ./uninstall.sh --dry-run
```

Restore backed-up files, remove managed files, and rebuild the initramfs:

```bash
sudo ./uninstall.sh
sudo reboot
```

Uninstall rebuilds all initramfs images for the recorded generator. If a managed file was edited after installation, uninstall stops instead of deleting the change. Review it and use `sudo ./uninstall.sh --force` only when that modification may be discarded.

Installation state and backups are stored under:

```text
/var/lib/nvidia-plymouth-race-fix/
```

## Safety model

- The selected theme and `/etc/plymouth/plymouthd.conf` are not modified.
- The wait has a bounded timeout and never blocks boot indefinitely.
- Failure to initialize NVIDIA falls back to Plymouth's normal behavior.
- Existing target files are backed up before replacement.
- The uninstaller restores pre-existing files when backups exist.
- Post-install modifications are detected by checksum and require explicit `--force` before removal.
- A dry run is available before installation and removal.

## EFI stub messages

EFI stub messages are printed before Plymouth starts. This project cannot hide firmware, bootloader, or EFI stub output. It only fixes the later Plymouth renderer race.

## Limitations

- This is not a general fix for missing `quiet splash`, broken theme assets, missing Plymouth plugins, Secure Boot module rejection, wrong display-manager handoff, or an NVIDIA driver that never loads.
- `mkinitcpio` integration is not automated because hook ordering differs between classic and systemd-based Arch initramfs configurations.
- The dracut backend requires a systemd-based dracut image and refuses installation when `plymouth-start.service` is absent from the current image.
- Multi-GPU systems are supported only when the graphical boot output is driven by a DRM card whose kernel driver resolves to `nvidia`.
- A very slow GPU initialization may require a larger `--timeout` value.
- initramfs-tools support is structurally tested but has not received the same live hardware coverage as dracut.
- The scripts target Linux environments with GNU core utilities or compatible BusyBox tools; they are `/bin/sh` scripts, not generic non-Linux POSIX packages.
- A brief firmware-to-kernel or simpledrm-to-NVIDIA mode switch can still cause a short black frame even when Plymouth works correctly.

## Troubleshooting

1. Confirm `quiet splash` is present in `/proc/cmdline`.
2. Confirm `nvidia_drm.modeset=1` or an equivalent driver default is active.
3. Run `./diagnose.sh`.
4. Confirm a current `/dev/dri/cardN` resolves to the `nvidia` driver.
5. Confirm the selected theme works when tested independently.
6. Verify that the rebuilt initramfs contains the helper and drop-in.
7. If Plymouth still falls back to text, collect a Plymouth debug log and open an issue with sanitized output.

## Development

Run the tests without root:

```bash
python3 -m unittest -v tests.test_project
```

The test suite uses temporary filesystem roots and does not rebuild the host initramfs.

See [INSTALL.md](INSTALL.md) for the file layout and rollback details. Background reading: [ArchWiki Plymouth](https://wiki.archlinux.org/title/Plymouth).

## License

MIT. See [LICENSE](LICENSE).
