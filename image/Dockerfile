# g9s-devbox runtime image, P1: local core (tini + sshd).
#
# Contract (D-001 (a), D-002): pinned Debian 13 slim base by digest, exact
# package pins measured on the base (session 261117-01), tini -g as PID 1,
# root bootstrap entrypoint, foreground sshd. The image contains NO agents,
# NO VS Code Server (client-installed, P2), NO SFTPGo/Samba (siblings, P3),
# NO supervisor. Persistent state lives only in the bind mount, not in
# named volumes or image layers.

# Measured index digest of debian:13-slim (linux/amd64 manifest
# sha256:7378260c0a098d27ac206225db5e7d92b8c7c84ea7afccc86eeb513756bbd392).
# A tag move cannot change what this build starts from.
FROM debian:13-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

ENV DEBIAN_FRONTEND=noninteractive

# Exact pins agreed for P1 (apt candidates measured on this exact digest).
# openssh-server needs a client for key handling; libstdc++6 is pinned for
# the P2 toolchain baseline. apt fails the build when any pin is gone.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-server=1:10.0p1-7+deb13u4 \
        openssh-client=1:10.0p1-7+deb13u4 \
        tini=0.19.0-3+b8 \
        git=1:2.47.3-0+deb13u1 \
        curl=8.14.1-2+deb13u7 \
        ca-certificates=20250419+deb13u1 \
        iproute2=6.15.0-1 \
        libstdc++6=14.2.0-19 \
    && rm -rf /var/lib/apt/lists/*

# sshd config: key-only `dev`, central authorized_keys, internal-sftp,
# root/password/kbd-interactive denied (see image/sshd_config).
COPY image/sshd_config /etc/ssh/sshd_config

# Root bootstrap + healthcheck. The entrypoint validates state/identity and
# execs sshd; it never regenerates host keys when the identity marker
# exists (seed-only host keys, D-002 (g)).
COPY image/entrypoint.sh /usr/local/bin/devbox-entrypoint.sh
COPY image/healthcheck.sh /usr/local/bin/devbox-healthcheck.sh
RUN chmod 0755 /usr/local/bin/devbox-entrypoint.sh /usr/local/bin/devbox-healthcheck.sh \
    && chmod 0644 /etc/ssh/sshd_config

# tini -g as PID 1: signal reaping and process-group kill for the sshd
# tree. No CMD: the entrypoint ends with `exec /usr/sbin/sshd -D -e`.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/devbox-entrypoint.sh"]
