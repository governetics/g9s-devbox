#!/bin/bash
# g9s-devbox host-prep (P1). Run ON THE HOST as root BEFORE `compose up`.
#
# Creates (idempotently) and verifies only the TOP roots of the persistent
# state tree with the agreed owners/modes (D-002 (a)):
#
#   DEVBOX_HOST_PATH            root:root      0755
#   ├── home/                   UID:GID        0750
#   ├── workspaces/             UID:GID        0750
#   ├── system/                 root:root      0700   (marker + host keys live here)
#   └── services/               root:root      0700   (P3 file services, created now)
#
# Hard limits of this script:
#   - never creates the identity marker (the container entrypoint owns it);
#   - never touches anything below the top roots (no recursive chown/chmod);
#   - never deletes anything;
#   - refuses symlinks anywhere on the path, non-absolute paths, system
#     roots, and an unknown non-empty tree;
#   - tree inspection is fail-closed and newline-safe: a missing or
#     failing find(1) — or any top-level name outside home/workspaces/
#     system/services/lost+found — refuses BEFORE any mutation (GNU find
#     -printf is the Debian contract);
#   - with NO marker present, every existing top root (home/workspaces/
#     system/services) must be EMPTY — nested content, dotfiles included —
#     or the script refuses BEFORE any create/chown/chmod happens (zero
#     mutations on refusal);
#   - the marker is accepted only as a regular non-symlink root:root 0600
#     file; any damage (type/owner/mode) is a refusal, and its
#     schema/UID/GID must match the arguments, otherwise the script refuses.
#
# Usage: host-prep.sh --path /var/lib/devbox --uid 1000 --gid 1000
# Exit codes: 0 prepared/verified; 1 refused (state/permission problem);
# 2 usage error.

set -uo pipefail

log()  { echo "host-prep: $*"; }
err()  { echo "host-prep: FATAL: $*" >&2; }
die()  { err "$*"; exit 1; }
usage(){ err "usage: $0 --path <absolute-dir> --uid <numeric> --gid <numeric>"; exit 2; }

SCHEMA_VERSION=1

# --------------------------------------------------------------------------
# Arguments.
# --------------------------------------------------------------------------
PATH_ARG= UID_ARG= GID_ARG=
while [ $# -gt 0 ]; do
  case "$1" in
    --path) [ $# -ge 2 ] || usage; PATH_ARG=$2; shift 2 ;;
    --uid)  [ $# -ge 2 ] || usage; UID_ARG=$2;  shift 2 ;;
    --gid)  [ $# -ge 2 ] || usage; GID_ARG=$2;  shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$PATH_ARG" ] && [ -n "$UID_ARG" ] && [ -n "$GID_ARG" ] || usage
case "$UID_ARG" in ''|*[!0-9]*) die "--uid must be numeric, got '$UID_ARG'";; esac
case "$GID_ARG" in ''|*[!0-9]*) die "--gid must be numeric, got '$GID_ARG'";; esac
[ "$UID_ARG" -ge 1 ] || die "--uid must be >= 1 (dev is non-root)"
[ "$GID_ARG" -ge 1 ] || die "--gid must be >= 1"

# --------------------------------------------------------------------------
# Environment and path safety.
# --------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0 ...)"
[ "$(uname -s)" = "Linux" ] || die "host-prep proves ownership only on Linux; refusing to run on $(uname -s) (macOS/Docker Desktop results do not count, implementation-plan P1)"
command -v find > /dev/null 2>&1 || die "find(1) not found; tree-state verification is impossible (fail-closed refusal)"

case "$PATH_ARG" in
  /*) ;;
  *) die "path must be absolute, got '$PATH_ARG'" ;;
esac

# Reject '.', '..' and '//' components without relying on realpath.
normalized=/
rest=${PATH_ARG#/}
while :; do
  component=${rest%%/*}
  if [ "$rest" = "$component" ]; then rest=; else rest=${rest#*/}; fi
  case "$component" in
    ''|.|..) die "path '$PATH_ARG' contains an empty/'.'/'..' component" ;;
  esac
  normalized=$normalized$component
  [ -n "$rest" ] || break
  normalized=$normalized/
done

# Depth: at least /parent/name; the exact critical roots are refused.
case "$normalized" in
  /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/var/log)
    die "refusing to operate on system root '$normalized'" ;;
esac

# No symlinks anywhere along the existing prefix of the path.
probe=$normalized
while [ "$probe" != / ]; do
  if [ -L "$probe" ]; then die "'$probe' is a symlink; symlinks on the state path are refused"; fi
  if [ -e "$probe" ]; then
    [ -d "$probe" ] || die "'$probe' exists and is not a directory"
    break # deepest existing ancestor; parents above are real dirs by walk
  fi
  probe=$(dirname "$probe")
done
# re-walk for full coverage (the loop above stops at the deepest existing
# ancestor; ancestors above it are checked here)
probe=$(dirname "$normalized")
while [ "$probe" != / ]; do
  [ -L "$probe" ] && die "'$probe' is a symlink; symlinks on the state path are refused"
  probe=$(dirname "$probe")
done

ROOT=$normalized
log "target root: $ROOT (uid/gid $UID_ARG/$GID_ARG)"

# --------------------------------------------------------------------------
# Unknown non-empty state check (before creating anything). Fail-closed and
# newline-safe: the allowed-name decision is made BY find itself (a fixed
# -printf marker per matching entry, -quit after the first), so entry names
# — newlines, leading dashes, empty-looking names — never feed shell
# parsing; any nonzero find rc is FATAL here, before the mutation section.
# GNU find (-printf) is the Debian/Linux contract; a find without -printf
# errors nonzero and dies in the same gate.
# --------------------------------------------------------------------------
if [ -d "$ROOT" ]; then
  top_rc=0
  top_mark=$(find "$ROOT" -mindepth 1 -maxdepth 1 \
               ! -name home ! -name workspaces ! -name system \
               ! -name services ! -name lost+found \
               -printf 'unexpected-entry\n' -quit) || top_rc=$?
  [ "$top_rc" -eq 0 ] || die "find failed under '$ROOT' (rc=$top_rc); cannot verify tree state; refusing before any mutation"
  if [ "$top_mark" = "unexpected-entry" ]; then
    die "unknown non-empty state: an entry other than home/workspaces/system/services/lost+found exists under $ROOT; refusing (adoption is an explicit operator decision)"
  fi
elif [ -e "$ROOT" ]; then
  die "'$ROOT' exists and is not a directory"
fi

# --------------------------------------------------------------------------
# State analysis, all read-only: marker read-back (never created here) and,
# when NO marker exists, nested-emptiness verification of the four top
# roots. Any refusal here happens BEFORE the mutation section below, so a
# refused run performs zero create/chown/chmod operations.
# --------------------------------------------------------------------------
MARKER=$ROOT/system/identity
if [ -e "$MARKER" ]; then
  # The marker is valid only as a regular, non-symlink, root:root 0600
  # file. Damage is a refusal, never something this script "fixes".
  [ ! -L "$MARKER" ] || die "marker '$MARKER' is a symlink; refusing"
  [ -f "$MARKER" ] || die "marker '$MARKER' is not a regular file; refusing"
  marker_stat=$(stat -c '%u %g %a' "$MARKER")
  [ "$marker_stat" = "0 0 600" ] || die "marker '$MARKER' has owner/mode '$marker_stat', expected '0 0 600' (damaged marker); refusing"
  m_schema= m_uid= m_gid=
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      schema=*|uid=*|gid=*) ;;
      *) die "marker 'system/identity' has unknown content '$line'" ;;
    esac
    key=${line%%=*}; value=${line#*=}
    case "$value" in ''|*[!0-9]*) die "marker 'system/identity' has non-numeric value '$line'" ;; esac
    case "$key" in
      schema) [ -z "$m_schema" ] || die "marker has duplicate key '$key'"; m_schema=$value ;;
      uid)    [ -z "$m_uid" ]    || die "marker has duplicate key '$key'"; m_uid=$value ;;
      gid)    [ -z "$m_gid" ]    || die "marker has duplicate key '$key'"; m_gid=$value ;;
    esac
  done < "$MARKER"
  [ -n "$m_schema" ] && [ -n "$m_uid" ] && [ -n "$m_gid" ] || die "marker 'system/identity' is missing schema/uid/gid"
  [ "$m_schema" = "$SCHEMA_VERSION" ] || die "marker schema $m_schema != supported $SCHEMA_VERSION (explicit migration required)"
  [ "$m_uid" = "$UID_ARG" ] || die "marker uid $m_uid != --uid $UID_ARG (explicit migration required)"
  [ "$m_gid" = "$GID_ARG" ] || die "marker gid $m_gid != --gid $GID_ARG (explicit migration required)"
  log "identity marker verified: schema $m_schema, uid/gid $m_uid/$m_gid"
else
  log "no identity marker (empty first boot will create it inside the container)"
  # Without a marker this tree is unknown: bootstrap may only happen on a
  # fully prepared EMPTY tree. Every EXISTING top root must be empty —
  # nested content, dotfiles included. Fail-closed: presence is proven by a
  # fixed -printf marker, never by the entry name (a newline-only name is
  # still content), and any nonzero find rc is FATAL here. Refusal in this
  # loop precedes every create/chown/chmod below.
  for d in home workspaces system services; do
    dir=$ROOT/$d
    [ -e "$dir" ] || continue
    [ -d "$dir" ] || die "'$dir' exists and is not a directory; refusing"
    nested_rc=0
    nested_mark=$(find "$dir" -mindepth 1 -printf 'nested-content\n' -quit) || nested_rc=$?
    [ "$nested_rc" -eq 0 ] || die "find failed under '$dir' (rc=$nested_rc); cannot verify emptiness; refusing before any mutation"
    if [ "$nested_mark" = "nested-content" ]; then
      die "unknown non-empty state: '$dir' is not empty (nested content, dotfiles included) and no identity marker exists; refusing before any mutation (adoption is an explicit operator decision)"
    fi
  done
fi

# --------------------------------------------------------------------------
# Idempotent create/verify of the top roots only. Corrections are
# non-recursive and logged; nothing below these directories is touched.
# --------------------------------------------------------------------------
ensure_dir() { # ensure_dir <dir> <owner-uid> <owner-gid> <mode>
  local dir=$1 ouid=$2 ogid=$3 mode=$4 actual
  if [ ! -d "$dir" ]; then
    [ ! -e "$dir" ] || die "'$dir' exists and is not a directory"
    mkdir "$dir" || die "cannot create $dir"
    chown "$ouid:$ogid" "$dir" || die "chown failed on $dir"
    chmod "$mode" "$dir" || die "chmod failed on $dir"
    log "created $dir ($ouid:$ogid $mode)"
    return
  fi
  [ -L "$dir" ] && die "'$dir' is a symlink"
  actual=$(stat -c '%u %g %a' "$dir")
  if [ "$actual" != "$ouid $ogid $mode" ]; then
    chown "$ouid:$ogid" "$dir" || die "chown failed on $dir"
    chmod "$mode" "$dir" || die "chmod failed on $dir"
    log "adjusted $dir: '$actual' -> '$ouid $ogid $mode' (non-recursive)"
  else
    log "ok $dir ($ouid:$ogid $mode)"
  fi
}

ensure_dir "$ROOT"                 0      0      755
ensure_dir "$ROOT/home"            "$UID_ARG" "$GID_ARG" 750
ensure_dir "$ROOT/workspaces"      "$UID_ARG" "$GID_ARG" 750
ensure_dir "$ROOT/system"          0      0      700
ensure_dir "$ROOT/services"        0      0      700

log "done. Next: docker compose --env-file .env -f deploy/compose.yml up -d"
exit 0
