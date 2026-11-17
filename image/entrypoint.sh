#!/bin/bash
# g9s-devbox root bootstrap (P1). tini -g is PID 1; this script runs as
# root, validates persistent state and identity, materializes the central
# authorized_keys, ensures the unprivileged `dev` user, and execs
# `sshd -D -e` in the foreground.
#
# Contract (D-002):
#   - env and public keys are validated BEFORE any state mutation;
#   - the bind root itself must be root:root 0755 — checked
#     unconditionally on every start, BEFORE the known/empty branching
#     (recreate included);
#   - first boot on an empty prepared tree seeds the ed25519 host key and
#     writes the root-owned identity marker (schema 1, numeric UID/GID);
#   - with an existing marker the host key is never regenerated: loss,
#     corruption, UID/GID/schema mismatch, bad modes/owners, or an unknown
#     non-empty state fail BEFORE sshd starts (fail-loud, stderr + exit);
#   - state inspection is fail-closed and newline-safe: a missing or
#     failing find(1), or a top-level name outside home/workspaces/system/
#     services/lost+found, refuses the start (GNU find -printf is the
#     Debian contract); the top-level scan is unconditional — it runs on
#     every start, after the root owner/mode check and BEFORE the
#     known/empty branching, so a known state with an extra top-level
#     entry refuses too (nested emptiness is a no-marker-only concern);
#   - symlinks are refused for the identity marker and every top root
#     (system, system/ssh, services, home, workspaces) before the
#     -d/owner/mode checks: [ -e ]/[ -d ]/stat follow symlinks, so the
#     right stat bits on a link target must not pass;
#   - the central root-owned authorized_keys lives at
#     /etc/ssh/devbox/authorized_keys on the CONTAINER LAYER (ephemeral):
#     env is the authority, the file is a start-time materialization,
#     atomically re-created from DEVBOX_RUNTIME_AUTHORIZED_KEYS on every
#     start. OpenSSH reads AuthorizedKeysFile under the target user's
#     identity (temporarily_use_uid), so dev must traverse the parent and
#     read the file — impossible under system/ 0700, and that denial is
#     contract (host keys, identity marker), not a defect to relax. The
#     parent is a regular root:root 0755 directory (checked/created
#     fail-closed, non-recursive, symlink-refused), the file is root:root
#     0644 (public keys are not secrets), and the atomic mv replaces the
#     destination without ever writing through a symlink. A stale
#     authorized_keys left under system/ by older versions is neither
#     read nor deleted here (operator-side cleanup is a separate act);
#   - /run/sshd (sshd privilege separation) is ensured fail-closed and
#     idempotently: symlink refusal and type check, a die-guarded
#     non-recursive mkdir only when the path is absent (a restart of the
#     same container must not die on the already-present directory), then
#     an unconditional root:root 0755 owner/mode check;
#   - no recursive chown/chmod anywhere; nothing is deleted.
#
# The runtime env names are DEVBOX_RUNTIME_* (mapped in compose) so the
# panel env_file carrying DEVBOX_* originals is never shadowed.

set -euo pipefail

STATE_ROOT=/var/lib/devbox
SYSTEM_DIR=$STATE_ROOT/system
SERVICES_DIR=$STATE_ROOT/services
HOME_DIR=$STATE_ROOT/home
WORKSPACES_DIR=$STATE_ROOT/workspaces
SSH_DIR=$SYSTEM_DIR/ssh
IDENTITY=$SYSTEM_DIR/identity
HOST_KEY=$SSH_DIR/ssh_host_ed25519_key
HOST_KEY_PUB=${HOST_KEY}.pub
SCHEMA_VERSION=1
DEV_USER=dev
# Ephemeral runtime trust path (container layer, not the bind): OpenSSH
# reads AuthorizedKeysFile as the target user, so it cannot live in system/.
AUTH_DIR=/etc/ssh/devbox
AUTHORIZED_KEYS=$AUTH_DIR/authorized_keys

log() { echo "devbox-entrypoint: $*"; }
die() { echo "devbox-entrypoint: FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Phase 1 — validate inputs. No state mutation happens before this passes.
# ---------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "must run as root (tini entrypoint)"

for var in DEVBOX_RUNTIME_UID DEVBOX_RUNTIME_GID DEVBOX_RUNTIME_AUTHORIZED_KEYS; do
  eval "value=\${$var-}"
  [ -n "$value" ] || die "$var is not set (compose maps it from DEVBOX_* inputs)"
done

case "$DEVBOX_RUNTIME_UID" in ''|*[!0-9]*) die "DEVBOX_RUNTIME_UID must be numeric, got '$DEVBOX_RUNTIME_UID'";; esac
case "$DEVBOX_RUNTIME_GID" in ''|*[!0-9]*) die "DEVBOX_RUNTIME_GID must be numeric, got '$DEVBOX_RUNTIME_GID'";; esac
[ "$DEVBOX_RUNTIME_UID" -ge 1 ] || die "DEVBOX_RUNTIME_UID must be >= 1 (dev is non-root)"
[ "$DEVBOX_RUNTIME_GID" -ge 1 ] || die "DEVBOX_RUNTIME_GID must be >= 1"
command -v find > /dev/null 2>&1 || die "find(1) not found; empty-tree verification is impossible (fail-closed refusal)"

# Validate every non-blank line as an OpenSSH public key via ssh-keygen.
# '#' comment lines are rejected on purpose: descriptions belong in the key
# comment field, and the central list must contain only loadable keys.
validate_authorized_keys() {
  local lineno=0 keyfile
  keyfile=$(mktemp /tmp/devbox-keycheck.XXXXXX)
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in
      '') continue ;;
      '#'*) echo "line $lineno: comment lines are not allowed in DEVBOX_RUNTIME_AUTHORIZED_KEYS" >&2; return 1 ;;
    esac
    printf '%s\n' "$line" > "$keyfile"
    if ! ssh-keygen -lf "$keyfile" >/dev/null 2>&1; then
      echo "line $lineno: not a valid OpenSSH public key: $line" >&2
      return 1
    fi
  done <<< "$DEVBOX_RUNTIME_AUTHORIZED_KEYS"
  rm -f "$keyfile"
}
validate_authorized_keys || die "DEVBOX_RUNTIME_AUTHORIZED_KEYS failed validation; refusing to touch state"

KEY_COUNT=$(printf '%s\n' "$DEVBOX_RUNTIME_AUTHORIZED_KEYS" | sed 's/\r$//' | grep -c '[^[:space:]]' || true)
[ "$KEY_COUNT" -ge 1 ] || die "DEVBOX_RUNTIME_AUTHORIZED_KEYS contains no keys"

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# stat-based owner/mode assertion: check_mode_owner <path> <uid> <gid> <mode>
check_mode_owner() {
  local actual
  actual=$(stat -c '%u %g %a' "$1" 2>/dev/null) || die "cannot stat $1"
  [ "$actual" = "$2 $3 $4" ] || die "$1 has owner/mode '$actual', expected '$2 $3 $4'"
}

# Atomic root-owned file write: write_atomic <dest> <mode> <stdin>
write_atomic() {
  local dest=$1 mode=$2 tmp
  tmp=$(mktemp "${dest}.tmp.XXXXXX")
  cat > "$tmp"
  chown 0:0 "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
}

# Parse the identity marker without eval: strict key=value, numeric values,
# no duplicates, no unknown keys. Sets parsed_schema/parsed_uid/parsed_gid.
read_marker() {
  parsed_schema= parsed_uid= parsed_gid=
  local lineno=0 key value
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ -n "$line" ] || continue
    case "$line" in
      schema=*|uid=*|gid=*) ;;
      *) echo "identity marker line $lineno: unknown content '$line'" >&2; return 1 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$value" in ''|*[!0-9]*) echo "identity marker line $lineno: non-numeric value '$line'" >&2; return 1 ;; esac
    case "$key" in
      schema) [ -z "$parsed_schema" ] || { echo "identity marker: duplicate key '$key'" >&2; return 1; }; parsed_schema=$value ;;
      uid)    [ -z "$parsed_uid" ]    || { echo "identity marker: duplicate key '$key'" >&2; return 1; }; parsed_uid=$value ;;
      gid)    [ -z "$parsed_gid" ]    || { echo "identity marker: duplicate key '$key'" >&2; return 1; }; parsed_gid=$value ;;
    esac
  done < "$1"
  [ -n "$parsed_schema" ] && [ -n "$parsed_uid" ] && [ -n "$parsed_gid" ] || {
    echo "identity marker $1: missing schema/uid/gid" >&2; return 1;
  }
}

# ---------------------------------------------------------------------------
# Phase 2 — state machine: known marker / empty first boot / unknown state.
# ---------------------------------------------------------------------------

[ -d "$STATE_ROOT" ] || die "$STATE_ROOT does not exist; run scripts/host-prep.sh on the host first"

# Root trust boundary: the bind root itself must be root:root 0755 on every
# start — known recreate and empty first boot alike — before any branching.
check_mode_owner "$STATE_ROOT" 0 0 755

# Top-level unknown-state scan, unconditional (closes the no-marker-only
# asymmetry): same fail-closed, newline-safe form as host-prep — the
# allowed-name decision is made BY find itself (a fixed -printf marker,
# -quit after the first), entry names never feed shell parsing, and any
# nonzero find rc is FATAL. Runs after the root owner/mode check and
# BEFORE the known/empty branching: a known state with an extra top-level
# entry refuses too. Nested emptiness below stays no-marker-only.
top_rc=0
top_mark=$(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 \
             ! -name home ! -name workspaces ! -name system \
             ! -name services ! -name lost+found \
             -printf 'unexpected-entry\n' -quit) || top_rc=$?
[ "$top_rc" -eq 0 ] || die "find failed under $STATE_ROOT (rc=$top_rc); cannot verify tree state; refusing to start"
if [ "$top_mark" = "unexpected-entry" ]; then
  die "unknown non-empty state: an entry other than home/workspaces/system/services/lost+found exists under $STATE_ROOT; refusing to start (known and empty states alike)"
fi

if [ -e "$IDENTITY" ]; then
  # Known identity: verify everything, mutate only the central key list.
  # Symlink first: [ -e ]/[ -f ]/stat follow links, so the marker is
  # accepted only as a real regular root-owned file, never a link to one.
  [ ! -L "$IDENTITY" ] || die "$IDENTITY is a symlink; symlinks on the state tree are refused"
  [ -f "$IDENTITY" ] || die "$IDENTITY exists but is not a regular file"
  read_marker "$IDENTITY" || die "identity marker at $IDENTITY is unreadable/corrupt; refusing to start sshd"
  [ "$parsed_schema" = "$SCHEMA_VERSION" ] || die "identity marker schema $parsed_schema != supported $SCHEMA_VERSION; explicit migration required"
  [ "$parsed_uid" = "$DEVBOX_RUNTIME_UID" ] || die "identity marker uid $parsed_uid != DEVBOX_RUNTIME_UID $DEVBOX_RUNTIME_UID; explicit migration required"
  [ "$parsed_gid" = "$DEVBOX_RUNTIME_GID" ] || die "identity marker gid $parsed_gid != DEVBOX_RUNTIME_GID $DEVBOX_RUNTIME_GID; explicit migration required"
  check_mode_owner "$IDENTITY" 0 0 600

  # Type first — symlink, then directory — then owner/mode: a symlink or
  # any non-directory carrying the right stat bits (stat follows links)
  # must not pass the checks below.
  [ ! -L "$SYSTEM_DIR" ] || die "$SYSTEM_DIR is a symlink; symlinks on the state tree are refused"
  [ -d "$SYSTEM_DIR" ] || die "$SYSTEM_DIR missing with marker present (damaged state)"
  [ ! -L "$SSH_DIR" ] || die "$SSH_DIR is a symlink; symlinks on the state tree are refused"
  [ -d "$SSH_DIR" ] || die "$SSH_DIR missing with marker present: host keys lost"
  [ ! -L "$SERVICES_DIR" ] || die "$SERVICES_DIR is a symlink; symlinks on the state tree are refused"
  [ -d "$SERVICES_DIR" ] || die "$SERVICES_DIR missing with marker present (damaged state)"
  [ ! -L "$HOME_DIR" ] || die "$HOME_DIR is a symlink; symlinks on the state tree are refused"
  [ -d "$HOME_DIR" ] || die "$HOME_DIR missing with marker present (damaged state)"
  [ ! -L "$WORKSPACES_DIR" ] || die "$WORKSPACES_DIR is a symlink; symlinks on the state tree are refused"
  [ -d "$WORKSPACES_DIR" ] || die "$WORKSPACES_DIR missing with marker present (damaged state)"
  check_mode_owner "$SYSTEM_DIR" 0 0 700
  check_mode_owner "$SSH_DIR" 0 0 700
  check_mode_owner "$SERVICES_DIR" 0 0 700
  check_mode_owner "$HOME_DIR" "$DEVBOX_RUNTIME_UID" "$DEVBOX_RUNTIME_GID" 750
  check_mode_owner "$WORKSPACES_DIR" "$DEVBOX_RUNTIME_UID" "$DEVBOX_RUNTIME_GID" 750

  [ -f "$HOST_KEY" ] || die "host key $HOST_KEY lost (marker present); seed-only policy refuses to regenerate; restore from backup or rebuild identity explicitly"
  check_mode_owner "$HOST_KEY" 0 0 600
  ssh-keygen -y -P '' -f "$HOST_KEY" > /dev/null 2>&1 || die "host key $HOST_KEY is corrupt (does not load); refusing to start sshd"
  if [ ! -f "$HOST_KEY_PUB" ]; then
    # The .pub is derived material: rebuild it from the intact private key.
    ssh-keygen -y -P '' -f "$HOST_KEY" | write_atomic "$HOST_KEY_PUB" 644
    log "re-derived $HOST_KEY_PUB from the intact private host key"
  fi
  log "state verified: marker schema $parsed_schema, uid/gid $parsed_uid/$parsed_gid; host key reused"
else
  # No marker: only a fully prepared EMPTY tree may bootstrap. The
  # top-level scan already ran unconditionally above; what remains here
  # is nested emptiness — fail-closed and newline-safe: nested content is
  # detected by a fixed -printf marker (a newline-only name is still
  # content), and any nonzero find rc is FATAL.
  for d in home workspaces system services; do
    dir=$STATE_ROOT/$d
    [ ! -L "$dir" ] || die "$dir is a symlink; symlinks on the state tree are refused"
    [ -d "$dir" ] || die "$dir missing; run scripts/host-prep.sh before first start"
    nested_rc=0
    nested_mark=$(find "$dir" -mindepth 1 -printf 'nested-content\n' -quit) || nested_rc=$?
    [ "$nested_rc" -eq 0 ] || die "find failed under $dir (rc=$nested_rc); cannot verify emptiness; refusing first boot"
    if [ "$nested_mark" = "nested-content" ]; then
      die "unknown non-empty state: $dir is not empty (nested content, dotfiles included) and no identity marker exists (restored tree?); adoption is an explicit operator decision"
    fi
  done
  check_mode_owner "$HOME_DIR" "$DEVBOX_RUNTIME_UID" "$DEVBOX_RUNTIME_GID" 750
  check_mode_owner "$WORKSPACES_DIR" "$DEVBOX_RUNTIME_UID" "$DEVBOX_RUNTIME_GID" 750
  check_mode_owner "$SYSTEM_DIR" 0 0 700
  check_mode_owner "$SERVICES_DIR" 0 0 700

  # First boot: seed the only host key (ed25519), then fix the marker.
  # A crash between the two leaves orphaned keys without a marker -> next
  # start hits the unknown-state branch above and fails loudly.
  mkdir "$SSH_DIR" || die "cannot create $SSH_DIR"
  chown 0:0 "$SSH_DIR"; chmod 0700 "$SSH_DIR"
  ssh-keygen -q -t ed25519 -N '' -f "$HOST_KEY" -C "devbox-host" \
    || die "host key generation failed"
  chown 0:0 "$HOST_KEY" "$HOST_KEY_PUB"
  chmod 0600 "$HOST_KEY"; chmod 0644 "$HOST_KEY_PUB"
  printf 'schema=%s\nuid=%s\ngid=%s\n' "$SCHEMA_VERSION" "$DEVBOX_RUNTIME_UID" "$DEVBOX_RUNTIME_GID" \
    | write_atomic "$IDENTITY" 600
  log "first boot: ed25519 host key seeded, identity marker written (schema $SCHEMA_VERSION, uid/gid $DEVBOX_RUNTIME_UID/$DEVBOX_RUNTIME_GID)"
fi

# ---------------------------------------------------------------------------
# Phase 3 — central authorized_keys: atomic root-owned materialization.
#
# The central list is EPHEMERAL (container layer), not persistent state:
# env is the single authority, and every start re-materializes the file.
# It must live where OpenSSH can read it AS THE TARGET USER: sshd checks
# AuthorizedKeysFile under temporarily_use_uid(dev), so the parent must be
# traversable and the file readable by dev — while system/ keeps its 0700
# root-only contract for host keys and the identity marker. Public keys
# are not secrets; root:root 0755/0644 gives dev exactly read access.
# ---------------------------------------------------------------------------

# Fail-closed, non-recursive parent handling: a regular root:root 0755
# directory only. Symlink first — [ -e ]/[ -d ]/stat follow links, so a
# link carrying the right stat bits must be refused before the checks.
if [ -e "$AUTH_DIR" ] || [ -L "$AUTH_DIR" ]; then
  [ ! -L "$AUTH_DIR" ] || die "$AUTH_DIR is a symlink; symlinks on the trust path are refused"
  [ -d "$AUTH_DIR" ] || die "$AUTH_DIR exists but is not a directory"
else
  # Non-recursive create: /etc/ssh must already exist (openssh-server
  # image layout); mkdir without -p refuses to invent missing parents.
  [ -d /etc/ssh ] || die "/etc/ssh missing; openssh-server image layout broken"
  mkdir "$AUTH_DIR" || die "cannot create $AUTH_DIR"
  chown 0:0 "$AUTH_DIR"
  chmod 0755 "$AUTH_DIR"
fi
check_mode_owner "$AUTH_DIR" 0 0 755

# Atomic materialization: mktemp in the verified parent, then mv -f —
# rename(2) over the destination replaces whatever sits there (a stray
# symlink included) and never writes through it.
printf '%s\n' "$DEVBOX_RUNTIME_AUTHORIZED_KEYS" | sed 's/\r$//' | write_atomic "$AUTHORIZED_KEYS" 644
[ ! -L "$AUTHORIZED_KEYS" ] || die "$AUTHORIZED_KEYS is a symlink after materialization"
check_mode_owner "$AUTHORIZED_KEYS" 0 0 644
log "central authorized_keys materialized: $KEY_COUNT key(s) at $AUTHORIZED_KEYS"

# ---------------------------------------------------------------------------
# Phase 4 — the unprivileged user (container layer, not persistent state).
# ---------------------------------------------------------------------------

if getent passwd "$DEV_USER" > /dev/null; then
  # Restart of the same container: the account already exists; only the
  # numeric identity may be checked, never silently rewritten.
  set -- $(getent passwd "$DEV_USER" | cut -d: -f3,4 | tr ':' ' ')
  [ "$1" = "$DEVBOX_RUNTIME_UID" ] || die "user $DEV_USER exists with uid $1 != DEVBOX_RUNTIME_UID $DEVBOX_RUNTIME_UID"
  [ "$2" = "$DEVBOX_RUNTIME_GID" ] || die "user $DEV_USER exists with gid $2 != DEVBOX_RUNTIME_GID $DEVBOX_RUNTIME_GID"
else
  getent group "$DEVBOX_RUNTIME_GID" > /dev/null || groupadd -g "$DEVBOX_RUNTIME_GID" "$DEV_USER"
  # -M: home already exists on the bind; -p '*': no usable password and not
  # a locked account (locked '!' would make sshd refuse pubkey logins with
  # UsePAM no).
  useradd -M -u "$DEVBOX_RUNTIME_UID" -g "$DEVBOX_RUNTIME_GID" \
    -d "$HOME_DIR" -s /bin/bash -p '*' "$DEV_USER" \
    || die "useradd $DEV_USER failed"
fi

# Writability of user areas and denial of system/services, tested as the
# real user (catches ro mounts and loosened modes, not just stat bits).
runuser -u "$DEV_USER" -- test -w "$HOME_DIR" || die "$DEV_USER cannot write $HOME_DIR"
runuser -u "$DEV_USER" -- test -w "$WORKSPACES_DIR" || die "$DEV_USER cannot write $WORKSPACES_DIR"

# The central list must be readable AS DEV: OpenSSH reads it under the
# target user's identity, so a root-readable-only file is exactly the
# reject-every-login failure this layout exists to prevent. Fail the
# start loudly instead of letting sshd come up broken.
runuser -u "$DEV_USER" -- test -r "$AUTHORIZED_KEYS" \
  || die "$DEV_USER cannot read $AUTHORIZED_KEYS; sshd would reject every login"

# denial_check <name> <flag> <dir>: exit 0 of `test <flag> <dir>` as dev
# means the denial is broken; exit 1 means denied (expected); anything else
# is an unexpected probe failure and must not read as "denied".
denial_check() {
  local what=$1 flag=$2 dir=$3 rc
  if runuser -u "$DEV_USER" -- test "$flag" "$dir" 2> /dev/null; then rc=0; else rc=$?; fi
  case "$rc" in
    0) die "$DEV_USER can $what $dir (permissions loosened)" ;;
    1) log "denied as expected: $DEV_USER cannot $what $dir" ;;
    *) die "traversal probe for $dir exited unexpectedly ($rc); refusing to treat as denied" ;;
  esac
}
denial_check read      -r "$SYSTEM_DIR"
denial_check traverse  -x "$SYSTEM_DIR"
denial_check read      -r "$SERVICES_DIR"
denial_check traverse  -x "$SERVICES_DIR"
# The central trust path must stay unwritable by dev (root:root 0755).
denial_check write     -w "$AUTH_DIR"

# ---------------------------------------------------------------------------
# Phase 5 — config test, then foreground sshd.
# ---------------------------------------------------------------------------

# sshd privilege separation dir: fail-closed, idempotent, NON-recursive
# guarded create (auth-path fix 2). A restart of the same container finds
# /run/sshd already present (same writable layer), so an unconditional
# mkdir dies on EEXIST; the create runs only when the path is absent.
# Symlink first: [ -e ]/[ -d ]/stat follow links, so a link must be
# refused before the type and owner/mode checks. The root:root 0755
# assertion after the branch is unconditional — known-present and
# just-created states alike.
if [ -e "/run/sshd" ] || [ -L "/run/sshd" ]; then
  [ ! -L "/run/sshd" ] || die "/run/sshd is a symlink; symlinks on the sshd runtime path are refused"
  [ -d "/run/sshd" ] || die "/run/sshd exists but is not a directory"
else
  mkdir /run/sshd || die "cannot create /run/sshd (privilege separation dir)"
  chown 0:0 "/run/sshd"
  chmod 0755 "/run/sshd"
fi
check_mode_owner "/run/sshd" 0 0 755
sshd -t || die "sshd -t failed (config/host keys rejected)"

log "starting sshd -D -e"
exec /usr/sbin/sshd -D -e
