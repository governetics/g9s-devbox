#!/bin/bash
# g9s-devbox P1 client-side probe. Runs FROM A CLIENT MACHINE against the
# published SSH endpoint and proves the P1 local-core claims that are
# observable from outside (P1-4/P1-5/P1-6 of the session declaration):
#
#   - real SSH login as the unprivileged user works (key-only);
#   - OpenSSH SFTP put/get/rename round-trip works;
#   - root login is DENIED; the server does not OFFER password or
#     keyboard-interactive authentication (proved by the server's own
#     "Authentications that can continue:" list in `ssh -vv` output);
#   - reading /var/lib/devbox/system/ is DENIED (shell and SFTP);
#   - /var/run/docker.sock is absent; no host-home mount points exist
#     inside the container (mount point = FIELD 2 of /proc/mounts, exact
#     /home, /Users and descendants — no regex trailing hole).
#
# Modes:
#   default           full battery above (requires a WORKING key);
#   --expect-denied   single-probe mode for a key that must NOT log in
#                     (revoked key, or the home-bypass check after
#                     revocation): an explicit "Permission denied
#                     (publickey)" from the server = PASS; a successful
#                     login = FAIL; anything else (network, host-key or
#                     tool problem, unclear refusal) = NOT PROVEN. No
#                     successful reachability precheck is required in this
#                     mode — the probe itself is the reachability test.
#
# Verdict discipline: a negative probe unexpectedly succeeding is a FAIL
# (exit 1). An unreachable target or a missing client tool is NOT PROVEN
# (exit 2), never silently green. All artifacts live in a private temp dir
# and in uniquely named remote files; cleanup removes ONLY the probe's own
# temp dir and tag-prefixed remote files. The script contains no secrets
# and no operator-specific paths; everything comes from flags.
#
# Self-test hook (no network): --selftest-auth-methods reads a SYNTHETIC
# fixture from stdin — line 1: the ssh exit status; the rest: `ssh -vv`
# output — and prints the shared classifier verdict (PASS/FAIL/NOT-PROVEN;
# exit 0/1/2). This is a behavioral control of the classifier on synthetic
# data — it is NOT a claim about a real password-enabled sshd; the
# server-side proof is the manager's Linux run.
#
# Usage: p1-client-probe.sh --target <host> --port <port> --identity <key>
#        [--user dev] [--expect-denied]
# Exit codes: 0 all probes passed; 1 at least one probe FAILED; 2 NOT PROVEN
# (environment/usage problem).

set -uo pipefail

TARGET= PORT=22 IDENTITY= REMOTE_USER=dev EXPECT_DENIED=0 SELFTEST_AUTH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   [ $# -ge 2 ] || exit 2; TARGET=$2;   shift 2 ;;
    --port)     [ $# -ge 2 ] || exit 2; PORT=$2;     shift 2 ;;
    --identity) [ $# -ge 2 ] || exit 2; IDENTITY=$2; shift 2 ;;
    --user)     [ $# -ge 2 ] || exit 2; REMOTE_USER=$2; shift 2 ;;
    --expect-denied) EXPECT_DENIED=1; shift ;;
    --selftest-auth-methods) SELFTEST_AUTH=1; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# judge_auth_methods <text>: classify the server's authentication offers
# from "Authentications that can continue:" lines of `ssh -vv` output.
# Only the FULL expected OpenSSH debug format is evidence:
#   ^debug[0-9]+: Authentications that can continue: [a-z0-9,-]+$
# (CRLF is normalized first). notice:/prefixed/banner-like/malformed
# pseudo-lists are not proof of anything. Echoes PASS / FAIL / NOT-PROVEN
# and returns 0 / 1 / 2.
#   PASS        a proven server list offers publickey and neither password
#               nor keyboard-interactive appears in any proven list;
#   FAIL        some proven server list offers password or
#               keyboard-interactive;
#   NOT-PROVEN  no valid continuation list at all (network/tool problem,
#               or only malformed pseudo-lists) — never a silent pass.
judge_auth_methods() {
  local text=$1 list line methods bad=0 pk=0
  list=$(printf '%s\n' "$text" | tr -d '\r' \
         | grep -E '^debug[0-9]+: Authentications that can continue: [a-z0-9,-]+$' || true)
  if [ -z "$list" ]; then echo NOT-PROVEN; return 2; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    methods=${line##*Authentications that can continue:}
    methods=$(printf '%s' "$methods" | tr -d ' ')
    [ -n "$methods" ] || continue
    case ",$methods," in
      *,password,*|*,keyboard-interactive,*) bad=1 ;;
    esac
    case ",$methods," in
      *,publickey,*) pk=1 ;;
    esac
  done <<< "$list"
  if [ "$bad" -eq 1 ]; then echo FAIL; return 1; fi
  if [ "$pk" -eq 1 ]; then echo PASS; return 0; fi
  echo FAIL; return 1
}

# classify_auth_probe <rc> <text>: the ONE classifier of a password-only
# `ssh -vv` attempt, shared by the live probe below and the
# --selftest-auth-methods behavioral controls. rc=0 means the attempt
# LOGGED IN — an unexpected success is a FAIL no matter what the output
# contains (a publickey continuation list beside a successful login still
# means the auth surface is wider than the contract). Only the output of a
# NONZERO-rc attempt reaches the auth-list judge.
classify_auth_probe() {
  local rc=$1
  if [ "$rc" -eq 0 ]; then echo FAIL; return 1; fi
  judge_auth_methods "$2"
}

# --- Self-test mode: classifier control on a synthetic fixture. ------------
# stdin contract: line 1 = the ssh exit status, the rest = ssh -vv output.
if [ "$SELFTEST_AUTH" = 1 ]; then
  [ "$EXPECT_DENIED" = 0 ] || { echo "--selftest-auth-methods cannot be combined with --expect-denied" >&2; exit 2; }
  selftest_input=$(cat)
  case "$selftest_input" in
    *$'\n'*) ;;
    *) echo "--selftest-auth-methods input: line 1 must be the ssh exit status, then the ssh -vv output" >&2; exit 2 ;;
  esac
  selftest_rc=${selftest_input%%$'\n'*}
  selftest_text=${selftest_input#*$'\n'}
  case "$selftest_rc" in ''|*[!0-9]*) echo "--selftest-auth-methods: line 1 must be a numeric ssh exit status, got '$selftest_rc'" >&2; exit 2 ;; esac
  selftest_verdict_rc=0
  selftest_verdict=$(classify_auth_probe "$selftest_rc" "$selftest_text") || selftest_verdict_rc=$?
  echo "[SELFTEST-auth-methods] $selftest_verdict"
  exit "$selftest_verdict_rc"
fi

[ -n "$TARGET" ] && [ -n "$IDENTITY" ] || { echo "usage: $0 --target <host> --port <port> --identity <key> [--user dev] [--expect-denied]" >&2; exit 2; }
case "$PORT" in ''|*[!0-9]*) echo "--port must be numeric" >&2; exit 2 ;; esac
command -v ssh  > /dev/null 2>&1 || { echo "ssh client not found" >&2; exit 2; }
command -v sftp > /dev/null 2>&1 || { echo "sftp client not found" >&2; exit 2; }
[ -f "$IDENTITY" ] || { echo "identity file '$IDENTITY' not found" >&2; exit 2; }

WORKDIR=$(mktemp -d /tmp/g9s-devbox-p1-probe.XXXXXX) || exit 2
KNOWN_HOSTS=$WORKDIR/known_hosts
REMOTE_TAG="p1-probe-$(date +%Y%m%d%H%M%S)-$$"
PASS_COUNT=0 FAIL_COUNT=0 ERROR_COUNT=0
cleanup() {
  # Best-effort removal of OUR remote artifacts only (tag-prefixed files);
  # nothing else on the remote side is touched.
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$IDENTITY" -p "$PORT" \
      "$REMOTE_USER@$TARGET" "rm -f \"$REMOTE_TAG-put\" \"$REMOTE_TAG-renamed\" \"$REMOTE_TAG-get\"" \
      > /dev/null 2>&1
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$IDENTITY" -p "$PORT")

pass() { PASS_COUNT=$((PASS_COUNT + 1));  echo "[PASS] $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1));  echo "[FAIL] $*"; }
probe_err() { ERROR_COUNT=$((ERROR_COUNT + 1)); echo "[NOT-PROVEN] $*"; }

summarize() {
  local total
  total=$((PASS_COUNT + FAIL_COUNT + ERROR_COUNT))
  echo "----"
  echo "p1-client-probe: $PASS_COUNT passed, $FAIL_COUNT failed, $ERROR_COUNT not-proven (of $total) against $REMOTE_USER@$TARGET:$PORT (expect-denied=$EXPECT_DENIED)"
  if [ "$FAIL_COUNT" -gt 0 ]; then exit 1; fi
  if [ "$ERROR_COUNT" -gt 0 ]; then exit 2; fi
  exit 0
}

# expect_deny <name> <command...>: the command must fail with an auth/
# permission denial in the output (a network error is NOT a denial).
expect_deny() {
  local name=$1; shift
  if out=$("$@" 2>&1); then
    fail "$name — unexpectedly SUCCEEDED: $out"
  else
    case "$out" in
      *[Dd]enied*|*[Pp]ermission*) pass "$name — denied as expected" ;;
      *) probe_err "$name — failed without a denial message (network?): $out" ;;
    esac
  fi
}
# expect_output <name> <expected> <command...>: command succeeds and its
# output equals <expected> exactly.
expect_output() {
  local name=$1 expected=$2; shift 2
  if out=$("$@" 2>&1); then
    if [ "$out" = "$expected" ]; then pass "$name"; else fail "$name — output '$out' != '$expected'"; fi
  else
    fail "$name — exited $? : $out"
  fi
}

# --- expect-denied mode: one proof that this key must NOT log in. ----------
if [ "$EXPECT_DENIED" = 1 ]; then
  if out=$(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET" 'id' 2>&1); then
    fail "denied-key login — unexpectedly SUCCEEDED (key still authorized, or home-bypass): $out"
  else
    case "$out" in
      *"Permission denied (publickey)"*)
        pass "denied-key login — explicit 'Permission denied (publickey)' from the server" ;;
      *)
        probe_err "denied-key login — no explicit publickey denial (network/host-key/tool problem?): $out" ;;
    esac
  fi
  summarize
fi

# --- Reachability: without it nothing below is proven. ---------------------
if ! ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET" 'echo reachable' > /dev/null 2>&1; then
  echo "NOT PROVEN: cannot reach $REMOTE_USER@$TARGET:$PORT with $IDENTITY (SSH precheck failed)" >&2
  exit 2
fi

# --- P1-5: real SSH login, non-root identity. -------------------------------
id_out=$(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET" 'id' 2>&1)
case "$id_out" in
  uid=0\(*|uid=-*) fail "id — unexpected identity: $id_out" ;;
  uid=[1-9]*"($REMOTE_USER)") pass "id — non-root login as $REMOTE_USER: $id_out" ;;
  *) fail "id — unexpected output: $id_out" ;;
esac

# --- P1-5: SFTP put/get/rename round-trip. ----------------------------------
payload="$WORKDIR/payload.txt"
printf 'g9s-devbox p1 client probe %s\n' "$REMOTE_TAG" > "$payload"
batch_put=$WORKDIR/sftp-put.batch
cat > "$batch_put" <<EOF
put "$payload" "$REMOTE_TAG-put"
rename "$REMOTE_TAG-put" "$REMOTE_TAG-renamed"
get "$REMOTE_TAG-renamed" "$WORKDIR/$REMOTE_TAG-get"
EOF
if out=$(sftp -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
             -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$IDENTITY" -P "$PORT" \
             -b "$batch_put" "$REMOTE_USER@$TARGET" 2>&1); then
  if cmp -s "$payload" "$WORKDIR/$REMOTE_TAG-get"; then
    pass "sftp put/rename/get round-trip — byte-identical readback"
  else
    fail "sftp round-trip — readback differs from payload"
  fi
else
  fail "sftp round-trip — sftp batch failed: $out"
fi

# --- P1-4/P1-5: root login denied. ------------------------------------------
expect_deny "root login denied" \
  ssh "${SSH_OPTS[@]}" "root@$TARGET" 'id'

# --- P1-4/P1-5: the server must not OFFER password authentication. ----------
# Evidence = the server's own "Authentications that can continue:" list
# from `ssh -vv` output (password-only preference, no key offered, zero
# password prompts, batch mode so nothing hangs). The shared classifier
# classify_auth_probe sees rc + text: the attempt's rc is taken FIRST, and
# rc=0 means the password-pref attempt LOGGED IN — an unconditional FAIL
# even when the output also contains a publickey list. For nonzero rc,
# PASS only on a proven debug-format list that offers publickey and never
# password/keyboard-interactive; password or keyboard-interactive anywhere
# in a proven list = FAIL; no valid list at all (network/tool problem,
# malformed pseudo-lists) = NOT PROVEN, never a silent green. The
# classifier is behaviorally controlled on SYNTHETIC fixtures via
# --selftest-auth-methods (tests/test_p1.py); those controls exercise the
# classifier only and are NOT a real password-enabled sshd — the
# server-side proof is the manager's Linux run.
password_rc=0
password_out=$(ssh -vv -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" -p "$PORT" \
    -o PubkeyAuthentication=no -o PreferredAuthentications=password \
    -o NumberOfPasswordPrompts=0 \
    "$REMOTE_USER@$TARGET" 'id' 2>&1) || password_rc=$?
password_class_rc=0
password_verdict=$(classify_auth_probe "$password_rc" "$password_out") || password_class_rc=$?
case "$password_class_rc" in
  0) pass "password auth not offered — proven server auth list is publickey-only" ;;
  1) if [ "$password_rc" -eq 0 ]; then
       fail "password-pref ssh attempt SUCCEEDED (rc=0) — server accepted a non-publickey login (auth surface wider than the P1 contract): $password_out"
     else
       fail "server OFFERS password/keyboard-interactive authentication (auth surface wider than the P1 contract)"
     fi ;;
  *) probe_err "password denial NOT PROVEN — no valid server auth list in ssh -vv output (network/tool problem)" ;;
esac

# --- P1-5: system/ is unreadable via shell AND via SFTP. --------------------
expect_deny "system/ read via shell denied" \
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET" 'cat /var/lib/devbox/system/authorized_keys'
expect_deny "system/ listing via shell denied" \
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET" 'ls /var/lib/devbox/system'
batch_ls=$WORKDIR/sftp-ls.batch
echo "ls /var/lib/devbox/system" > "$batch_ls"
expect_deny "system/ listing via SFTP denied" \
  sftp -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
       -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$IDENTITY" -P "$PORT" \
       -b "$batch_ls" "$REMOTE_USER@$TARGET"

# --- P1-5: no docker socket, no host-home mount points. ---------------------
expect_output "docker.sock absent" "absent" \
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET" \
  'if [ -e /var/run/docker.sock ]; then echo present; else echo absent; fi'

# Mount points are parsed as FIELD 2 of each /proc/mounts line and matched
# by glob: exactly /home, /Users and their descendants. Field extraction,
# not a regex over whole lines — a bare "/home" (no trailing slash) is
# caught too, and device/fstype fields can never produce a false match.
if mounts_raw=$(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET" 'cat /proc/mounts' 2>&1); then
  host_home_mounts=
  while IFS= read -r mline; do
    [ -n "$mline" ] || continue
    mp=${mline#* }; mp=${mp%% *}
    case "$mp" in
      /home|/home/*|/Users|/Users/*) host_home_mounts="$host_home_mounts $mp" ;;
    esac
  done <<< "$mounts_raw"
  if [ -n "$host_home_mounts" ]; then
    fail "host-home mount points present:$host_home_mounts"
  else
    pass "no host-home (/home, /Users) mount points"
  fi
else
  probe_err "mount audit — could not read remote /proc/mounts: $mounts_raw"
fi

summarize
