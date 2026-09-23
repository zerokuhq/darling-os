#!/usr/bin/env bash
#
# build-rootfs.sh - build the DarlingOS root filesystem.
#
# Creates an Ubuntu (noble) minimal base in TARGET_DIR, installs the kernel,
# GRUB and prebuilt packages, and configures the system to boot directly into
# the unified DarlingOS Darwin userland (zsh + Homebrew) with zero Linux fallback.
#
# Usage:   sudo ./scripts/build-rootfs.sh <target-dir>
#
# <target-dir> must be empty (e.g. a freshly formatted and mounted partition).
# Run as root.
#
# Host prerequisites: debootstrap, curl, ca-certificates, unzip, sha256sum
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: this script must run as root (try: sudo $0 ...)" >&2
  exit 1
fi

TARGET_DIR="${1:?usage: build-rootfs.sh <target-dir>}"

# --- pinned inputs ---------------------------------------------------------
SUITE="${SUITE:-noble}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"

if [ "$TARGET_ARCH" = "arm64" ]; then
  DEFAULT_MIRROR="http://ports.ubuntu.com/ubuntu-ports"
else
  DEFAULT_MIRROR="http://archive.ubuntu.com/ubuntu"
fi
MIRROR="${MIRROR:-$DEFAULT_MIRROR}"

# Prebuilt binary package release.
DARLING_TAG="${DARLING_TAG:-v0.1.20260608}"
DARLING_DEBS_URL="${DARLING_DEBS_URL:-https://github.com/darlinghq/darling/releases/download/v0.1.20260608/debs_20260608.zip}"
DARLING_DEBS_SHA256="${DARLING_DEBS_SHA256:-27469ef3932da2e91dd7fb34b70e3628a3e54b7af9fb5480051f44af35eca1fd}"

DARLING_DEBS=(
  darling-core
  darling-system
  darling-ffi
  darling-cli
  darling-cli-extra
  darling-cli-gui-common
  darling-cli-python2-common
  darling-jsc
  darling-jsc-webkit-common
  darling-python2
  darling-ruby
  darling-perl
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/build}"
DEBS_DIR="$WORK_DIR/packages"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

CHROOT_DIR=""
cleanup() {
  [ -z "$CHROOT_DIR" ] && return 0
  set +e
  umount "$CHROOT_DIR/dev/pts" 2>/dev/null
  umount "$CHROOT_DIR/dev" 2>/dev/null
  umount "$CHROOT_DIR/proc" 2>/dev/null
  umount "$CHROOT_DIR/sys" 2>/dev/null
  umount "$CHROOT_DIR/var/cache/packages" 2>/dev/null
}
trap cleanup EXIT

# --- 1. base system ---------------------------------------------------------
log "Creating $SUITE base in $TARGET_DIR (arch: $TARGET_ARCH)"
mkdir -p "$TARGET_DIR"
debootstrap --variant=minbase --arch="$TARGET_ARCH" "$SUITE" "$TARGET_DIR" "$MIRROR"

# --- 2. chroot plumbing ------------------------------------------------------
log "Preparing chroot"
CHROOT_DIR="$TARGET_DIR"
cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"
mkdir -p "$CHROOT_DIR/dev" "$CHROOT_DIR/proc" "$CHROOT_DIR/sys" \
         "$CHROOT_DIR/var/cache/packages"
mount --bind /dev     "$CHROOT_DIR/dev"
mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
mount -t proc proc    "$CHROOT_DIR/proc"
mount -t sysfs sys    "$CHROOT_DIR/sys"

# Configure APT sources
if [ "$TARGET_ARCH" = "arm64" ]; then
  cat > "$CHROOT_DIR/etc/apt/sources.list" <<EOF
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports $SUITE main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports $SUITE-updates main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports $SUITE-security main restricted universe multiverse
deb [arch=amd64] http://archive.ubuntu.com/ubuntu $SUITE main restricted universe multiverse
deb [arch=amd64] http://archive.ubuntu.com/ubuntu $SUITE-updates main restricted universe multiverse
deb [arch=amd64] http://security.ubuntu.com/ubuntu $SUITE-security main restricted universe multiverse
EOF
else
  cat > "$CHROOT_DIR/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main restricted universe multiverse
deb $MIRROR $SUITE-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $SUITE-security main restricted universe multiverse
EOF
fi

r() { chroot "$CHROOT_DIR" "$@"; }

# --- 3. system packages -------------------------------------------------------
log "Installing system packages (kernel, bootloader, networking, runtime dependencies)"
if [ "$TARGET_ARCH" = "arm64" ]; then
  BOOTLOADER_PKG="grub-efi-arm64 grub-efi-arm64-bin"
else
  BOOTLOADER_PKG="grub-efi-amd64 grub-pc-bin"
fi

r /bin/sh -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
  apt-get install -y --no-install-recommends \
    systemd systemd-sysv \
    systemd-resolved systemd-timesyncd \
    initramfs-tools \
    linux-image-generic \
    $BOOTLOADER_PKG \
    ca-certificates \
    curl nano kbd git \
    openssh-server \
    libfuse2t64 xdg-user-dirs
"

if [ "$TARGET_ARCH" = "arm64" ]; then
  r /bin/sh -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends qemu-user-static binfmt-support
    dpkg --add-architecture amd64
    apt-get update
    apt-get install -y --no-install-recommends libc6:amd64
  '
else
  r /bin/sh -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    dpkg --add-architecture i386
    apt-get update
    apt-get install -y --no-install-recommends libc6-i386
  '
fi

# --- 4. system runtime & userland ---------------------------------------------
mkdir -p "$WORK_DIR" "$DEBS_DIR"
if [ "${BUILD_DARLING_FROM_SOURCE:-0}" = "1" ]; then
  log "Compiling Darling from source (BUILD_DARLING_FROM_SOURCE=1)"
  OUTPUT_DEBS_DIR="$DEBS_DIR" "$SCRIPT_DIR/build-darling-source.sh"
elif [ -n "$(find "$DEBS_DIR" -name "*.deb" 2>/dev/null | head -n 1)" ]; then
  log "Using locally provided Darling packages in $DEBS_DIR"
else
  log "Downloading system packages $DARLING_TAG"
  if [ ! -f "$WORK_DIR/packages.zip" ]; then
    curl -fL --retry 3 -o "$WORK_DIR/packages.zip" "$DARLING_DEBS_URL"
  fi
  echo "$DARLING_DEBS_SHA256  $WORK_DIR/packages.zip" | sha256sum -c -
  unzip -q -o "$WORK_DIR/packages.zip" -d "$DEBS_DIR"
fi

DEBS_SUBDIR="$(find "$DEBS_DIR" -type f -name "*.deb" -exec dirname {} \; | sort -u | head -n 1)"
[ -n "$DEBS_SUBDIR" ] || { echo "error: no packages found inside $DEBS_DIR" >&2; exit 1; }
mount --bind "$DEBS_SUBDIR" "$CHROOT_DIR/var/cache/packages"

log "Installing Darwin userland package set"
deb_args=""
for p in "${DARLING_DEBS[@]}"; do
  deb_args="$deb_args /var/cache/packages/${p}_*.deb"
done
if [ "$TARGET_ARCH" = "arm64" ]; then
  r /bin/sh -c "set -e; export DEBIAN_FRONTEND=noninteractive; dpkg -i --force-architecture $deb_args || apt-get install -y -f"
else
  r /bin/sh -c "set -e; export DEBIAN_FRONTEND=noninteractive; apt-get install -y$deb_args"
fi

log "Verifying system runtime installation"
r /bin/sh -c '
  set -e
  test -x /usr/bin/darling
  test -x /usr/libexec/darling/bin/zsh
  test -x /usr/libexec/darling/bin/bash
  test -x /usr/libexec/darling/usr/bin/sw_vers
  test -f /usr/lib/binfmt.d/darling.conf
'

# --- 5. homebrew -------------------------------------------------------------
log "Bundling Homebrew into DarlingOS"
mkdir -p "$CHROOT_DIR/usr/libexec/darling/usr/local/Homebrew" \
         "$CHROOT_DIR/usr/libexec/darling/usr/local/bin" \
         "$CHROOT_DIR/usr/libexec/darling/usr/local/Cellar" \
         "$CHROOT_DIR/usr/libexec/darling/usr/local/Caskroom" \
         "$CHROOT_DIR/usr/libexec/darling/usr/local/var/homebrew" \
         "$CHROOT_DIR/usr/libexec/darling/usr/local/etc" \
         "$CHROOT_DIR/usr/libexec/darling/usr/local/share"

git clone --depth=1 https://github.com/Homebrew/brew.git \
  "$CHROOT_DIR/usr/libexec/darling/usr/local/Homebrew"

ln -sf ../Homebrew/bin/brew "$CHROOT_DIR/usr/libexec/darling/usr/local/bin/brew"

# Ensure user darwin (UID 1000) owns /usr/local for rootless package management
chown -R 1000:1000 "$CHROOT_DIR/usr/libexec/darling/usr/local"
test -x "$CHROOT_DIR/usr/libexec/darling/usr/local/Homebrew/bin/brew"
test -x "$CHROOT_DIR/usr/libexec/darling/usr/local/bin/brew"

# Compatibility symlink: support scripts expecting ARM64 /opt/homebrew prefix
mkdir -p "$CHROOT_DIR/usr/libexec/darling/opt"
ln -sf ../usr/local "$CHROOT_DIR/usr/libexec/darling/opt/homebrew"
test -x "$CHROOT_DIR/usr/libexec/darling/opt/homebrew/bin/brew"

# --- 6. configuration & single-userland zero-escape lockdown -----------------
log "Configuring DarlingOS single userland and zero-escape lockdown"

printf 'darlingos\n' > "$CHROOT_DIR/etc/hostname"

cat > "$CHROOT_DIR/etc/hosts" <<'EOF'
127.0.0.1	localhost
127.0.1.1	darlingos

::1		ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
EOF

# Kernel tunables required by Darwin userland emulation.
cat > "$CHROOT_DIR/etc/sysctl.d/60-system.conf" <<'EOF'
# Darwin userland maps code segments at low virtual addresses.
vm.mmap_min_addr = 0

# Prefix isolation relies on unprivileged user + mount namespaces.
kernel.apparmor_restrict_unprivileged_userns = 0
EOF

# Restrict virtual terminals in systemd-logind to tty1 only.
mkdir -p "$CHROOT_DIR/etc/systemd/logind.conf.d"
cat > "$CHROOT_DIR/etc/systemd/logind.conf.d/10-single-vt.conf" <<'EOF'
[Login]
NAutoVTs=1
ReserveVT=1
EOF

# Disable Alt+Fn virtual terminal switching in console keymap.
mkdir -p "$CHROOT_DIR/etc/kbd"
cat > "$CHROOT_DIR/etc/kbd/disable-vt-switch.kmap" <<'EOF'
alt keycode 59 = VoidSymbol
alt keycode 60 = VoidSymbol
alt keycode 61 = VoidSymbol
alt keycode 62 = VoidSymbol
alt keycode 63 = VoidSymbol
alt keycode 64 = VoidSymbol
alt keycode 65 = VoidSymbol
alt keycode 66 = VoidSymbol
alt keycode 67 = VoidSymbol
alt keycode 68 = VoidSymbol
alt keycode 87 = VoidSymbol
alt keycode 88 = VoidSymbol
EOF

# Systemd service to apply keymap unbinding on boot.
cat > "$CHROOT_DIR/etc/systemd/system/disable-vt-switch.service" <<'EOF'
[Unit]
Description=Disable Console VT Switching Keys
DefaultDependencies=no
After=systemd-vconsole-setup.service
Before=getty.target

[Service]
Type=oneshot
ExecStart=/usr/bin/loadkeys /etc/kbd/disable-vt-switch.kmap
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

# tty1 autologin directly into DarlingOS session.
mkdir -p "$CHROOT_DIR/etc/systemd/system/getty@tty1.service.d"
cat > "$CHROOT_DIR/etc/systemd/system/getty@tty1.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin darwin --noclear --keep-baud 115200,38400,9600 tty1 vt100
Restart=always
RestartSec=1
EOF

# ttyS0 serial autologin directly into DarlingOS session.
mkdir -p "$CHROOT_DIR/etc/systemd/system/getty@ttyS0.service.d"
cat > "$CHROOT_DIR/etc/systemd/system/getty@ttyS0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin darwin --noclear --keep-baud 115200,38400,9600 ttyS0 vt100
Restart=always
RestartSec=1
EOF

cat > "$CHROOT_DIR/etc/issue" <<'EOF'
DarlingOS (amd64)
EOF

# Single-userland session wrapper: trapped infinite loop running zsh in DarlingOS.
# DPREFIX is set to ~/.system to avoid any folder named .darling.
# Never exits or drops to a Linux shell prompt under any condition.
cat > "$CHROOT_DIR/usr/local/bin/system-shell" <<'EOF'
#!/bin/sh
trap '' INT QUIT TSTP HUP
export SHELL=/bin/zsh
export TERM="${TERM:-xterm-256color}"
export DPREFIX="$HOME/.system"

while true; do
  clear 2>/dev/null || true
  echo "=================================================="
  echo "                 Starting DarlingOS               "
  echo "=================================================="
  /usr/bin/darling shell /bin/zsh -l
  /usr/bin/darling shutdown 2>/dev/null || true
  echo ""
  echo "Session ended. Restarting DarlingOS..."
  sleep 1
done
EOF
chmod 0755 "$CHROOT_DIR/usr/local/bin/system-shell"

# Users and permissions lockdown:
# 1. Disable root account completely (locked password, nologin shell).
# 2. Create user 'darwin' with locked password and system-shell wrapper.
# 3. Strip sudo access (darwin is not in sudo or wheel).
# 4. Restrict host shells (/bin/bash, /bin/dash, etc.) to 0700 root:root
#    so user 'darwin' cannot execute host Linux binaries via /Volumes/SystemRoot.
r /bin/sh -c '
  set -e
  useradd -m -u 1000 -s /usr/local/bin/system-shell darwin
  passwd -l root
  passwd -l darwin
  usermod -s /usr/sbin/nologin root

  # Remove sudo rights completely
  rm -f /etc/sudoers.d/*
  sed -i "/^%sudo/d" /etc/sudoers 2>/dev/null || true
  sed -i "/^%admin/d" /etc/sudoers 2>/dev/null || true

  # Restrict host Linux shells from being executed by non-root users
  chmod 0700 /bin/bash /bin/dash /bin/sh /usr/bin/bash /usr/bin/dash /usr/bin/sh 2>/dev/null || true

  # Enable services
  systemctl enable systemd-networkd.service systemd-resolved.service systemd-timesyncd.service ssh.service
  systemctl enable getty@tty1.service getty@ttyS0.service disable-vt-switch.service
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

  # Mask secondary gettys and dynamic VTs to block VT switching
  systemctl mask getty@tty2.service getty@tty3.service getty@tty4.service \
                 getty@tty5.service getty@tty6.service autovt@.service

  # Mask rescue and emergency targets so errors never drop into an emergency root shell
  systemctl mask rescue.service rescue.target emergency.service emergency.target
'

# Provision default zsh configuration for user darwin.
cat > "$CHROOT_DIR/home/darwin/.zprofile" <<'EOF'
# DarlingOS .zprofile
export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_AUTO_UPDATE=1
eval "$(/usr/local/bin/brew shellenv 2>/dev/null || true)"

# Single unified userland: unmount host root leak
umount /Volumes/SystemRoot 2>/dev/null || true
EOF

cat > "$CHROOT_DIR/home/darwin/.zshrc" <<'EOF'
# DarlingOS .zshrc
export PROMPT='%m:%~ %n%# '
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_AUTO_UPDATE=1
EOF
chown -R 1000:1000 "$CHROOT_DIR/home/darwin"

# SSH lockdown: only allow user darwin (which launches system-shell); block root.
mkdir -p "$CHROOT_DIR/etc/ssh/sshd_config.d"
cat > "$CHROOT_DIR/etc/ssh/sshd_config.d/system.conf" <<'EOF'
PermitRootLogin no
AllowUsers darwin
X11Forwarding no
EOF

# DHCP for ethernet interfaces.
mkdir -p "$CHROOT_DIR/etc/systemd/network"
cat > "$CHROOT_DIR/etc/systemd/network/10-dhcp.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

# GRUB defaults.
cat > "$CHROOT_DIR/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR="DarlingOS"
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200 quiet splash"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=true
EOF

log "Rootfs ready: $TARGET_DIR"
