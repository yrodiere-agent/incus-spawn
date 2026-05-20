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

#-- Remove package manager for immutable appliance --#
# KIWI's <packages type="uninstall"> fails, so remove manually
rm -f /usr/bin/zypper /usr/bin/rpm 2>/dev/null || true
rm -rf /usr/lib*/libzypp* /usr/lib*/librpm* 2>/dev/null || true
rm -rf /usr/share/zypper 2>/dev/null || true

#-- Set default locale --#
echo 'LANG=C.UTF-8' > /etc/locale.conf

exit 0
