#!/bin/bash
# Stage 1: wipe the target disk, partition (1G EFI + ext4 root), debootstrap a base system.
# Run as root. Nothing here is interactive.
#   DISK_MODEL  substring of the disk's model as shown by `lsblk -dno NAME,MODEL` (required)
#   SUITE       Ubuntu codename, default: this host's (noble, ...)
#   MIRROR      default: first URI in this host's ubuntu.sources
#   TARGET      mount point, default /mnt/target
set -euo pipefail
: "${DISK_MODEL:?set DISK_MODEL to a substring of the target disk model}"
SUITE=${SUITE:-$(. /etc/os-release; echo "$VERSION_CODENAME")}
MIRROR=${MIRROR:-$(grep -m1 -E '^URIs:' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null | awk '{print $2}')}
MIRROR=${MIRROR:-http://archive.ubuntu.com/ubuntu/}
TARGET=${TARGET:-/mnt/target}

M=$(lsblk -dno NAME,MODEL | awk -v m="$DISK_MODEL" 'index($0,m){print "/dev/"$1}')
[ "$(wc -w <<<"$M")" = 1 ] || { echo "DISK_MODEL '$DISK_MODEL' must match exactly one disk, got: ${M:-none}"; exit 1; }
D=$M; ROOTDEV=$(findmnt -no SOURCE / | sed -E 's/p?[0-9]+$//'); [ "$D" != "$ROOTDEV" ] || { echo "$D is the disk holding /"; exit 1; }
[ -n "$D" ] && [ -b "$D" ] || { echo "no block device matching model '$DISK_MODEL' (a plain file at /dev/sdX means the USB bridge dropped it)"; exit 1; }
grep -q "^$D" /proc/mounts && { echo "$D has mounted partitions; unmount first"; exit 1; }
echo "target disk: $D ($(lsblk -dno SIZE,MODEL $D))"

DEBIAN_FRONTEND=noninteractive apt-get install -yq debootstrap gdisk dosfstools >/dev/null
# zap twice: a stale backup GPT at the end of the disk makes the first zap exit non-zero
sgdisk --zap-all "$D" || sgdisk --zap-all "$D"
sgdisk -n1:0:+1G -t1:ef00 -c1:EFI -n2:0:0 -t2:8300 -c2:root "$D"
partprobe "$D"; sleep 2
P1=$(lsblk -lnpo NAME "$D" | sed -n 2p); P2=$(lsblk -lnpo NAME "$D" | sed -n 3p)
mkfs.vfat -F32 -n EFI "$P1"
mkfs.ext4 -F -L root "$P2"
mkdir -p "$TARGET"; mount "$P2" "$TARGET"; mkdir -p "$TARGET/boot/efi"; mount "$P1" "$TARGET/boot/efi"
debootstrap --arch=amd64 --components=main,restricted,universe,multiverse "$SUITE" "$TARGET" "$MIRROR"
echo "STAGE1_DONE: base $SUITE on $D, mounted at $TARGET"
