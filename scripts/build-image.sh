#!/usr/bin/env bash
#
# build-image.sh - assemble a bootable "DarlingOS" disk image.
#
# Creates a partitioned disk image (GPT: 2 MiB bios_grub + 512 MiB ESP + ext4 root),
# builds the rootfs into it (scripts/build-rootfs.sh), installs GRUB for both
# legacy BIOS and UEFI boot, and converts the result to compressed qcow2.
#
# Usage:   sudo ./scripts/build-image.sh
#
# Output (in build/dist):
#   darlingos-amd64.qcow2.zst
#   darlingos-amd64.qcow2.zst.sha256
#   IMAGE-INFO.txt
#
# Host prerequisites: debootstrap, qemu-utils, parted, dosfstools, e2fsprogs,
#                     zstd, curl, ca-certificates, unzip
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: this script must run as root (try: sudo $0 ...)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DIST_DIR="${DIST_DIR:-$BUILD_DIR/dist}"
IMG="$BUILD_DIR/disk.raw"
MNT="$BUILD_DIR/mnt"

IMG_SIZE="${IMG_SIZE:-8G}"
ESP_SIZE_MIB="${ESP_SIZE_MIB:-512}"
IMAGE_NAME="darlingos-amd64"

DARLING_TAG="${DARLING_TAG:-v0.1.20260608}"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

for tool in qemu-img parted mkfs.fat mkfs.ext4 blkid zstd debootstrap curl unzip; do
  command -v "$tool" >/dev/null || { echo "error: missing host tool: $tool" >&2; exit 1; }
done

LOOP=""
cleanup() {
  set +e
  if [ -d "$MNT" ]; then
    umount "$MNT/dev/pts" 2>/dev/null
    umount "$MNT/dev"     2>/dev/null
    umount "$MNT/proc"    2>/dev/null
    umount "$MNT/sys"     2>/dev/null
    umount -R "$MNT"      2>/dev/null
  fi
  if [ -n "$LOOP" ]; then
    losetup -d "$LOOP" 2>/dev/null
  fi
  rm -f "$IMG"
}
trap cleanup EXIT

log "Creating raw image ($IMG_SIZE)"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
rm -f "$IMG"
qemu-img create -f raw "$IMG" "$IMG_SIZE"

log "Partitioning GPT (bios_grub + ESP ${ESP_SIZE_MIB} MiB + ext4 root)"
parted -s "$IMG" mklabel gpt
# 1. BIOS boot partition for GPT (required for grub-install --target=i386-pc on GPT)
parted -s "$IMG" mkpart bios 1MiB 3MiB
parted -s "$IMG" set 1 bios_grub on
# 2. EFI System Partition
parted -s "$IMG" mkpart ESP fat32 3MiB "$((ESP_SIZE_MIB + 3))MiB"
parted -s "$IMG" set 2 esp on
# 3. Root partition
parted -s "$IMG" mkpart root ext4 "$((ESP_SIZE_MIB + 3))MiB" 100%

log "Attaching loop device"
LOOP="$(losetup -P --show "$IMG")"
log "Loop device: $LOOP"
partprobe "$LOOP"
udevadm settle 2>/dev/null || sleep 2

log "Formatting partitions"
mkfs.fat -F 32 -n DARLING_ESP "${LOOP}p2"
mkfs.ext4 -F -L DARLINGOS "${LOOP}p3"

log "Mounting filesystems"
mkdir -p "$MNT"
mount "${LOOP}p3" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "${LOOP}p2" "$MNT/boot/efi"

log "Building DarlingOS rootfs"
"$SCRIPT_DIR/build-rootfs.sh" "$MNT"

log "Writing /etc/fstab"
ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p3")"
ESP_UUID="$(blkid -s UUID -o value "${LOOP}p2")"
cat > "$MNT/etc/fstab" <<EOF
# <file system> <mount point> <type>  <options>          <dump> <pass>
UUID=$ROOT_UUID  /            ext4    errors=remount-ro  0 1
UUID=$ESP_UUID   /boot/efi    vfat   umask=0077          0 1
EOF

log "Binding chroot filesystems for GRUB installation"
mount --bind /dev     "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc    "$MNT/proc"
mount -t sysfs sys    "$MNT/sys"

log "Installing GRUB (BIOS + UEFI)"
chroot "$MNT" /usr/sbin/grub-install --target=i386-pc --recheck "$LOOP"
chroot "$MNT" /usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=DarlingOS --removable --no-nvram --recheck
chroot "$MNT" /usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg

log "Unmounting chroot bind mounts"
umount "$MNT/dev/pts" 2>/dev/null || true
umount "$MNT/dev"     2>/dev/null || true
umount "$MNT/proc"    2>/dev/null || true
umount "$MNT/sys"     2>/dev/null || true

log "Finalizing filesystems"
KERNEL="$(basename "$(ls "$MNT"/boot/vmlinuz-* 2>/dev/null | head -n 1)")"
umount -R "$MNT"
losetup -d "$LOOP"
LOOP=""

QCOW2="$DIST_DIR/$IMAGE_NAME.qcow2"
log "Converting to qcow2"
qemu-img convert -f raw -O qcow2 "$IMG" "$QCOV2"
rm -f "$IMG"

( cd "$DIST_DIR" && sha256sum "$IMAGE_NAME.qcow2" > "$IMAGE_NAME.qcow2.sha256" )

log "Compressing to zstandard (.qcow2.zst)"
zstd -19 -T0 -q -f -o "$QCOV2.zst" "$QCOV2"
( cd "$DIST_DIR" && sha256sum "$IMAGE_NAME.qcow2.zst" > "$IMAGE_NAME.qcow2.zst.sha256" )

cat > "$DIST_DIR/IMAGE-INFO.txt" <<EOF
DarlingOS - Bootable Disk Image
===============================
Build date:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Base:        Ubuntu 24.04 LTS (noble minbase)
Kernel:      ${KERNEL:-unknown}
Darling:     ${DARLING_TAG}
Default Shell: /bin/zsh (login shell)
Bootloader:  GRUB (BIOS i386-pc + UEFI x86_64), GPT Dual Boot

Architecture & Security
-----------------------
- Boots directly into DarlingOS (Darwin userland with zsh).
- Zero Linux Escape: root account locked, zero sudo privileges,
  extra VTs and Alt+Fn switching masked, host shells locked down.
- SSH: enabled for user 'darwin' (connects directly into DarlingOS zsh).

Running with QEMU:
  # Linux (KVM enabled)
  qemu-system-x86_64 -enable-kvm -cpu host -m 4G -smp 4 \\
    -drive file=${IMAGE_NAME}.qcow2,format=qcow2,if=virtio \\
    -nographic -serial mon:stdio

  # macOS (UTM or QEMU TCG)
  qemu-system-x86_64 -m 4G -smp 4 \\
    -drive file=${IMAGE_NAME}.qcow2,format=qcow2,if=virtio \\
    -nographic -serial mon:stdio
EOF

log "Done - output in $DIST_DIR"
ls -lh "$DIST_DIR"
