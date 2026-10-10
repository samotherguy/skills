#!/bin/bash
# Stage 2: configure the debootstrapped system in a chroot so it boots on another UEFI machine
# and is reachable by SSH on first boot. Run as root after stage1.sh. Re-runnable.
#   DISK_MODEL     substring of the target disk model (required)
#   NEW_HOSTNAME   hostname for the server (required)
#   PASS_FILE      file holding the user's password, one line (required)
#   NEW_USER       login user, default: $SUDO_USER
#   AUTH_KEYS      authorized_keys to copy, default: /home/$NEW_USER/.ssh/authorized_keys
#   NVIDIA_BRANCH  e.g. 580; default: detected from this host's nvidia-driver-NNN; "none" to skip
#   WITH_DOCKER    1/0, default: 1 if this host has docker-ce
#   WITH_TAILSCALE 1/0, default: 1 if this host has tailscale
#   EXTRA_CMDLINE  extra kernel args, e.g. "usb-storage.quirks=0bda:9210:u" if it will boot from a flaky USB bridge
#   TARGET         mount point, default /mnt/target
set -euo pipefail
: "${DISK_MODEL:?}"; : "${NEW_HOSTNAME:?}"; : "${PASS_FILE:?}"
NEW_USER=${NEW_USER:-${SUDO_USER:?set NEW_USER}}
AUTH_KEYS=${AUTH_KEYS:-}   # default: this host's ~/.ssh/id_*.pub merged with its authorized_keys
NVIDIA_BRANCH=${NVIDIA_BRANCH:-$(dpkg -l 2>/dev/null | awk '/^ii +nvidia-driver-[0-9]+(-open)? /{sub("nvidia-driver-","",$2); print $2; exit}')}   # 580 or 580-open
WITH_DOCKER=${WITH_DOCKER:-$(dpkg -s docker-ce >/dev/null 2>&1 && echo 1 || echo 0)}
WITH_TAILSCALE=${WITH_TAILSCALE:-$(dpkg -s tailscale >/dev/null 2>&1 && echo 1 || echo 0)}
EXTRA_CMDLINE=${EXTRA_CMDLINE:-}
TARGET=${TARGET:-/mnt/target}
SUITE=$(. /etc/os-release; echo "$VERSION_CODENAME"); SUITE_VER=$(. /etc/os-release; echo "$VERSION_ID")
MIRROR=$(grep -m1 -E '^URIs:' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null | awk '{print $2}'); MIRROR=${MIRROR:-http://archive.ubuntu.com/ubuntu/}
TZ_NAME=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value)

M=$(lsblk -dno NAME,MODEL | awk -v m="$DISK_MODEL" 'index($0,m){print "/dev/"$1}')
[ "$(wc -w <<<"$M")" = 1 ] || { echo "DISK_MODEL '$DISK_MODEL' must match exactly one disk, got: ${M:-none}"; exit 1; }
D=$M; ROOTDEV=$(findmnt -no SOURCE / | sed -E 's/p?[0-9]+$//'); [ "$D" != "$ROOTDEV" ] || { echo "$D is the disk holding /"; exit 1; }
[ -n "$D" ] && [ -b "$D" ] || { echo "no block device matching '$DISK_MODEL'"; exit 1; }
P1=$(lsblk -lnpo NAME "$D" | sed -n 2p); P2=$(lsblk -lnpo NAME "$D" | sed -n 3p)
mountpoint -q "$TARGET" || mount "$P2" "$TARGET"
mountpoint -q "$TARGET/boot/efi" || mount "$P1" "$TARGET/boot/efi"
[ -x "$TARGET/usr/bin/apt-get" ] || { echo "no debootstrap root at $TARGET; run stage1.sh"; exit 1; }
for m in dev dev/pts proc sys; do mountpoint -q "$TARGET/$m" || mount --bind "/$m" "$TARGET/$m"; done
# private /run so netplan/systemctl inside the chroot cannot write into the host's /run; only the host resolver is shared in
mountpoint -q "$TARGET/run" || mount -t tmpfs tmpfs "$TARGET/run"
install -d "$TARGET/run/systemd/resolve"; mountpoint -q "$TARGET/run/systemd/resolve" || mount --bind /run/systemd/resolve "$TARGET/run/systemd/resolve"
install -d "$TARGET/etc/initramfs-tools/conf.d"; echo RESUME=none > "$TARGET/etc/initramfs-tools/conf.d/resume"   # else initramfs may wait on the HOST's swap UUID

printf 'UUID=%s / ext4 defaults 0 1\nUUID=%s /boot/efi vfat umask=0077 0 1\n' \
  "$(blkid -s UUID -o value "$P2")" "$(blkid -s UUID -o value "$P1")" > "$TARGET/etc/fstab"

# seed files from this host
SEED="$TARGET/root/seed"; install -d -m 700 "$SEED"
[ -f /etc/ssh/sshd_config ] && cp /etc/ssh/sshd_config "$SEED/sshd_config" || true   # absent: the target keeps the package default
if [ -n "$AUTH_KEYS" ]; then cp "$AUTH_KEYS" "$SEED/authorized_keys"
else cat /home/"$NEW_USER"/.ssh/id_*.pub /home/"$NEW_USER"/.ssh/authorized_keys 2>/dev/null | sort -u > "$SEED/authorized_keys"; fi
[ -s "$SEED/authorized_keys" ] || { echo "no public keys found for $NEW_USER; set AUTH_KEYS"; exit 1; }
printf '%s:%s\n' "$NEW_USER" "$(tr -d '\r\n' < "$PASS_FILE")" > "$SEED/chpasswd"; chmod 600 "$SEED/chpasswd"
install -d "$TARGET/etc/apt/keyrings" "$TARGET/usr/share/keyrings"
if [ "$WITH_DOCKER" = 1 ]; then
  cp /etc/apt/keyrings/docker.asc "$TARGET/etc/apt/keyrings/"; cp /etc/apt/sources.list.d/docker.list "$TARGET/etc/apt/sources.list.d/"
  if [ -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]; then
    cp /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg "$TARGET/usr/share/keyrings/"
    cp /etc/apt/sources.list.d/nvidia-container-toolkit.list "$TARGET/etc/apt/sources.list.d/"
  fi
fi
if [ "$WITH_TAILSCALE" = 1 ]; then
  cp /usr/share/keyrings/tailscale-archive-keyring.gpg "$TARGET/usr/share/keyrings/"; cp /etc/apt/sources.list.d/tailscale.list "$TARGET/etc/apt/sources.list.d/"
fi

# the chroot script: variables are expanded into the first block, the rest is literal
{
  printf 'set -euo pipefail\nexport DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8\n'
  printf 'H=%q U=%q SUITE=%q SUITE_VER=%q MIRROR=%q TZ_NAME=%q NV=%q WITH_DOCKER=%q WITH_TAILSCALE=%q EXTRA_CMDLINE=%q\n' \
    "$NEW_HOSTNAME" "$NEW_USER" "$SUITE" "$SUITE_VER" "$MIRROR" "$TZ_NAME" "${NVIDIA_BRANCH:-none}" "$WITH_DOCKER" "$WITH_TAILSCALE" "$EXTRA_CMDLINE"
  cat <<'INNER'
echo "$H" > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' "$H" > /etc/hosts
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/ubuntu.sources <<SRC
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d   # no service starts inside the chroot
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf                           # resolves now via the bind-mounted host resolver, and on the target
apt-get update -q
apt-get install -yq locales tzdata
locale-gen en_US.UTF-8 >/dev/null; update-locale LANG=en_US.UTF-8
ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime; echo "$TZ_NAME" > /etc/timezone; dpkg-reconfigure -f noninteractive tzdata
# ubuntu-minimal + ubuntu-standard, NOT ubuntu-server: that pulls cloud-init, which fights the user/hostname/netplan set below
apt-get install -yq ubuntu-minimal ubuntu-standard "linux-generic-hwe-$SUITE_VER" "linux-headers-generic-hwe-$SUITE_VER" \
  grub-efi-amd64-signed shim-signed efibootmgr openssh-server sudo netplan.io systemd-resolved avahi-daemon curl ca-certificates gnupg
if [ "$NV" != none ]; then
  # prebuilt signed modules for this kernel flavour, installed together with the driver so it does not pull DKMS
  apt-get install -yq "linux-modules-nvidia-$NV-generic-hwe-$SUITE_VER" "nvidia-driver-$NV"
  ! dpkg -l | grep -q nvidia-dkms || echo "WARNING: nvidia-dkms got pulled in; works with Secure Boot off, otherwise fix before moving the disk"
fi
apt-get update -q
if [ "$WITH_DOCKER" = 1 ]; then
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  [ "$NV" = none ] || { apt-get install -yq nvidia-container-toolkit; nvidia-ctk runtime configure --runtime=docker; }
fi
[ "$WITH_TAILSCALE" = 1 ] && apt-get install -yq tailscale
id -u "$U" >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash "$U"
for g in sudo adm plugdev docker; do getent group "$g" >/dev/null && usermod -aG "$g" "$U"; done
chpasswd < /root/seed/chpasswd
echo "$U ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$U"; chmod 440 "/etc/sudoers.d/$U"
install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh"
install -m 600 -o "$U" -g "$U" /root/seed/authorized_keys "/home/$U/.ssh/authorized_keys"
[ -f /root/seed/sshd_config ] && cp /root/seed/sshd_config /etc/ssh/sshd_config
printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    all-en:\n      match:\n        name: "en*"\n      dhcp4: true\n      optional: true\n' > /etc/netplan/01-dhcp.yaml; chmod 600 /etc/netplan/01-dhcp.yaml
systemctl enable systemd-networkd systemd-resolved ssh avahi-daemon
[ "$WITH_DOCKER" = 1 ] && systemctl enable docker
[ "$WITH_TAILSCALE" = 1 ] && systemctl enable tailscaled
sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/; s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"$EXTRA_CMDLINE\"/" /etc/default/grub
sed -i '/GRUB_DISABLE_OS_PROBER/d' /etc/default/grub; echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub   # stock file has it commented out, so delete then add
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --removable --no-nvram
install -D /boot/efi/EFI/BOOT/grub.cfg /boot/efi/EFI/ubuntu/grub.cfg   # Ubuntu's signed grubx64.efi hardcodes /EFI/ubuntu as its prefix
update-grub
update-initramfs -u -k all
[ -e "/boot/vmlinuz-$(uname -r)" ] || rm -f "/boot/initrd.img-$(uname -r)"   # postinsts build an initrd for the HOST kernel; drop it only if that kernel is not installed here
find /boot -maxdepth 1 -xtype l -delete
truncate -s0 /etc/machine-id; rm -f /var/lib/dbus/machine-id
rm -f /usr/sbin/policy-rc.d; rm -rf /root/seed; apt-get clean
echo CHROOT_DONE
INNER
} > "$TARGET/root/stage2-chroot.sh"
chroot "$TARGET" /bin/bash /root/stage2-chroot.sh
rm -f "$TARGET/root/stage2-chroot.sh"

echo "--- verify"
chroot "$TARGET" systemctl is-enabled ssh systemd-networkd | tr '\n' ' '; echo
ls "$TARGET/boot/efi/EFI/BOOT/BOOTX64.EFI" "$TARGET/boot/efi/EFI/ubuntu/grub.cfg"
grep -q "$(blkid -s UUID -o value "$P2")" "$TARGET/boot/efi/EFI/ubuntu/grub.cfg" && echo "efi grub.cfg points at the root uuid"
ls -d "$TARGET"/lib/modules/*/kernel/nvidia-* 2>/dev/null || true
lsinitramfs "$TARGET"/boot/initrd.img-* | grep -qE 'usb-storage|nvme' && echo "initramfs has usb-storage/nvme"
for m in run/systemd/resolve run sys proc dev/pts dev boot/efi ""; do umount "$TARGET/$m"; done; rmdir "$TARGET"; sync
echo "STAGE2_DONE: $D is unmounted and ready to move"
