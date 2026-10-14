# sql-ag-lab runtime image: a deliberately small, fully deterministic QEMU launcher.
# Why not run dockurr/windows at runtime? Restoring a memory-state snapshot requires the
# destination QEMU command line (machine, devices, firmware, NIC) to be byte-for-byte
# compatible with the source. dockur generates its command line dynamically, uses a raw
# UEFI vars file (blocks snapshots) and its own NAT/DHCP stack, and its maintainer has
# declined snapshot support (dockur/windows#485, #1288). dockur is still used to build
# the base image (ISO download + unattended install + virtio drivers).
FROM debian:trixie-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils ovmf iproute2 python3 procps ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY launcher.sh router.sh qmp.py /opt/lab/
RUN chmod +x /opt/lab/launcher.sh /opt/lab/router.sh /opt/lab/qmp.py \
 && /usr/bin/qemu-system-x86_64 --version
ENTRYPOINT ["/opt/lab/launcher.sh"]
