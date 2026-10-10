---
name: building-ubuntu-server-disk
description: Use when asked to install Ubuntu Server onto a spare SSD from a running Ubuntu machine without an ISO, installer, VM or reboot, so the disk can be moved into another UEFI machine and reached by SSH on first boot - including when the target needs NVIDIA drivers, Docker with the nvidia runtime, or Tailscale, or when a disk built this way boots to a bare "grub>" prompt.
---

# Building an Ubuntu Server disk from a running host

## Overview

Build the whole system in place with `debootstrap` and a chroot, on a disk attached
to the host over USB or SATA, then move the disk. Two scripts do it end to end and
leave the disk unmounted. The procedure was verified on Ubuntu 24.04 hardware with an
RTX GPU: 30 minutes, boots in the second machine, SSH with the host's key, GPU visible
inside Docker. The scripts here are the generalized form of what ran; their added
guards and env-var defaults have been parse-checked and dry-run, not yet used for a
full build, so read stage2's verify output rather than trusting STAGE2_DONE.

## When to use

- A second machine (same or similar hardware) needs an OS and you only have the running desktop
- No installer interaction wanted: user, SSH keys, drivers, Docker, Tailscale all preset
- The ISO or VM route is blocked (no qemu, no spare USB stick, no monitor on the target)

Not for: encrypted or LVM layouts, non-UEFI targets, or a disk that will stay in the host.

## Run it

```bash
sudo DISK_MODEL='970 EVO' bash scripts/stage1.sh
sudo DISK_MODEL='970 EVO' NEW_HOSTNAME=server-2 PASS_FILE=./pass.txt bash scripts/stage2.sh
```

`DISK_MODEL` is a substring of `lsblk -dno NAME,MODEL`. stage2 mirrors the host by
default: same user, authorized_keys, sshd_config, mirror, timezone, NVIDIA branch,
Docker and Tailscale if present. Every default is an env var; see the script header.
Both scripts refuse to run if the disk is missing or still mounted, and stage2 is
re-runnable.

Before stage1, **wipe is destructive and the disk may not be blank**: mount it read-only
and look, then get explicit confirmation.

## What the scripts get right that a first attempt misses

| Pitfall | Symptom | Handled by |
|---|---|---|
| Ubuntu's signed `grubx64.efi` hardcodes `/EFI/ubuntu` as its prefix | `--removable` install boots to a bare `grub>` prompt | copying `EFI/BOOT/grub.cfg` to `EFI/ubuntu/grub.cfg` |
| `ubuntu-server` metapackage pulls cloud-init | first boot creates an `ubuntu` user, rewrites netplan and hostname | `ubuntu-minimal` + `ubuntu-standard` instead |
| `nvidia-driver-NNN` alone pulls DKMS | long compile in chroot, unsigned modules | installing `linux-modules-nvidia-NNN-generic-hwe-*` in the same call |
| stock `/etc/default/grub` has os-prober commented out | `grep -q` says it is set, `update-grub` adds the host's Windows and Ubuntu | delete the line, then append `=true` |
| postinsts call `update-initramfs` for `uname -r`, which is the host kernel | when the host kernel version differs from the one installed, a stray `initrd.img-<host kernel>` and dangling symlinks sit in target `/boot` | removed after the last initramfs rebuild, only if no matching `vmlinuz` exists |
| bind-mounting host `/run` | `netplan generate` writes into the host's `/run/systemd/network` | private tmpfs on `/run`, only the host resolver bound in |
| initramfs resume hook sees the host's swap | boot waits on a swap UUID that does not exist | `RESUME=none` |
| second NIC with no cable | `wait-online` delays boot | `optional: true` in netplan |
| the USB bridge drops the disk under write load | `Medium Error`, `uas_eh_abort_handler`, then `/dev/sdX` is gone and `dd` writes a plain **file** at that path | scripts test `[ -b ]`; see below |

## Flaky USB enclosures (Realtek RTL9210, id 0bda:9210, and friends)

Disable UAS and link power management at runtime, then re-plug the enclosure directly
into a rear motherboard port, never through a hub:

```bash
echo '0bda:9210:u' | sudo tee /sys/module/usb_storage/parameters/quirks
echo '0bda:9210:k' | sudo tee /sys/module/usbcore/parameters/quirks
```

If the target will boot *from* the enclosure, pass the same as `EXTRA_CMDLINE`.

## First boot on the target

Firmware has no NVRAM entry by design. Pick the disk in the boot menu once, then on the
server run `sudo grub-install && sudo update-grub` to register one. With a discrete GPU,
the firmware output is on the GPU's ports, not the motherboard's.

If it lands on `grub>` anyway:

```
search --file --set=root /boot/grub/grub.cfg
configfile /boot/grub/grub.cfg
```

Reach it as `ssh user@<hostname>.local` (avahi on the server, mDNS on the host).
No link light means power or cable, not the OS. Link light but nothing on the LAN
means firmware never booted the disk.

## Verify before unplugging

stage2 prints these; read them: `ssh` and `systemd-networkd` enabled, `EFI/BOOT/BOOTX64.EFI`
and `EFI/ubuntu/grub.cfg` present and pointing at the root UUID, NVIDIA modules under
`/lib/modules/<kernel>/kernel/`, `usb-storage` and `nvme` inside the initramfs.
