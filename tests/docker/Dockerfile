# Test machine: Linux Mint with systemd as PID 1, so install.sh can be tested
# exactly like on the real deck (services, docker, sudo, a desktop user).
# Built and started by tests/run-docker-test.sh.
ARG BASE_IMAGE=linuxmintd/mint22.3-amd64
FROM ${BASE_IMAGE}

ARG DISABLE_MINT_REPO=0
ENV container=docker DEBIAN_FRONTEND=noninteractive

# Extra CA certificate (only when the build machine sits behind a TLS-inspecting proxy).
COPY extra-ca.crt /usr/local/share/ca-certificates/extra-ca.crt
RUN if [ ! -s /usr/local/share/ca-certificates/extra-ca.crt ]; then rm -f /usr/local/share/ca-certificates/extra-ca.crt; fi \
 && if [ "$DISABLE_MINT_REPO" = "1" ]; then sed -i 's/^deb\(-src\)\? http:\/\/packages.linuxmint.com/# &/' /etc/apt/sources.list.d/*.list; fi \
 && apt-get update -q \
 && apt-get install -y -q --no-install-recommends systemd systemd-sysv dbus dbus-user-session sudo ca-certificates \
      curl cron xvfb dbus-x11 x11-apps imagemagick xterm openbox cinnamon-desktop-data procps iproute2 \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Trim systemd for a container.
RUN systemctl mask getty@tty1.service systemd-logind.service systemd-udevd.service systemd-udev-trigger.service \
      console-getty.service systemd-remount-fs.service 2>/dev/null || true \
 && systemctl enable cron.service

# The desktop user, like on the deck (admin with sudo; no password for the test).
RUN useradd -m -s /bin/bash -G sudo deck \
 && echo 'deck ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-deck && chmod 440 /etc/sudoers.d/90-deck

# Docker inside the test machine needs real (non-overlay) storage for its images.
VOLUME ["/var/lib/docker", "/var/lib/containerd"]
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
