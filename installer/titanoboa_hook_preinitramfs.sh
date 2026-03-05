#!/usr/bin/env bash
#
set -exo pipefail

# Swap kernel with vanilla and rebuild initramfs.
#
# This is done because we want the initramfs to use a signed
# kernel for secureboot.
kernel_pkgs=(
    kernel
    kernel-core
    kernel-devel
    kernel-devel-matched
    kernel-modules
    kernel-modules-core
    kernel-modules-extra
)
dnf -y versionlock delete "${kernel_pkgs[@]}"
dnf --setopt=protect_running_kernel=False -y remove "${kernel_pkgs[@]}"
(cd /usr/lib/modules && rm -rf -- ./*)
dnf -y --repo fedora,updates --setopt=tsflags=noscripts install kernel kernel-core
kernel=$(find /usr/lib/modules -maxdepth 1 -type d -printf '%P\n' | grep .)
depmod "$kernel"

mkdir -p /sbin /etc/modules-load.d /etc/dracut.conf.d
cat >/sbin/mount.ntfs <<'EOF'
#!/bin/sh
# Try to locate a usable mount binary.
if command -v mount >/dev/null 2>&1; then
    MNT="$(command -v mount)"
elif [ -x /usr/bin/mount ]; then
    MNT="/usr/bin/mount"
elif [ -x /bin/mount ]; then
    MNT="/bin/mount"
else
    MNT="mount"
fi
exec "$MNT" -t ntfs3 "$@"
EOF

chmod 0755 /sbin/mount.ntfs
printf "ntfs3\nloop\niso9660\nsr_mod\n" >/etc/modules-load.d/early.conf
cat >/etc/dracut.conf.d/10-bazzite-installer-ntfs3.conf <<'EOF'
add_drivers+=" ntfs3 loop iso9660 sr_mod "
install_items+=" /sbin/mount.ntfs /etc/modules-load.d/early.conf "
EOF


imageref="$(podman images --format '{{ index .Names 0 }}\n' 'bazzite*' | head -1)"
imageref="${imageref##*://}"
imageref="${imageref%%:*}"


# Include nvidia-gpu-firmware package.
dnf install -yq nvidia-gpu-firmware || :
dnf clean all -yq
