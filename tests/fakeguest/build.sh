#!/usr/bin/env bash
# Builds tests/fakeguest/{vmlinuz,initrd.img} from Debian's kernel + busybox-static.
# Requires: busybox-static installed, apt-get download access, xz.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pkg=$(apt-cache depends linux-image-amd64 | awk '/Depends: linux-image/ {print $2; exit}')
(cd "$work" && apt-get download "$pkg" >/dev/null && dpkg-deb -x ./*.deb k)
kver=$(ls "$work/k/usr/lib/modules")
cp "$work/k/boot/vmlinuz-$kver" vmlinuz
mkdir -p "$work/root"/{bin,proc,sys,dev,lib}
cp /bin/busybox "$work/root/bin/busybox"
cp init "$work/root/init"
for m in net/core/failover drivers/net/net_failover drivers/net/virtio_net; do
  xz -dc "$work/k/usr/lib/modules/$kver/kernel/$m.ko.xz" > "$work/root/lib/$(basename $m).ko"
done
(cd "$work/root" && find . | cpio -o -H newc 2>/dev/null | gzip -1) > initrd.img
echo "built fakeguest for kernel $kver"
