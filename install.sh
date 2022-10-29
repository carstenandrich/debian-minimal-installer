#!/bin/sh -eux

# apt install bubblewrap btrfs-progs cdebootstrap dosfstools fdisk

### vvv ADJUST THESE PARAMETERS vvv ###

# configure
DEBIAN_SUITE="sid"
HOSTNAME="debian"
HOSTNAME_FQDN=""
DEV="/dev/sdb"
# TODO: determine devices automatically
DEV_ESP="${DEV}1"
DEV_ROOT="${DEV}2"

# pack include files with proper ownership
rm -f include.tar.gz
tar -czf include.tar.gz --owner=root:0 --group=root:0 -C include etc root

# create partition table (must have separate esp and root partitions)
# FIXME: overwrites existing partition table without confirmation!!!
sfdisk --lock $DEV <<-EOF
	label: gpt

	name=esp,  size=1G, type=uefi, bootable
	name=root, size=4G, type=linux
EOF

### ^^^ ADJUST THESE PARAMETERS ^^^ ###

# register function for reliable cleanup when script exits (both regular exit
# and premature termination due to errors, signals, etc.)
cleanup()
{
        # unmount bind mounts created by build process
        for mount in root.mnt/@root/boot/efi root.mnt ; do
                if mountpoint -q "$mount" ; then
                        umount "$mount"
                fi
        done

	if [ -d root.mnt ] ; then
		rmdir root.mnt
	fi
}
trap "cleanup" EXIT INT

# wait for udev to create device nodes
udevadm settle

# create btrfs filesystem, mount it, and create subvolumes
# FIXME: fails if $DEV_ROOT contains a partition signature
mkfs.btrfs --label root $DEV_ROOT
UUID_ROOT=$(blkid --match-tag UUID --output value $DEV_ROOT)
mkdir root.mnt
mount $DEV_ROOT root.mnt
btrfs subvolume create root.mnt/@root
btrfs subvolume create root.mnt/@home
btrfs subvolume set-default root.mnt/@root
mkdir -p root.mnt/@root/mnt/root

# create EFI system partition and mount it
mkfs.fat -F 32 $DEV_ESP
UUID_ESP=$(blkid --match-tag UUID --output value $DEV_ESP)
mkdir -p root.mnt/@root/boot/efi
mount $DEV_ESP root.mnt/@root/boot/efi

# bootstrap system, caching bootstrap results to accelerate potential rebuilds
if [ -f bootstrap.tar.gz ] ; then
	tar -xf bootstrap.tar.gz -C root.mnt/@root
else
	cdebootstrap --flavour=minimal --include=usrmerge,whiptail $DEBIAN_SUITE root.mnt/@root "http://deb.debian.org/debian"
	tar -czf bootstrap.tar.gz -C root.mnt/@root .
fi

# update resolv.conf (may have changed since bootstrapping)
cat /etc/resolv.conf > root.mnt/@root/etc/resolv.conf

# configure apt sources
echo "deb http://deb.debian.org/debian $DEBIAN_SUITE main contrib non-free" > root.mnt/@root/etc/apt/sources.list
if [ $DEBIAN_SUITE != "sid" ] ; then
	echo "deb http://security.debian.org/debian-security $DEBIAN_SUITE-security main contrib non-free" >> root.mnt/@root/etc/apt/sources.list
	echo "deb http://deb.debian.org/debian $DEBIAN_SUITE-updates main contrib non-free" >> root.mnt/@root/etc/apt/sources.list
	echo "deb http://deb.debian.org/debian $DEBIAN_SUITE-backports main contrib non-free" >> root.mnt/@root/etc/apt/sources.list
fi

# create /etc/hostname and /etc/hosts
echo "127.0.0.1 localhost" > root.mnt/@root/etc/hosts
if [ -n "$HOSTNAME_FQDN" ] ; then
	echo "$HOSTNAME_FQDN" > root.mnt/@root/etc/hostname
	echo "127.0.1.1 $HOSTNAME_FQDN $HOSTNAME" >> root.mnt/@root/etc/hosts
else
	echo "$HOSTNAME" > root.mnt/@root/etc/hostname
	echo "127.0.1.1 $HOSTNAME" >> root.mnt/@root/etc/hosts
fi

# create /etc/fstab
cat >root.mnt/@root/etc/fstab <<-EOF
	UUID="$UUID_ROOT" /         btrfs relatime,ssd              0 0
	UUID="$UUID_ROOT" /home     btrfs relatime,ssd,subvol=@home 0 0
	UUID="$UUID_ROOT" /mnt/root btrfs relatime,ssd,subvolid=5   0 0
	UUID="$UUID_ESP"                            /boot/efi vfat  relatime                  0 0
	tmpfs                                       /tmp      tmpfs mode=1777                 0 0
EOF

# create /etc/kernel/cmdline
echo "root=UUID=$UUID_ROOT ro" > root.mnt/@root/etc/kernel/cmdline

# untar includes
tar -xf include.tar.gz -C root.mnt/@root

# build systemd-boot package (required for automatic updates on Bullseye)
# TODO: remove when deprecating Bullseye
dpkg-deb -b systemd-boot/

# call chroot build script via bubblewrap:
#   * clears environment variables (prevents locale issues)
#   * binds /var/cache/apt/archives into chroot to cache downloaded .deb files
#   * partially isolates host system from build process (via minimally
#     populated /dev and /proc mounts)
#   * cleans up reliably (unmount everything and kill any remaining processes)
#
# TODO: remove /dev/block when deprecating Bullseye
# TODO: remove systemd-boot.deb when deprecating Bullseye
mkdir -p /var/cache/apt/archives
bwrap \
	--clearenv \
	--setenv DEBIAN_SUITE "$DEBIAN_SUITE" \
	--setenv HOME "$HOME" \
	--setenv PATH "/usr/sbin:/usr/bin:/sbin:/bin" \
	--setenv TERM "$TERM" \
	--setenv USER "$USER" \
	\
	--bind root.mnt/@root / \
	--bind root.mnt/@home /home \
	--dev /dev \
	--ro-bind /dev/block /dev/block \
	--dev-bind $DEV $DEV \
	--dev-bind $DEV_ROOT $DEV_ROOT \
	--dev-bind $DEV_ESP $DEV_ESP \
	--bind root.mnt /mnt/root \
	--proc /proc \
	--tmpfs /run \
	--ro-bind /sys /sys \
	--bind /sys/firmware/efi/efivars /sys/firmware/efi/efivars \
	--perms 1777 --tmpfs /tmp \
	--perms 500 --file 3 /tmp/install_chroot.sh \
	--perms 644 --file 4 /tmp/systemd-boot.deb \
	--bind /var/cache/apt/archives /var/cache/apt/archives \
	\
	--unshare-pid --die-with-parent \
	/tmp/install_chroot.sh \
		3<install_chroot.sh \
		4<systemd-boot.deb

# remove chroot helper that disables service invocation
dpkg --root=root.mnt/@root --purge cdebootstrap-helper-rc.d

# create snapshots
mkdir -p root.mnt/.snapshots/home root.mnt/.snapshots/root
chmod 700 root.mnt/.snapshots root.mnt/.snapshots/home root.mnt/.snapshots/root
btrfs subvol snapshot -r root.mnt/@home root.mnt/.snapshots/home/@$(date --utc +%Y-%m-%dT%H%M%SZ)
btrfs subvol snapshot -r root.mnt/@root root.mnt/.snapshots/root/@$(date --utc +%Y-%m-%dT%H%M%SZ)

# create snapshot script
cat >root.mnt/mksnapshot.sh <<-EOF
	#!/bin/sh -eux

	btrfs subvol snapshot -r /mnt/root/@home /mnt/root/.snapshots/home/@\$(date --utc +%Y-%m-%dT%H%M%SZ)
	btrfs subvol snapshot -r /mnt/root/@root /mnt/root/.snapshots/root/@\$(date --utc +%Y-%m-%dT%H%M%SZ)
EOF
chmod +x root.mnt/mksnapshot.sh

# cleanup() will be called by EXIT trap
