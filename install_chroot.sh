#!/bin/sh -eux

# make apt-get not ask any questions
# https://manpages.debian.org/unstable/debconf-doc/debconf.7.en.html#Frontends
export DEBIAN_FRONTEND=noninteractive

# fetch repository index
apt-get update

# setup C locale as default
apt-get --assume-yes install locales
update-locale LANG=C.UTF-8

# install subset of important packages plus some personal favorites
# FIXME: as of systemd package version 251.2-3, systemd-boot was split off into separate packaged, see:
#        https://salsa.debian.org/systemd-team/systemd/-/blob/debian/251.2-3/debian/changelog
#        the systemd-boot package does not exist on current Debian stable (Bullseye) or prior versions
apt-get --assume-yes --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install \
	bsdmainutils cpio dbus dmidecode init iproute2 iputils-ping \
	kmod mount nano netbase sensible-utils systemd systemd-boot systemd-sysv tzdata udev \
	vim-common vim-tiny

# install remaining packages
apt-get --assume-yes --no-install-recommends -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install \
	busybox console-setup keyboard-configuration linux-image-amd64 \
	\
	bash-completion file htop less man-db manpages psmisc screen sudo \
	pciutils usbutils \
	\
	ethtool iputils-arping iputils-tracepath netcat-openbsd openssh-client \
	rsync tcpdump \
	\
	btrfs-progs dosfstools e2fsprogs fdisk \
	\
	openssh-server

# use local keymap in initramfs (busybox)
sed -i 's/^KEYMAP=n/KEYMAP=y/' /etc/initramfs-tools/initramfs.conf
dpkg-reconfigure initramfs-tools

# install and configure boot loader (systemd-boot)
bootctl --esp-path=/boot/efi install
cat >/boot/efi/loader/loader.conf <<-EOF
	default $(cat /etc/machine-id)-*
	timeout 5
EOF

# use systemd services
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service
systemctl enable systemd-timesyncd.service

# use systemd-resolved's resolv.conf instead of the one generated by debootstrap
ln -fs /run/systemd/resolve/resolv.conf /etc/resolv.conf

# enable peristent systemd journal (disable copy-on-write for journal files)
mkdir -p /var/log/journal
chattr +C /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal

# set root password "root" (generate via `openssl passwd -1 -salt ""`)
usermod --password '$1$$oCLuEVgI1iAqOA8pwkzAg1' root
