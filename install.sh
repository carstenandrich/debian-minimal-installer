#!/bin/sh -eux

### vvv ADJUST THESE PARAMETERS vvv ###

# Debian suite to install (supported: bookworm, trixie, or sid)
DEBIAN_SUITE="sid"
# apt mirror to use for bootstrapping and installation
MIRROR="http://deb.debian.org/debian"
MIRROR_SECURITY="http://security.debian.org/debian-security"
# hostname and fully-qualified domain name (FQDN) of installed system
HOSTNAME="debian"
HOSTNAME_FQDN=""
# block device to install on (**WARNING**: will be overwritten!)
DEV="/dev/null"
# partition table in sfdisk syntax to create on $DEV, must contain:
#   * EFI system partition (ESP) with type=uefi and name=esp
#   * root partition with type=linux and name=root
PART_TABLE="label: gpt
name=esp,  size=1G, type=uefi, bootable
name=root, size=4G, type=linux"

# pack include files with proper ownership (git repo does not retain ownership)
rm -f include.tar.gz
tar -czf include.tar.gz --owner=root:0 --group=root:0 -C include etc root

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

	rm -f include.tar.gz
}
trap "cleanup" EXIT INT

# check if $DEV already contains a partition table or filesystem signature,
# because sfdisk overwrites existing partition tables without asking
if [ -n "$(blkid --match-tag PTTYPE --match-tag TYPE --output value $DEV)" ] ; then
	echo "ERROR: $DEV contains a partition table or filesystem signature"
	echo "To \033[01;31m**IRREVERSIBLY OVERWRITE**\033[0m $DEV, run 'wipefs -a $DEV' to wipe all signatures, then retry"
	exit 1
fi

# create partition table (wipe signatures to facilitate rerunning after failed
# installation attempt; above check is sufficient due diligence)
sfdisk --lock $DEV --wipe always --wipe-partitions always <<-EOF
$PART_TABLE
EOF

# wait for udev to create device nodes
udevadm settle

# get device names of created partitions
DEV_ESP=$(blkid --match-token PARTLABEL=esp --list-one --output device $DEV*)
DEV_ROOT=$(blkid --match-token PARTLABEL=root --list-one --output device $DEV*)

# create btrfs filesystem, mount it, and create subvolumes
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
mount -o umask=0077 $DEV_ESP root.mnt/@root/boot/efi

# bootstrap system, caching bootstrap results to accelerate potential rebuilds
if [ -f bootstrap.tar.gz ] ; then
	tar -xf bootstrap.tar.gz -C root.mnt/@root
else
	cdebootstrap --flavour=minimal --include=whiptail $DEBIAN_SUITE root.mnt/@root "$MIRROR"
	rm -rf root.mnt/@root/run/*

	# cache bootstrapping result
	tar -czf bootstrap.tar.gz -C root.mnt/@root .
fi

# update resolv.conf (may have changed since bootstrapping)
cat /etc/resolv.conf >root.mnt/@root/etc/resolv.conf

# configure apt sources
rm -f root.mnt/@root/etc/apt/sources.list
if [ "$DEBIAN_SUITE" = "sid" ] ; then
	cat >root.mnt/@root/etc/apt/sources.list.d/debian.sources <<-EOF
		Types: deb
		URIs: http://deb.debian.org/debian/
		Suites: sid
		Components: main contrib non-free non-free-firmware
		Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
	EOF
# TODO: remove fallback when deprecating bookworm
elif [ "$DEBIAN_SUITE" = "bookworm" ] ; then
	cat >root.mnt/@root/etc/apt/sources.list <<-EOF
		deb http://deb.debian.org/debian ${DEBIAN_SUITE} main contrib non-free non-free-firmware
		deb http://security.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free non-free-firmware
		deb http://deb.debian.org/debian ${DEBIAN_SUITE}-updates main contrib non-free non-free-firmware
		deb http://deb.debian.org/debian ${DEBIAN_SUITE}-backports main contrib non-free non-free-firmware
	EOF
else
	cat >root.mnt/@root/etc/apt/sources.list.d/debian.sources <<-EOF
		Types: deb
		URIs: http://deb.debian.org/debian/
		Suites: ${DEBIAN_SUITE} ${DEBIAN_SUITE}-updates ${DEBIAN_SUITE}-backports
		Components: main contrib non-free non-free-firmware
		Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

		Types: deb
		URIs: http://security.debian.org/debian-security/
		Suites: ${DEBIAN_SUITE}-security
		Components: main contrib non-free non-free-firmware
		Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
	EOF
fi

# create /etc/hostname and /etc/hosts
echo "127.0.0.1 localhost" >root.mnt/@root/etc/hosts
echo "$HOSTNAME" >root.mnt/@root/etc/hostname
if [ -n "$HOSTNAME_FQDN" ] ; then
	echo "127.0.1.1 $HOSTNAME_FQDN $HOSTNAME" >>root.mnt/@root/etc/hosts
else
	echo "127.0.1.1 $HOSTNAME" >>root.mnt/@root/etc/hosts
fi

# create /etc/fstab
cat >root.mnt/@root/etc/fstab <<-EOF
	UUID="$UUID_ROOT" /         btrfs relatime,ssd              0 0
	UUID="$UUID_ROOT" /home     btrfs relatime,ssd,subvol=@home 0 0
	UUID="$UUID_ROOT" /mnt/root btrfs relatime,ssd,subvolid=5   0 0
	UUID="$UUID_ESP"                            /boot/efi vfat  relatime,umask=0077       0 0
	tmpfs                                       /tmp      tmpfs mode=1777                 0 0
EOF

# create /etc/kernel/cmdline
echo "root=UUID=$UUID_ROOT ro" >root.mnt/@root/etc/kernel/cmdline

# untar includes
tar -xf include.tar.gz -C root.mnt/@root

# call chroot build script via bubblewrap:
#   * clears environment variables (prevents locale issues)
#   * binds /var/cache/apt/archives into chroot to cache downloaded .deb files
#   * partially isolates host system from build process (via minimally
#     populated /dev and /proc mounts)
#   * cleans up reliably (unmount everything and kill any remaining processes)
#
# TODO: use bwrap --clearenv when bubblewrap 0.5 is widely available
mkdir -p /var/cache/apt/archives
env --ignore-environment bwrap \
	--setenv DEBIAN_SUITE "$DEBIAN_SUITE" \
	--setenv HOME "$HOME" \
	--setenv PATH "/usr/sbin:/usr/bin:/sbin:/bin" \
	--setenv TERM "$TERM" \
	--setenv USER "$USER" \
	\
	--bind root.mnt/@root / \
	--bind root.mnt/@home /home \
	--dev /dev \
	--dev-bind $DEV $DEV \
	--dev-bind $DEV_ROOT $DEV_ROOT \
	--dev-bind $DEV_ESP $DEV_ESP \
	--bind root.mnt /mnt/root \
	--proc /proc \
	--tmpfs /run \
	--ro-bind /sys /sys \
	--bind /sys/firmware/efi/efivars /sys/firmware/efi/efivars \
	--tmpfs /tmp \
	--file 3 /tmp/install_chroot.sh \
	--bind /var/cache/apt/archives /var/cache/apt/archives \
	\
	--unshare-pid --die-with-parent \
	/bin/sh -eux /tmp/install_chroot.sh \
		3<install_chroot.sh

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
