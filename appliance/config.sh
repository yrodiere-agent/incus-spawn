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
rm -f /usr/lib64/libLLVM*.so* 2>/dev/null || true
rm -f /usr/lib64/libgallium*.so* 2>/dev/null || true
rm -f /usr/lib64/libvulkan_lvp*.so* 2>/dev/null || true
rm -f /usr/lib64/libMesa*.so* 2>/dev/null || true
rm -rf /usr/lib64/dri 2>/dev/null || true
rm -f /usr/bin/qemu-system-* 2>/dev/null || true
rm -f /usr/bin/qemu-img 2>/dev/null || true
rm -f /usr/bin/skopeo 2>/dev/null || true
rm -f /usr/bin/lego 2>/dev/null || true
rm -rf /usr/share/qemu 2>/dev/null || true
rm -rf /usr/share/seabios 2>/dev/null || true
rm -rf /usr/share/ipxe 2>/dev/null || true

#-- Remove initrd from rootfs (it's extracted separately) --#
rm -f /boot/initrd* 2>/dev/null || true

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
