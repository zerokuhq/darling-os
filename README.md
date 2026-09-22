# DarlingOS

**DarlingOS** is a specialized, lightweight operating system that boots directly into [Darling](https://www.darlinghq.org) (Darwin userland with `zsh`) to serve as a dedicated, **TUI-only Darwin operating system environment**.

Built on a minimal Linux kernel and systemd foundation, DarlingOS is strictly hardened as an appliance: **users cannot escape, drop, or fallback to Linux under any circumstances**.

```
+-------------------------------------------------------------+
|                         DarlingOS                           |
|         (Darwin TUI Console - zsh login shell)              |
+-------------------------------------------------------------+
|        Darwin System Libraries, Frameworks & CLI Tools      |
+-------------------------------------------------------------+
|        Darling Container & Mach-O Execution Engine          |
+-------------------------------------------------------------+
|         Linux Kernel 6.8 & Minimal Appliance Base           |
+-------------------------------------------------------------+
```

---

## Key Features

- **Boots Straight into Darwin TUI**: Automatically logs in to the `darwin` console on `tty1` and `ttyS0` with `zsh` as the default interactive login shell.
- **Zero Linux Escape Guarantee**:
  - The Linux `root` account is permanently disabled (`passwd -l root` with `/usr/sbin/nologin`).
  - User `darwin` is unprivileged with **zero sudo permissions**.
  - Host Linux shells (`/bin/bash`, `/bin/dash`, `/bin/sh`) are restricted to `0700 root:root` so executing host binaries via `/Volumes/SystemRoot` is denied by the kernel.
  - Secondary virtual terminals (`tty2` through `tty6`) and dynamic VTs are permanently masked. Keyboard shortcuts (`Alt+F1`–`Alt+F12`) for console switching are neutralized.
  - The shell wrapper (`/usr/local/bin/system-shell`) traps all interrupt signals (`INT`, `QUIT`, `TSTP`, `HUP`) and runs in an infinite loop. Any session exit immediately restarts DarlingOS without yielding to a Linux shell.
  - Unified Darwin userland: the prefix is housed cleanly in `~/.system` (no `/darling` folder names) and `/Volumes/SystemRoot` is automatically unmounted to prevent host filesystem leakage.
  - Systemd emergency and rescue targets are masked so errors cannot drop into an emergency root shell.
- **Dual Bootloader Support**: GPT partitioned disk image with both legacy BIOS (`i386-pc` via `bios_grub`) and UEFI (`x86_64-efi` with removable fallback binary `BOOTX64.EFI`).
- **Remote SSH Access**: SSH is enabled and restricted strictly to user `darwin` (`PermitRootLogin no`), dropping directly into the DarlingOS `zsh` shell.
- **Automated CI/CD**: Prebuilt disk images are compiled, verified with headless QEMU boot tests, and published via GitHub Actions Artifacts and GitHub Releases.

---

## Quick Start: Running Prebuilt Images

### 1. Download
Download the latest compressed disk image (`darlingos-amd64.qcow2.zst`) from [GitHub Releases](https://github.com/zerokuhq/darling-os/releases) or GitHub Actions Artifacts.

Decompress the image:
```bash
zstd -d darlingos-amd64.qcow2.zst
```

### 2. Run with QEMU

#### On Linux (KVM Accelerated)
```bash
qemu-system-x86_64 -enable-kvm -cpu host -m 4G -smp 4 \
  -drive file=darlingos-amd64.qcow2,format=qcow2,if=virtio \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -nographic -serial mon:stdio
```

#### Without KVM (UTM or QEMU TCG Emulation)
```bash
qemu-system-x86_64 -m 4G -smp 4 \
  -drive file=darlingos-amd64.qcow2,format=qcow2,if=virtio \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -nographic -serial mon:stdio
```

> **Tip:** You can also import `darlingos-amd64.qcow2` directly into **UTM** or **Proxmox VE**.

### 3. Remote Access via SSH
If port forwarding is configured (e.g. `2222 -> 22`):
```bash
ssh -p 2222 darwin@localhost
```
Connecting via SSH drops directly into DarlingOS `zsh`.

---

## Darwin CLI Commands Inside DarlingOS

Inside DarlingOS, you have access to standard Darwin commands and utilities:

```zsh
sw_vers               # Displays system version and build number
uname -a              # Reports Darwin kernel identity
defaults read         # Defaults property system
plutil -p file.plist  # Property list tool
otool -L /bin/zsh     # Inspect Mach-O dependencies
codesign --display    # Verify code signatures
brew --version        # Bundled Homebrew package manager
python2               # Python runtime
ruby                  # Ruby runtime
perl                  # Perl runtime
```

---

## Bundled Homebrew Package Manager

DarlingOS includes **Homebrew** pre-bundled in `/usr/local` for command-line package management:

```zsh
brew --version        # Check Homebrew version
brew help             # Display Homebrew commands
brew install <pkg>    # Install command-line formulas
```

Homebrew is pre-configured with rootless permissions (`/usr/local` owned by user `darwin`) and optimized for DarlingOS with automated telemetry and auto-update delays disabled (`HOMEBREW_NO_ANALYTICS=1`, `HOMEBREW_NO_AUTO_UPDATE=1`).

---

## Building DarlingOS from Source

### Prerequisites (Ubuntu 24.04 LTS host)
```bash
sudo apt-get update
sudo apt-get install -y \
  debootstrap \
  qemu-utils \
  parted \
  dosfstools \
  e2fsprogs \
  zstd \
  curl \
  unzip \
  kpartx \
  ca-certificates \
  grub-pc-bin \
  grub-efi-amd64-bin
```

### Assemble the Disk Image
```bash
sudo ./scripts/build-image.sh
```

The output will be generated in `build/dist/`:
- `darlingos-amd64.qcow2.zst`: Compressed bootable disk image.
- `darlingos-amd64.qcow2.zst.sha256`: SHA-256 checksum.
- `IMAGE-INFO.txt`: Image metadata and run instructions.

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       └── build.yml          # GitHub Actions build & release workflow
├── scripts/
│   ├── build-rootfs.sh        # Builds locked root filesystem with Darling & zsh
│   └── build-image.sh         # Partitions GPT disk, installs GRUB & converts to qcow2
├── LICENSE                    # MIT License
├── README.md                  # Project documentation
└── .gitignore                 # Build artifacts ignore rules
```

---

## License

DarlingOS build scripts and configuration are licensed under the [MIT License](LICENSE).

Upstream components:
- [Darling](https://www.darlinghq.org): GPL v3 / LGPL / APSL
- Ubuntu Linux: GPL and open source licenses
