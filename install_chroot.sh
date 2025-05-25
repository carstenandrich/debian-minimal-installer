#!/bin/sh -eux

# /tmp is tmpfs created by bwrap, but bwrap uses 0755 mode
# TODO: use bwrap --perms 1777 --tmpfs /tmp once bwrap 0.5 is widely available
chmod 1777 /tmp

# make apt-get not ask any questions
# https://manpages.debian.org/unstable/debconf-doc/debconf.7.en.html#Frontends
export DEBIAN_FRONTEND=noninteractive

# fetch repository index
apt-get update

# setup C locale as default
apt-get --assume-yes --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install \
	locales
update-locale LANG=C.UTF-8

# installing systemd-resolved replaces /etc/resolv.conf with a symlink to
# /run/system/resolved/stub-resolv.conf. with service invocation inhibited in
# the chroot, systemd-resolved does not run and these files are missing,
# breaking DNS resolution. as a workaround, substitute these files with the
# contents of /etc/resolv.conf (expected to be a usable resolv.conf provided
# by the host).
mkdir -p /run/systemd/resolve
cat /etc/resolv.conf >/run/systemd/resolve/resolv.conf
cat /etc/resolv.conf >/run/systemd/resolve/stub-resolv.conf

# install all packages except kernel (avoids multiple initramfs rebuilds)
apt-get --assume-yes --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install \
	bsdmainutils cpio dbus dmidecode init initramfs-tools iproute2 \
	kmod login mount nano netbase sensible-utils \
	systemd systemd-boot systemd-resolved systemd-sysv systemd-timesyncd \
	tzdata udev vim-tiny zstd \
	\
	bash-completion busybox console-setup keyboard-configuration usb-modeswitch \
	htop less man-db manpages \
	btrfs-progs dosfstools fdisk \
	iputils-ping iputils-tracepath netcat-openbsd openssh-client openssh-server

# install cryptsetup-initramfs if required
if [ -s /etc/crypttab ] ; then
	apt-get --assume-yes --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install cryptsetup-initramfs
fi

# enable systemd services not enabled by default
if [ -f /usr/lib/systemd/system/systemd-boot-update.service ] ; then
	systemctl enable systemd-boot-update.service
fi
if [ -f /usr/lib/systemd/system/systemd-networkd.service ] ; then
	systemctl enable systemd-networkd.service
fi

# disable resuming (emits warning during initramfs generation and may cause
# boot delay when erroneously waiting for swap partition)
# https://manpages.debian.org/unstable/initramfs-tools-core/initramfs-tools.7.en.html#resume
if [ -d /etc/initramfs-tools/conf.d ] ; then
	echo "RESUME=none" >/etc/initramfs-tools/conf.d/resume
fi

# configure initramfs generation before installing kernel
# (use local keymap in initramfs)
sed -i 's/^KEYMAP=n/KEYMAP=y/' /etc/initramfs-tools/initramfs.conf

# install and configure systemd-boot before installing kernel
bootctl --esp-path=/boot/efi install
# bootctl does not create system token in VMs, so create directory explicitly
mkdir -p /boot/efi/$(cat /etc/machine-id)
cat >/boot/efi/loader/loader.conf <<-EOF
	default $(cat /etc/machine-id)-*
	timeout 5
EOF

# install kernel and memtest86+
# TODO: add memtest86+ once dependency on grub-common is removed (see Debian Bug #1087942)
# FIXME: automatic memtest86+ systemd-boot entry creation only on Trixie/Sid (see Debian Bug #1081704)
apt-get --assume-yes --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install \
	linux-image-amd64

# enable persistent systemd journal (implies `chattr +C /var/log/journal`)
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal

# permit local logins without password
# NOTE: sshd refuses login without password unless PermitEmptyPasswords is set:
#       https://manpages.debian.org/unstable/openssh-server/sshd_config.5.en.html#PermitEmptyPasswords
sed -i 's/^root:[^:]*:/root::/' /etc/shadow
