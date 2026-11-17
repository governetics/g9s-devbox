#!/bin/bash
# g9s-devbox container healthcheck (P1).
#
# Proves the local core only: sshd accepts its configuration (host keys and
# the central authorized_keys in place), port 22 is actually LISTENing, the
# required state roots exist, and the central list is non-empty and
# readable BY DEV — the exact failure class of a root-readable-only list
# (OpenSSH reads AuthorizedKeysFile as the target user, so such a file
# rejects every login while `sshd -t` stays green). It does NOT prove an
# authenticated user workflow, VS Code Server, extensions or any LLM
# readiness (D-002 (ж)) — `healthy` != user-ready.

set -uo pipefail

fail() { echo "devbox-healthcheck: FAIL: $*" >&2; exit 1; }

STATE_ROOT=/var/lib/devbox
SYSTEM_DIR=$STATE_ROOT/system
AUTH_DIR=/etc/ssh/devbox
AUTHORIZED_KEYS=$AUTH_DIR/authorized_keys
DEV_USER=dev

[ "$(id -u)" -eq 0 ] || fail "healthcheck must run as root"

# sshd -t re-reads the full config: host keys, central authorized_keys,
# StrictModes. Any state damage (key loss/corruption, loosened modes)
# makes the container unhealthy and visible in `docker inspect`.
/usr/sbin/sshd -t || fail "sshd -t rejected the configuration/state"

# Real listener, not just a config claim.
ss -H -tln 'sport = :22' 2>/dev/null | grep -q ':22 ' || fail "no TCP listener on port 22"

# Required state roots: the bind is mounted and the layout is intact.
[ -d "$STATE_ROOT/home" ] || fail "$STATE_ROOT/home missing"
[ -d "$STATE_ROOT/workspaces" ] || fail "$STATE_ROOT/workspaces missing"
[ -d "$STATE_ROOT/services" ] || fail "$STATE_ROOT/services missing"
[ -f "$SYSTEM_DIR/identity" ] || fail "identity marker missing"
[ -f "$SYSTEM_DIR/ssh/ssh_host_ed25519_key" ] || fail "host key missing"

# Central authorized_keys (ephemeral, /etc/ssh/devbox): non-empty and —
# probed as the real user, not as root (root reads would mask a wrong
# mode/parent) — actually readable by dev. This closes the unreadable-as-
# dev failure class; it is still not a user-login proof.
[ -s "$AUTHORIZED_KEYS" ] || fail "central authorized_keys missing or empty"
runuser -u "$DEV_USER" -- test -r "$AUTHORIZED_KEYS" \
  || fail "central authorized_keys is not readable by $DEV_USER (OpenSSH reads it as the target user)"

echo "devbox-healthcheck: ok (sshd config, listener :22, state roots, central list readable by dev)"
exit 0
