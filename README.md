# Minimalistic Non-Interactive Debian Installer

**If you're looking for a regular Debian installer, go to [Debian.org](https://www.debian.org/).**
This repository addresses _advanced_ Debian users in need of a minimalistic
and/or easily customizable, non-interactive installer.

## Features

  * Non-interactive install of minimalistic Debian system in < 3 minutes
  * Supports current Debian stable (Bookworm) and unstable (Sid) on x86_64
  * Installs systemd-boot as minimal UEFI boot loader (BIOS/GRUB not supported)
  * Creates Btrfs subvolumes for separate snapshotting of root filesystem and
    home directories
  * Easily customizable (two shell scripts)
  * Usable from [minimal live system](https://github.com/carstenandrich/debian-minimal-live)

## Quick Start Instructions

Clone repository:

```sh
git clone https://github.com/carstenandrich/debian-minimal-installer.git
cd debian-minimal-installer
```

Install required dependencies:

```sh
sudo apt-get install bubblewrap btrfs-progs cdebootstrap dosfstools fdisk
```

Configure Debian suite, install device, and desired partition table in
[`install.sh`](./install.sh). Modify package selection in
[`install_chroot.sh`](./install_chroot.sh). Add/change configuration files in
[`include/`](./include/), most notably the
[keyboard configuration](./include/etc/default/keyboard), which is German QWERTZ
layout by default.

Run the install process:

```sh
sudo ./install.sh
```

In case the installation fails, fix the underlying issue, wipe partition and
filesystem signatures with `wipefs -a /dev/sdX? /dev/sdX`, and then re-run
`install.sh`.
