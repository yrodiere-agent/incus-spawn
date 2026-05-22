#!/bin/bash
# KIWI post-install script — runs inside the chroot during image build.
# Configures the minimal appliance for running Incus containers.

set -euo pipefail

#-- Systemd: enable only essential services --#
systemctl enable systemd-networkd
systemctl enable sshd
systemctl enable incus.service
systemctl enable incus-spawn-vm.service

#-- Systemd: mask everything we don't need --#
systemctl mask systemd-resolved
systemctl mask systemd-homed
systemctl mask systemd-userdbd
systemctl mask ModemManager
systemctl mask plymouth-start
systemctl mask plymouth-quit
systemctl mask plymouth-quit-wait
systemctl mask plymouth-read-write
systemctl mask serial-getty@ttyS0
systemctl mask getty@tty1
systemctl mask console-setup
systemctl mask remote-fs.target
systemctl mask sys-kernel-debug.mount
systemctl mask sys-kernel-tracing.mount
systemctl mask systemd-pstore.service
systemctl mask e2scrub_all.timer
systemctl mask e2scrub_reap.service
systemctl mask fstrim.timer

#-- Network: systemd-networkd DHCP on all en* and eth* interfaces --#
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-wired.network << 'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCPv4]
UseDNS=yes
EOF

#-- DNS: point resolv.conf at systemd-networkd's stub --#
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

#-- Incus: pre-configure subuid/subgid --#
echo "root:100000:65536" >> /etc/subuid
echo "root:100000:65536" >> /etc/subgid

#-- SSH: disable password auth, enable pubkey --#
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
else
    # Create minimal sshd_config if package didn't provide one
    mkdir -p /etc/ssh
    cat > /etc/ssh/sshd_config << 'SSHEOF'
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/ssh/sftp-server
SSHEOF
fi

#-- Root SSH dir for authorized_keys injection --#
mkdir -p /root/.ssh
chmod 700 /root/.ssh

#-- Strip locale data and docs to minimize image size --#
rm -rf /usr/share/man /usr/share/doc /usr/share/info 2>/dev/null || true
rm -rf /usr/share/locale/* 2>/dev/null || true
rm -rf /var/cache/zypp /var/log/zypp 2>/dev/null || true
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

#-- Remove heavy Incus deps not needed for headless container hosting --#
# Graphics/GPU (pulled in by Incus's QEMU dep)
rm -f /usr/lib64/libLLVM*.so* 2>/dev/null || true
rm -f /usr/lib64/libgallium*.so* 2>/dev/null || true
rm -f /usr/lib64/libvulkan*.so* 2>/dev/null || true
rm -f /usr/lib64/libMesa*.so* 2>/dev/null || true
rm -f /usr/lib64/libSPIRV*.so* 2>/dev/null || true
rm -f /usr/lib64/libcapstone*.so* 2>/dev/null || true
rm -f /usr/lib64/libpython*.so* 2>/dev/null || true
rm -rf /usr/lib64/dri 2>/dev/null || true
rm -rf /usr/lib64/python* 2>/dev/null || true
# QEMU tools (Incus uses its own bundled QEMU for VMs, we only run containers)
rm -f /usr/bin/qemu-system-* /usr/bin/qemu-img /usr/bin/qemu-io 2>/dev/null || true
rm -f /usr/bin/qemu-nbd /usr/bin/qemu-storage-daemon 2>/dev/null || true
rm -rf /usr/share/qemu /usr/share/seabios /usr/share/ipxe 2>/dev/null || true
# Container image tools not needed at runtime
rm -f /usr/bin/skopeo /usr/bin/lego /usr/bin/umoci 2>/dev/null || true
# virtiofsd (Incus includes its own)
rm -f /usr/libexec/virtiofsd 2>/dev/null || true
# Perl (rpm scriptlet dependency, not needed at runtime)
rm -f /usr/bin/perl /usr/bin/perl5.* 2>/dev/null || true
rm -rf /usr/lib/perl5 2>/dev/null || true

#-- Remove boot files from rootfs (extracted separately for direct boot) --#
rm -f /boot/initrd* /boot/vmlinuz* /boot/System.map* 2>/dev/null || true
rm -f /usr/lib/modules/*/vmlinuz /usr/lib/modules/*/vmlinux.xz 2>/dev/null || true
rm -f /usr/lib/modules/*/System.map 2>/dev/null || true

#-- Strip kernel modules: remove drivers not needed in a virtual machine --#
KVER=$(ls /usr/lib/modules/ | head -1)
if [ -n "$KVER" ]; then
    MODDIR="/usr/lib/modules/$KVER/kernel"
    # GPU/DRM — headless VM, no display
    rm -rf "$MODDIR/drivers/gpu" 2>/dev/null || true
    # Sound — no audio in VM
    rm -rf "$MODDIR/sound" "$MODDIR/drivers/soundwire" 2>/dev/null || true
    # Wireless/Bluetooth — VM uses virtio-net
    rm -rf "$MODDIR/drivers/net/wireless" "$MODDIR/net/wireless" 2>/dev/null || true
    rm -rf "$MODDIR/drivers/bluetooth" "$MODDIR/net/bluetooth" 2>/dev/null || true
    # USB host controllers — no physical USB in VM
    rm -rf "$MODDIR/drivers/usb/host" "$MODDIR/drivers/usb/gadget" 2>/dev/null || true
    rm -rf "$MODDIR/drivers/usb/serial" "$MODDIR/drivers/usb/storage" 2>/dev/null || true
    # Hardware-specific drivers not relevant in QEMU
    rm -rf "$MODDIR/drivers/hwmon" "$MODDIR/drivers/iio" 2>/dev/null || true
    rm -rf "$MODDIR/drivers/media" "$MODDIR/drivers/infiniband" 2>/dev/null || true
    rm -rf "$MODDIR/drivers/isdn" "$MODDIR/drivers/nfc" 2>/dev/null || true
    rm -rf "$MODDIR/drivers/w1" "$MODDIR/drivers/comedi" 2>/dev/null || true
    rm -rf "$MODDIR/drivers/staging" 2>/dev/null || true
    # Filesystems we don't use
    rm -rf "$MODDIR/fs/ceph" "$MODDIR/fs/gfs2" "$MODDIR/fs/ocfs2" 2>/dev/null || true
    rm -rf "$MODDIR/fs/nfs" "$MODDIR/fs/cifs" "$MODDIR/fs/smbfs" 2>/dev/null || true
    rm -rf "$MODDIR/fs/9p" "$MODDIR/fs/afs" 2>/dev/null || true
    # Rebuild module dependency index
    depmod "$KVER" 2>/dev/null || true
fi

#-- Remove udev hardware databases (VM doesn't need hardware detection) --#
rm -f /usr/lib/udev/hwdb.d/20-pci-*.hwdb 2>/dev/null || true
rm -f /usr/lib/udev/hwdb.d/20-OUI.hwdb 2>/dev/null || true
rm -f /usr/lib/udev/hwdb.d/20-usb-*.hwdb 2>/dev/null || true
rm -f /usr/lib/udev/hwdb.d/20-bluetooth*.hwdb 2>/dev/null || true
rm -f /usr/share/file/magic.mgc 2>/dev/null || true

#-- Remove package manager for immutable appliance --#
rm -f /usr/bin/zypper /usr/bin/rpm 2>/dev/null || true
rm -rf /usr/lib*/libzypp* /usr/lib*/librpm* 2>/dev/null || true
rm -rf /usr/share/zypper 2>/dev/null || true
rm -rf /usr/lib/sysimage/rpm 2>/dev/null || true

#-- Dracut: ensure squashfs + overlay modules are in the initrd --#
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/squashfs.conf << 'EOF'
add_drivers+=" squashfs overlay "
EOF

#-- Set default locale --#
echo 'LANG=C.UTF-8' > /etc/locale.conf

exit 0
