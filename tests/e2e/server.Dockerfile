# A container that behaves like a fresh Ubuntu/Debian cloud VM: systemd, key-only SSH,
# default user with passwordless sudo and a locked password.
# It runs --privileged and shares the host kernel, so units that change global kernel state are masked.
# (systemd-binfmt would otherwise wipe WSL's interop registration on a Docker Desktop host.)
ARG BASE=ubuntu:24.04
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus openssh-server sudo iproute2 procps ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN (id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu) \
 && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-cloud-init-users \
 && chmod 440 /etc/sudoers.d/90-cloud-init-users \
 && passwd -l ubuntu \
 && mkdir -p /etc/ssh/sshd_config.d \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
COPY id_test.pub /home/ubuntu/.ssh/authorized_keys
RUN chown -R ubuntu:ubuntu /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh && chmod 600 /home/ubuntu/.ssh/authorized_keys \
 && (systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true) \
 && systemctl mask systemd-binfmt.service proc-sys-fs-binfmt_misc.mount proc-sys-fs-binfmt_misc.automount \
    systemd-sysctl.service systemd-modules-load.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
