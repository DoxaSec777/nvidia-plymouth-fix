# Contributing

Bug reports should include sanitized output from `./diagnose.sh`, the distribution and kernel version, the initramfs generator, NVIDIA driver version, selected Plymouth theme, and the exact Plymouth debug failure sequence.

Do not post private hostnames, usernames, serial numbers, full kernel command lines containing secrets, or complete journal archives without reviewing them first.

Before submitting changes:

```bash
python3 -m unittest -v tests.test_project
```

Keep the fix theme-agnostic, keep boot waits bounded, and preserve reversible installation.
