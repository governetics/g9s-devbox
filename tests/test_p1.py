#!/usr/bin/env python3
"""g9s-devbox P1 test suite (stdlib only).

Three kinds of checks, kept explicitly apart:

1. TEXTUAL PINS — string/regex assertions on the contract files. A textual
   pin proves the file carries the agreed contract wording, nothing more;
   it is NOT a runtime proof. Each checker is a pure function over file
   text so that mutation self-tests can prove the checkers are sensitive
   (a mutated file must be rejected).
2. MUTATION SELF-TESTS — in-memory negative/mutation tests: every textual
   checker must fail on a deliberately broken variant of the real file.
   The suite counts every executed (and rejecting) control and prints the
   count in its summary; attestations cite that number from the log, never
   a hand count.
3. BEHAVIORAL — `docker compose config` runs (valid / missing / empty /
   multiline env) and `bash -n` syntax checks. These need local tools; when
   a tool is absent the check reports NOT PROVEN (exit code 3), never a
   silent green.

Honesty contract: this suite never claims runtime properties (SSH login,
host-prep ownership, container start). Those are proven on the Linux node
by the manager's probe run; see docs/runbooks/p1-local-core.md.

Exit codes: 0 = all green; 1 = failures; 3 = at least one NOT PROVEN and
no failures.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEBIAN_DIGEST = ("debian:13-slim@sha256:"
                 "a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2")

PACKAGE_PINS = [
    "openssh-server=1:10.0p1-7+deb13u4",
    "openssh-client=1:10.0p1-7+deb13u4",
    "tini=0.19.0-3+b8",
    "git=1:2.47.3-0+deb13u1",
    "curl=8.14.1-2+deb13u7",
    "ca-certificates=20250419+deb13u1",
    "iproute2=6.15.0-1",
    "libstdc++6=14.2.0-19",
]

COMPOSE_KEYS = [
    "DEVBOX_HOST_PATH",
    "DEVBOX_UID",
    "DEVBOX_GID",
    "DEVBOX_AUTHORIZED_KEYS",
    "DEVBOX_SSH_BIND",
    "DEVBOX_SSH_PORT",
    "DEVBOX_CPU_LIMIT",
    "DEVBOX_MEMORY_LIMIT",
    "DEVBOX_PIDS_LIMIT",
]

FAKE_KEYS = ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeTestKeyOneForComposeProbe p1-macbook\n"
             "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeTestKeyTwoForComposeProbe p1-minipc")

VALID_ENV = {
    "DEVBOX_HOST_PATH": "/var/lib/devbox",
    "DEVBOX_UID": "1000",
    "DEVBOX_GID": "1000",
    "DEVBOX_AUTHORIZED_KEYS": FAKE_KEYS,
    "DEVBOX_SSH_BIND": "10.0.0.100",
    "DEVBOX_SSH_PORT": "2222",
    "DEVBOX_CPU_LIMIT": "6.0",
    "DEVBOX_MEMORY_LIMIT": "6656m",
    "DEVBOX_PIDS_LIMIT": "1024",
}


def read(rel):
    with open(os.path.join(REPO_ROOT, rel), "r", encoding="utf-8") as fh:
        return fh.read()


def strip_comments(text):
    """Drop full-line comments so pins do not match comment prose."""
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def scan_recursive_delete_flags(stripped, rules):
    """Token-level scan for forbidden recursive/delete mutation flags.

    rules: {command: (short_letters, long_flags)}. Every token standing
    AFTER the command name on the same line is checked: a short-flag
    cluster (-R, -Rh, -rf, split -r -f, flags positioned after arguments)
    carrying one of short_letters, or one of long_flags, is reported.
    Catches combined/split/positioned variants that plain substring pins
    miss. Textual only — behavior is proven by the Linux run.
    """
    problems = []
    for line in stripped.splitlines():
        tokens = line.split()
        for i, tok in enumerate(tokens):
            name = tok.lstrip("$({;|&").rstrip(";,").split("/")[-1].strip("\"'")
            if name not in rules:
                continue
            shorts, longs = rules[name]
            for t in tokens[i + 1:]:
                tt = t.strip("\"'").rstrip(";,")
                if tt.startswith("--"):
                    if tt.split("=", 1)[0] in longs:
                        problems.append("%s carries forbidden flag '%s'" % (name, tt))
                elif len(tt) > 1 and tt.startswith("-"):
                    if any(c in shorts for c in tt[1:]):
                        problems.append("%s carries forbidden short flag '%s'" % (name, tt))
    return problems


# ---------------------------------------------------------------------------
# Textual checkers. Each returns a list of problems (empty list = pinned).
# ---------------------------------------------------------------------------

def check_dockerfile(text):
    problems = []
    stripped = strip_comments(text)
    if DEBIAN_DIGEST not in stripped:
        problems.append("base image is not the agreed pinned digest")
    for pin in PACKAGE_PINS:
        if pin not in stripped:
            problems.append("missing package pin: %s" % pin)
    if 'ENTRYPOINT ["/usr/bin/tini", "-g", "--"' not in stripped:
        problems.append("PID 1 is not tini -g via ENTRYPOINT")
    lowered = stripped.lower()
    for forbidden in ("vscode", "vs-code", "sftpgo", "samba", "supervisor",
                      "systemd", "code-server", "opencode"):
        if forbidden in lowered:
            problems.append("image must not contain %s (P1 is local core only)" % forbidden)
    if re.search(r"^USER\s", stripped, re.M):
        problems.append("image must keep running as root (bootstrap + sshd)")
    return problems


def check_compose(text):
    problems = []
    stripped = strip_comments(text)
    # One service only (scope the search to the block after 'services:').
    head, _, services_block = stripped.partition("\nservices:")
    services = re.findall(r"^  ([A-Za-z0-9][A-Za-z0-9_-]*):$", services_block, re.M)
    if services != ["devbox"]:
        problems.append("compose must contain exactly one service 'devbox', got %r" % services)
    # No named volumes in any form.
    if "type: volume" in stripped:
        problems.append("named volume (type: volume) present")
    if re.search(r"^volumes:", stripped, re.M):
        problems.append("top-level volumes section present (named volumes)")
    # The single long bind.
    if "create_host_path: false" not in stripped:
        problems.append("bind is missing create_host_path: false")
    if "target: /var/lib/devbox" not in stripped:
        problems.append("bind target is not /var/lib/devbox")
    if stripped.count("type: bind") != 1:
        problems.append("expected exactly one bind mount")
    # The only published endpoint.
    port_lines = re.findall(r'- "\$\{DEVBOX_SSH_BIND:\?[^}]*\}:\$\{DEVBOX_SSH_PORT:\?[^}]*\}:22"', stripped)
    if len(port_lines) != 1:
        problems.append("expected exactly one SSH port line bind:port:22, got %d" % len(port_lines))
    # Exploitation contract.
    if "restart: unless-stopped" not in stripped:
        problems.append("restart policy is not unless-stopped")
    if "stop_grace_period: 30s" not in stripped:
        problems.append("stop_grace_period is not 30s")
    for frag in ("interval: 30s", "timeout: 5s", "retries: 3", "start_period: 15s",
                 "driver: json-file", 'max-size: "10m"', 'max-file: "3"'):
        if frag not in stripped:
            problems.append("missing exploitation fragment: %s" % frag)
    # Runtime env mapping must not shadow panel env_file names.
    for mapping in (
        'DEVBOX_RUNTIME_UID: "${DEVBOX_UID:?DEVBOX_UID is not set}"',
        'DEVBOX_RUNTIME_GID: "${DEVBOX_GID:?DEVBOX_GID is not set}"',
        'DEVBOX_RUNTIME_AUTHORIZED_KEYS: "${DEVBOX_AUTHORIZED_KEYS:?DEVBOX_AUTHORIZED_KEYS is not set}"',
        'cpus: ${DEVBOX_CPU_LIMIT:?DEVBOX_CPU_LIMIT is not set}',
        'memory: ${DEVBOX_MEMORY_LIMIT:?DEVBOX_MEMORY_LIMIT is not set}',
        'pids: ${DEVBOX_PIDS_LIMIT:?DEVBOX_PIDS_LIMIT is not set}',
    ):
        if mapping not in stripped:
            problems.append("missing mapping: %s" % mapping)
    # x-g9s-config: declared keys == expected, every key consumed, every
    # substitution declared.
    block = re.search(r"x-g9s-config:\n(.*?)\n\nservices:", stripped, re.S)
    if not block:
        problems.append("x-g9s-config block not found before services:")
        return problems
    declared = re.findall(r"^    ([A-Z][A-Z0-9_]*): \{consumers: \[devbox\]", block.group(1), re.M)
    if sorted(declared) != sorted(COMPOSE_KEYS):
        problems.append("x-g9s-config keys != expected set: %r" % sorted(declared))
    substituted = re.findall(r"\$\{([A-Z][A-Z0-9_]*):", stripped)
    for var in substituted:
        if var not in COMPOSE_KEYS:
            problems.append("substitution ${%s:?} is not a declared x-g9s-config key" % var)
    for key in COMPOSE_KEYS:
        if key not in substituted:
            problems.append("declared key %s has no ${KEY:?} substitution" % key)
    return problems


def check_sshd(text):
    problems = []
    stripped = strip_comments(text)
    for exact in (
        "PermitRootLogin no",
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "AuthenticationMethods publickey",
        "AllowUsers dev",
        "AuthorizedKeysFile /etc/ssh/devbox/authorized_keys",
        "HostKey /var/lib/devbox/system/ssh/ssh_host_ed25519_key",
        "Subsystem sftp internal-sftp",
        "AllowTcpForwarding yes",
        "UsePAM no",
        "StrictModes yes",
    ):
        if exact not in stripped:
            problems.append("sshd_config missing: %s" % exact)
    if stripped.count("HostKey ") != 1:
        problems.append("exactly one HostKey line expected (seed-only ed25519)")
    if stripped.count("AuthorizedKeysFile") != 1:
        problems.append("exactly one AuthorizedKeysFile line expected (central-only)")
    if "AuthorizedKeysCommand" in stripped:
        problems.append("AuthorizedKeysCommand must stay unset (no second channel)")
    if re.search(r"AuthorizedKeysFile[^\n]*%[hu]", stripped):
        problems.append("AuthorizedKeysFile must be a single absolute path, no %h/%u patterns")
    return problems


def check_entrypoint(text):
    problems = []
    stripped = strip_comments(text)
    for frag in (
        "ssh-keygen -lf",
        "sshd -t || die",
        "exec /usr/sbin/sshd -D -e",
        "printf 'schema=%s\\nuid=%s\\ngid=%s\\n'",
        'test -w "$HOME_DIR"',
        'test -w "$WORKSPACES_DIR"',
        'denial_check read      -r "$SYSTEM_DIR"',
        'denial_check traverse  -x "$SYSTEM_DIR"',
        'denial_check read      -r "$SERVICES_DIR"',
        'denial_check traverse  -x "$SERVICES_DIR"',
        "refusing to treat as denied",
        "useradd -M",
        '*[!0-9]*',
    ):
        if frag not in stripped:
            problems.append("entrypoint missing: %r" % frag)
    if stripped.count("-t ed25519") != 1:
        problems.append("exactly one host-key seeding (ed25519, first boot only) expected")
    for wrong in ("-t rsa", "-t ecdsa"):
        if wrong in stripped:
            problems.append("entrypoint must not contain %r" % wrong)
    # Root trust boundary: checked exactly once, BEFORE the known/empty
    # branching (unconditional — known recreate included).
    root_boundary = 'check_mode_owner "$STATE_ROOT" 0 0 755'
    boundary = stripped.find(root_boundary)
    branch = stripped.find('if [ -e "$IDENTITY" ]')
    if stripped.count(root_boundary) != 1:
        problems.append("root trust boundary check must appear exactly once, got %d"
                        % stripped.count(root_boundary))
    if branch == -1 or boundary == -1 or boundary > branch:
        problems.append("root trust boundary must be checked BEFORE the known/empty "
                        "branching (unconditional, incl. recreate)")
    # Top-level unknown-state scan (fix-round 3): exactly once, AFTER the
    # root trust boundary and BEFORE the known/empty branching — the scan
    # is unconditional, so a known state with an extra top-level entry
    # refuses too (host-prep parity; nested emptiness stays no-marker-only).
    top_call = 'top_mark=$(find "$STATE_ROOT"'
    top_scan = stripped.find("-printf 'unexpected-entry\\n' -quit")
    if stripped.count(top_call) != 1:
        problems.append("top-level unknown-state scan must appear exactly once, got %d"
                        % stripped.count(top_call))
    if top_scan == -1 or not boundary < top_scan < branch:
        problems.append("top-level unknown-state scan must run after the root "
                        "owner/mode check and BEFORE the known/empty branching")
    # Recursive/delete mutations: -R / combined / split / positioned short
    # flags and --recursive are all rejected (rm -f of own mktemp temp is
    # the only allowed rm form).
    problems.extend(scan_recursive_delete_flags(stripped, {
        "chown": ("R", {"--recursive"}),
        "chmod": ("R", {"--recursive"}),
        "rm": ("r", {"--recursive"}),
    }))
    if "mktemp" not in stripped or "mv -f" not in stripped:
        problems.append("atomic writes (mktemp + mv -f) expected for marker/authorized_keys")
    # Ephemeral central list (auth-path fix): /etc/ssh/devbox on the
    # container layer, root:root 0755/0644, fail-closed non-recursive
    # parent handling, symlink guards, atomic replace-on-write, the
    # read-as-dev start gate and the dev write denial must all stay.
    for frag in (
        "AUTH_DIR=/etc/ssh/devbox",
        "AUTHORIZED_KEYS=$AUTH_DIR/authorized_keys",
        '[ ! -L "$AUTH_DIR" ] || die',
        '[ -d "$AUTH_DIR" ] || die "$AUTH_DIR exists but is not a directory"',
        "[ -d /etc/ssh ] || die",
        'mkdir "$AUTH_DIR" || die',
        'check_mode_owner "$AUTH_DIR" 0 0 755',
        'write_atomic "$AUTHORIZED_KEYS" 644',
        'check_mode_owner "$AUTHORIZED_KEYS" 0 0 644',
        '[ ! -L "$AUTHORIZED_KEYS" ] || die',
        'runuser -u "$DEV_USER" -- test -r "$AUTHORIZED_KEYS"',
        'denial_check write     -w "$AUTH_DIR"',
    ):
        if frag not in stripped:
            problems.append("entrypoint missing central-keys contract: %r" % frag)
    # Guarded /run/sshd create (auth-path fix 2): fail-closed idempotent
    # form — existence-or-symlink probe, symlink refusal, type check,
    # die-guarded mkdir only in the absent branch, and the unconditional
    # root:root 0755 owner/mode check. The unguarded one-line mkdir of the
    # restart regression (dies on EEXIST when the same container restarts)
    # must not come back.
    for frag in (
        '[ -e "/run/sshd" ] || [ -L "/run/sshd" ]',
        '[ ! -L "/run/sshd" ] || die',
        '[ -d "/run/sshd" ] || die "/run/sshd exists but is not a directory"',
        'mkdir /run/sshd || die',
        'chown 0:0 "/run/sshd"',
        'chmod 0755 "/run/sshd"',
        'check_mode_owner "/run/sshd" 0 0 755',
    ):
        if frag not in stripped:
            problems.append("entrypoint missing guarded /run/sshd create: %r" % frag)
    # The old persistent central path is out of the current contract, and
    # directory creation must stay non-recursive.
    if "$SYSTEM_DIR/authorized_keys" in stripped or "/var/lib/devbox/system/authorized_keys" in stripped:
        problems.append("persistent system/authorized_keys must not be referenced "
                        "(ephemeral /etc/ssh/devbox is the contract)")
    if re.search(r"mkdir\s+-p", stripped):
        problems.append("mkdir must stay non-recursive (no -p)")
    # Fail-closed tree inspection (fix-round 2): find availability gate,
    # fixed-marker probes (never entry names), explicit rc capture + FATAL
    # assertion, and find-side allowed-name exclusion.
    for frag in (
        "command -v find",
        "! -name home ! -name workspaces ! -name system",
        "! -name services ! -name lost+found",
        "-printf 'unexpected-entry\\n' -quit",
        "-printf 'nested-content\\n' -quit",
        "|| top_rc=$?",
        "|| nested_rc=$?",
        '[ "$top_rc" -eq 0 ] || die',
        '[ "$nested_rc" -eq 0 ] || die',
    ):
        if frag not in stripped:
            problems.append("entrypoint missing fail-closed find form: %r" % frag)
    # Known-state root types: symlink first, then -d, then owner/mode (a
    # symlink or a regular file with the right stat bits must not pass).
    for frag in (
        '[ ! -L "$SYSTEM_DIR" ] || die',
        '[ ! -L "$SSH_DIR" ] || die',
        '[ ! -L "$SERVICES_DIR" ] || die',
        '[ ! -L "$HOME_DIR" ] || die',
        '[ ! -L "$WORKSPACES_DIR" ] || die',
        '[ -d "$SYSTEM_DIR" ] || die',
        '[ -d "$SSH_DIR" ] || die',
        '[ -d "$SERVICES_DIR" ] || die',
        '[ -d "$HOME_DIR" ] || die',
        '[ -d "$WORKSPACES_DIR" ] || die',
    ):
        if frag not in stripped:
            problems.append("entrypoint missing known-state directory-type check: %r" % frag)
    # Symlink parity for the identity marker and the empty-branch loop
    # (fix-round 3): [ -e ]/[ -f ]/[ -d ]/stat follow symlinks, so the
    # guards must reject the link before the type/owner/mode checks.
    for frag in (
        '[ ! -L "$IDENTITY" ] || die',
        '[ ! -L "$dir" ] || die',
    ):
        if frag not in stripped:
            problems.append("entrypoint missing symlink guard: %r" % frag)
    # The nested-emptiness verification must run BEFORE the host-key
    # seeding: a refused first boot performs zero mutations.
    emptiness = stripped.find("-printf 'nested-content\\n' -quit")
    seeding = stripped.find("-t ed25519")
    if emptiness == -1 or seeding == -1 or emptiness > seeding:
        problems.append("nested-emptiness check (empty first boot) must precede "
                        "host-key seeding")
    return problems


def check_hostprep(text):
    problems = []
    stripped = strip_comments(text)
    for frag in (
        '[ "$(id -u)" -eq 0 ] || die',
        '[ "$(uname -s)" = "Linux" ] || die',
        '*[!0-9]*',
        "-L",
        "unknown non-empty state",
        'MARKER=$ROOT/system/identity',
        '[ ! -L "$MARKER" ]',
        "expected '0 0 600'",
        "nested content, dotfiles included",
        'ensure_dir "$ROOT"',
        'ensure_dir "$ROOT/home"',
        'ensure_dir "$ROOT/workspaces"',
        'ensure_dir "$ROOT/system"',
        'ensure_dir "$ROOT/services"',
        "stat -c '%u %g %a'",
    ):
        if frag not in stripped:
            problems.append("host-prep missing: %r" % frag)
    # Fail-closed tree inspection (fix-round 2): find availability gate,
    # fixed-marker probes (never entry names), explicit rc capture + FATAL
    # assertion, and find-side allowed-name exclusion.
    for frag in (
        "command -v find",
        "! -name home ! -name workspaces ! -name system",
        "! -name services ! -name lost+found",
        "-printf 'unexpected-entry\\n' -quit",
        "-printf 'nested-content\\n' -quit",
        "|| top_rc=$?",
        "|| nested_rc=$?",
        '[ "$top_rc" -eq 0 ] || die',
        '[ "$nested_rc" -eq 0 ] || die',
    ):
        if frag not in stripped:
            problems.append("host-prep missing fail-closed find form: %r" % frag)
    # With no marker, both tree-state scans must run BEFORE the first
    # mutation (ensure_dir): a refused run performs zero mutations.
    first_mutation = stripped.find('ensure_dir "$ROOT"')
    for probe in ("-printf 'unexpected-entry\\n' -quit",
                  "-printf 'nested-content\\n' -quit"):
        pos = stripped.find(probe)
        if pos == -1 or first_mutation == -1 or pos > first_mutation:
            problems.append("tree-state scan (%r) must precede the first "
                            "ensure_dir mutation" % probe)
    # Recursive/delete mutations: -R / combined / split / positioned short
    # flags and --recursive are all rejected; host-prep additionally runs
    # no rm at all (it never deletes anything).
    problems.extend(scan_recursive_delete_flags(stripped, {
        "chown": ("R", {"--recursive"}),
        "chmod": ("R", {"--recursive"}),
        "rm": ("rf", {"--recursive"}),
    }))
    if re.search(r"(^|[\s;|&])rm\s", stripped):
        problems.append("host-prep must not run rm at all (no deletes)")
    for line in stripped.splitlines():
        if "identity" in line and re.search(r">|touch|mktemp|cp ", line):
            problems.append("host-prep must only READ the marker, offending line: %s" % line.strip())
    return problems


def check_healthcheck(text):
    problems = []
    stripped = strip_comments(text)
    for frag in (
        "/usr/sbin/sshd -t || fail",
        "sport = :22",
        "identity",
        "ssh_host_ed25519_key",
        "AUTH_DIR=/etc/ssh/devbox",
        "AUTHORIZED_KEYS=$AUTH_DIR/authorized_keys",
        '[ -s "$AUTHORIZED_KEYS" ] || fail',
        'runuser -u "$DEV_USER" -- test -r "$AUTHORIZED_KEYS"',
    ):
        if frag not in stripped:
            problems.append("healthcheck missing: %r" % frag)
    if "/var/lib/devbox/system/authorized_keys" in stripped or "$SYSTEM_DIR/authorized_keys" in stripped:
        problems.append("healthcheck must check the ephemeral /etc/ssh/devbox list, "
                        "not the old persistent path")
    if "VS Code" in stripped:
        problems.append("healthcheck body mentions VS Code (must not claim UI readiness)")
    return problems


def check_probe(text):
    problems = []
    stripped = strip_comments(text)
    for frag in (
        "--target", "--port", "--identity", "--user",
        "--expect-denied",
        "--selftest-auth-methods",
        "TARGET= PORT=22 IDENTITY=",
        "expect_deny",
        "root@$TARGET",
        "PubkeyAuthentication=no",
        "judge_auth_methods",
        # Only the full OpenSSH debug format is evidence (fix-round 2):
        # anchored, methods charset-restricted, no prefixes/banners.
        "^debug[0-9]+: Authentications that can continue: [a-z0-9,-]+$",
        # The shared rc+text classifier: live probe and selftest must use
        # the same code path, and rc=0 (login succeeded) must be a FAIL.
        "classify_auth_probe",
        '[ "$rc" -eq 0 ]',
        'classify_auth_probe "$password_rc" "$password_out"',
        'classify_auth_probe "$selftest_rc" "$selftest_text"',
        "*,keyboard-interactive,*) bad=1",
        "Permission denied (publickey)",
        "password_out=$(ssh -vv",
        "cmp -s",
        "/var/run/docker.sock",
        "cat /proc/mounts",
        "mp=${mline#* }",
        "/home|/home/*|/Users|/Users/*",
        "put",
        "rename",
        "get",
    ):
        if frag not in stripped:
            problems.append("client probe missing: %r" % frag)
    if re.search(r"10\.0\.0\.|192\.168\.|127\.0\.0\.1", stripped):
        problems.append("client probe must not hardcode personal addresses")
    return problems


def check_env_example(text):
    problems = []
    for key in COMPOSE_KEYS:
        if not re.search(r"^%s=" % key, text, re.M):
            problems.append(".env.example missing key: %s" % key)
    if "DEVBOX_AUTHORIZED_KEYS='ssh-ed25519" not in text:
        problems.append(".env.example must show the single-quoted multiline keys form")
    return problems


def check_gitignore(text):
    problems = []
    if not re.search(r"^\.env$", text, re.M):
        problems.append(".gitignore must ignore .env")
    if not re.search(r"^\.env\.\*$", text, re.M):
        problems.append(".gitignore must ignore .env.* variants")
    if not re.search(r"^!\.env\.example$", text, re.M):
        problems.append(".gitignore must NOT ignore .env.example (negation missing)")
    if text.find("!.env.example") < text.find(".env.*"):
        problems.append("!.env.example must come AFTER .env.* to re-include the template")
    if not re.search(r"^secrets/$", text, re.M):
        problems.append(".gitignore must ignore secrets/ directories")
    return problems


CHECKERS = {
    "image/Dockerfile": check_dockerfile,
    "deploy/compose.yml": check_compose,
    "image/sshd_config": check_sshd,
    "image/entrypoint.sh": check_entrypoint,
    "scripts/host-prep.sh": check_hostprep,
    "image/healthcheck.sh": check_healthcheck,
    "scripts/p1-client-probe.sh": check_probe,
    ".env.example": check_env_example,
    ".gitignore": check_gitignore,
}


class NotProvenError(Exception):
    """Raised when a check cannot run (missing tool), NOT when it fails."""


class ProbeMixin(object):
    def not_proven(self, reason):
        raise NotProvenError(reason)


# ---------------------------------------------------------------------------
# 1. Textual pins.
# ---------------------------------------------------------------------------

class TextualPins(ProbeMixin, unittest.TestCase):
    """TEXTUAL PINS: contract wording present in files. Not runtime proofs."""

    def test_all_textual_pins(self):
        for rel, checker in sorted(CHECKERS.items()):
            with self.subTest(file=rel):
                problems = checker(read(rel))
                self.assertEqual(problems, [], "%s: %r" % (rel, problems))


# ---------------------------------------------------------------------------
# 2. Mutation self-tests: every checker must reject a broken variant.
# ---------------------------------------------------------------------------

# Counts mutation controls that actually executed AND rejected (an
# assertNotEqual failure propagates before the increment). The suite
# summary prints this number; attestations cite it from the log.
MUTATION_CONTROLS = {"rejected": 0}


class MutationSelfTests(ProbeMixin, unittest.TestCase):
    """In-memory negative controls for the textual checkers (a checker that
    passes on mutated text pins nothing)."""

    def assert_rejected(self, rel, mutated):
        problems = CHECKERS[rel](mutated)
        self.assertNotEqual(problems, [], "mutation of %s was NOT rejected" % rel)
        MUTATION_CONTROLS["rejected"] += 1

    def test_compose_mutations(self):
        base = read("deploy/compose.yml")
        self.assert_rejected("deploy/compose.yml",
                             base.replace("create_host_path: false", "create_host_path: true"))
        self.assert_rejected("deploy/compose.yml", base + "\nvolumes:\n  scratch:\n")
        self.assert_rejected("deploy/compose.yml",
                             base.replace('restart: unless-stopped', 'restart: always'))
        self.assert_rejected("deploy/compose.yml",
                             base.replace('cpus: ${DEVBOX_CPU_LIMIT:?DEVBOX_CPU_LIMIT is not set}', 'cpus: 6.0'))
        self.assert_rejected("deploy/compose.yml",
                             base.replace("image: g9s-devbox:p1-local", "image: ${DEVBOX_NOT_DECLARED:?x}"))
        self.assert_rejected("deploy/compose.yml",
                             base.replace('    DEVBOX_PIDS_LIMIT: {consumers: [devbox]}\n', ''))

    def test_dockerfile_mutations(self):
        base = read("image/Dockerfile")
        self.assert_rejected("image/Dockerfile",
                             base.replace("@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2", ""))
        self.assert_rejected("image/Dockerfile",
                             base.replace("openssh-server=1:10.0p1-7+deb13u4", "openssh-server"))
        self.assert_rejected("image/Dockerfile",
                             base.replace('ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/devbox-entrypoint.sh"]',
                                         'ENTRYPOINT ["/bin/bash", "/usr/local/bin/devbox-entrypoint.sh"]'))

    def test_sshd_mutations(self):
        base = read("image/sshd_config")
        self.assert_rejected("image/sshd_config",
                             base.replace("PasswordAuthentication no", "PasswordAuthentication yes"))
        self.assert_rejected("image/sshd_config",
                             base.replace("PermitRootLogin no", "PermitRootLogin yes"))
        # Old persistent path (auth-path fix): must not come back as the
        # AuthorizedKeysFile — the unreadable-as-dev location is the
        # reject-every-login failure class.
        self.assert_rejected("image/sshd_config",
                             base.replace("AuthorizedKeysFile /etc/ssh/devbox/authorized_keys",
                                          "AuthorizedKeysFile /var/lib/devbox/system/authorized_keys"))
        self.assert_rejected("image/sshd_config",
                             base.replace("AuthorizedKeysFile /etc/ssh/devbox/authorized_keys",
                                          "AuthorizedKeysFile /home/dev/.ssh/authorized_keys"))
        self.assert_rejected("image/sshd_config",
                             base + "\nAuthorizedKeysFile /etc/ssh/extra_keys\n")
        # Second channel: AuthorizedKeysCommand must stay unset.
        self.assert_rejected("image/sshd_config",
                             base + "\nAuthorizedKeysCommand /usr/local/bin/devbox-keys\n")
        self.assert_rejected("image/sshd_config",
                             base.replace("Subsystem sftp internal-sftp", "Subsystem sftp /usr/lib/openssh/sftp-server"))

    def test_entrypoint_mutations(self):
        base = read("image/entrypoint.sh")
        self.assert_rejected("image/entrypoint.sh",
                             base.replace("sshd -t || die", "true || die"))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('chown 0:0 "$tmp"', 'chown -R 0:0 "$tmp"'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace("-t ed25519", "-t rsa"))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace("ssh-keygen -lf \"$keyfile\" >/dev/null 2>&1", "true"))
        # Root trust boundary must not be removable (nor branch-only).
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('check_mode_owner "$STATE_ROOT" 0 0 755\n', ''))
        # Recursive/delete variants: long form, split short flags, combined.
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('chown 0:0 "$tmp"', 'chown --recursive 0:0 "$tmp"'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('rm -f "$keyfile"', 'rm -r -f "$keyfile"'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('chmod 0600 "$HOST_KEY"', 'chmod -Rh 0600 "$HOST_KEY"'))
        # Fail-closed find form (fix-round 2): availability gate, rc capture
        # and fixed-marker probes must not be removed or loosened.
        self.assert_rejected("image/entrypoint.sh",
                             base.replace("command -v find", "command -v true"))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('|| nested_rc=$?', '|| :'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('|| top_rc=$?', '|| :'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace("-printf 'nested-content\\n' -quit", "-print -quit"))
        # Known-state root types: -d before owner/mode must not vanish.
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ -d "$SERVICES_DIR" ] || die', 'true'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ -d "$HOME_DIR" ] || die', 'true'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ -d "$WORKSPACES_DIR" ] || die', 'true'))
        # Symlink parity + unconditional top-scan (fix-round 3): the
        # marker/dir/loop symlink guards, the SSH_DIR type check and the
        # top-level scan itself must not be removable.
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ ! -L "$IDENTITY" ] || die', 'true || die'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ ! -L "$SSH_DIR" ] || die', 'true || die'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ ! -L "$dir" ] || die', 'true || die'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ -d "$SSH_DIR" ] || die', 'true'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('top_mark=$(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 \\\n',
                                          ''))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace("-printf 'unexpected-entry\\n' -quit", "-print -quit"))
        # Ephemeral central list (auth-path fix): the unreadable-as-dev
        # class — file mode, parent mode, the read-as-dev start gate —
        # plus the symlink guard, write denial, non-recursive create and
        # the old persistent path must all be load-bearing.
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('write_atomic "$AUTHORIZED_KEYS" 644',
                                          'write_atomic "$AUTHORIZED_KEYS" 600'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('check_mode_owner "$AUTHORIZED_KEYS" 0 0 644',
                                          'check_mode_owner "$AUTHORIZED_KEYS" 0 0 600'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('check_mode_owner "$AUTH_DIR" 0 0 755',
                                          'check_mode_owner "$AUTH_DIR" 0 0 700'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ ! -L "$AUTH_DIR" ] || die', 'true || die'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ ! -L "$AUTHORIZED_KEYS" ] || die', 'true || die'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('runuser -u "$DEV_USER" -- test -r "$AUTHORIZED_KEYS"',
                                          'true'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('denial_check write     -w "$AUTH_DIR"', 'true'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('mkdir "$AUTH_DIR" || die', 'mkdir -p "$AUTH_DIR" || die'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('AUTHORIZED_KEYS=$AUTH_DIR/authorized_keys',
                                          'AUTHORIZED_KEYS=$SYSTEM_DIR/authorized_keys'))
        # Guarded /run/sshd create (auth-path fix 2): the restart
        # regression — an unguarded mkdir dies on EEXIST when the same
        # container restarts — must not return; the symlink guard and the
        # root:root 0755 owner/mode check must stay load-bearing.
        self.assert_rejected("image/entrypoint.sh",
                             base.replace(
                                 'if [ -e "/run/sshd" ] || [ -L "/run/sshd" ]; then\n'
                                 '  [ ! -L "/run/sshd" ] || die "/run/sshd is a symlink; '
                                 'symlinks on the sshd runtime path are refused"\n'
                                 '  [ -d "/run/sshd" ] || die "/run/sshd exists but is not a directory"\n'
                                 'else\n'
                                 '  mkdir /run/sshd || die "cannot create /run/sshd (privilege separation dir)"\n'
                                 '  chown 0:0 "/run/sshd"\n'
                                 '  chmod 0755 "/run/sshd"\n'
                                 'fi\n'
                                 'check_mode_owner "/run/sshd" 0 0 755\n',
                                 'mkdir /run/sshd || die "cannot create /run/sshd (privilege separation dir)"\n'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('[ ! -L "/run/sshd" ] || die', 'true || die'))
        self.assert_rejected("image/entrypoint.sh",
                             base.replace('check_mode_owner "/run/sshd" 0 0 755\n', ''))

    def test_hostprep_mutations(self):
        base = read("scripts/host-prep.sh")
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace('[ "$(id -u)" -eq 0 ] || die', "true || die"))
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace('log "done.', 'rm -rf "$ROOT"\nlog "done.'))
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace('chmod "$mode" "$dir"', 'chmod -R "$mode" "$dir"'))
        # Recursive/delete variants: long form, split/positioned short flags.
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace('chown "$ouid:$ogid" "$dir"', 'chown "$ouid:$ogid" -R "$dir"'))
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace('log "done.', 'rm --recursive "$ROOT/x"\nlog "done.'))
        # Nested-emptiness (no-marker path) and marker damage must not be
        # removable or weakened.
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace("expected '0 0 600'", "expected '0 0 644'"))
        # Fail-closed find form (fix-round 2): availability gate, rc capture,
        # fixed-marker probes and the allowed-name exclusion must stay; the
        # old unchecked/name-substitution spellings must not come back.
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace("command -v find", "command -v true"))
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace('|| nested_rc=$?', '|| :'))
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace('|| top_rc=$?', '|| :'))
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace("-printf 'nested-content\\n' -quit", "-print -quit"))
        self.assert_rejected("scripts/host-prep.sh",
                             base.replace("! -name services ! -name lost+found", ""))

    def test_healthcheck_mutations(self):
        base = read("image/healthcheck.sh")
        self.assert_rejected("image/healthcheck.sh",
                             base.replace("/usr/sbin/sshd -t || fail", "/bin/true"))
        self.assert_rejected("image/healthcheck.sh",
                             base.replace("sport = :22", "sport = :23"))
        # New health contract (auth-path fix): the read-as-dev probe and
        # the non-empty check must not be removable, and the old
        # persistent path must not replace the ephemeral one.
        self.assert_rejected("image/healthcheck.sh",
                             base.replace('runuser -u "$DEV_USER" -- test -r "$AUTHORIZED_KEYS"',
                                          "/bin/true"))
        self.assert_rejected("image/healthcheck.sh",
                             base.replace('[ -s "$AUTHORIZED_KEYS" ] || fail', "true"))
        self.assert_rejected("image/healthcheck.sh",
                             base.replace("AUTH_DIR=/etc/ssh/devbox", "AUTH_DIR=/var/lib/devbox/system"))

    def test_probe_mutations(self):
        base = read("scripts/p1-client-probe.sh")
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("TARGET= PORT=22 IDENTITY=", "TARGET=10.0.0.100 PORT=22 IDENTITY="))
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("expect_deny", "expect_ok"))
        # Denied-key mode and its explicit-proof requirement.
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("--expect-denied", "--expect-allowed"))
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("Permission denied (publickey)", "Permission denied"))
        # Password probe must stay evidence-based (server auth list, -vv).
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("*,keyboard-interactive,*) bad=1", "*,keyboard-interactive,*) :"))
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("ssh -vv -o BatchMode=yes", "ssh -o BatchMode=yes"))
        # Strict-format parser + shared rc-aware classifier (fix-round 2).
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("^debug[0-9]+: Authentications that can continue: [a-z0-9,-]+$",
                                          "Authentications that can continue:"))
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace('classify_auth_probe "$password_rc" "$password_out"',
                                          'judge_auth_methods "$password_out"'))
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace('[ "$rc" -eq 0 ]', '[ "$rc" -eq 99 ]'))
        # Mount probe: field-2 parsing and exact/descendant globs must stay.
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("/home|/home/*|/Users|/Users/*", "/home/|/Users/"))
        self.assert_rejected("scripts/p1-client-probe.sh",
                             base.replace("mp=${mline#* }; mp=${mp%% *}", "mp=$mline"))

    def test_env_example_mutations(self):
        base = read(".env.example")
        self.assert_rejected(".env.example",
                             re.sub(r"^DEVBOX_GID=.*$", "", base, flags=re.M))

    def test_gitignore_mutation(self):
        self.assert_rejected(".gitignore", "# nothing ignored\n")
        base = read(".gitignore")
        self.assert_rejected(".gitignore", base.replace("!.env.example\n", ""))
        self.assert_rejected(".gitignore", base.replace(".env.*\n", ""))
        self.assert_rejected(".gitignore", base.replace("secrets/\n", ""))


# ---------------------------------------------------------------------------
# 3. Behavioral checks (local tools; NOT PROVEN when tools are absent).
# ---------------------------------------------------------------------------

def compose_config(env_path, extra_args=()):
    cmd = ["docker", "compose", "--env-file", env_path,
           "-f", os.path.join(REPO_ROOT, "deploy", "compose.yml"), "config"]
    cmd.extend(extra_args)
    return subprocess.run(cmd, capture_output=True, text=True)


def write_env(values):
    fd, path = tempfile.mkstemp(prefix="g9s-devbox-p1-env-", suffix=".env")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        for key, value in values.items():
            if "\n" in value:
                fh.write("%s='%s'\n" % (key, value))
            else:
                fh.write("%s=%s\n" % (key, value))
    return path


class ShellSyntax(ProbeMixin, unittest.TestCase):
    def test_bash_n(self):
        bash = shutil.which("bash")
        if not bash:
            self.not_proven("bash not found; shell syntax not checked")
        for rel in ("image/entrypoint.sh", "image/healthcheck.sh",
                    "scripts/host-prep.sh", "scripts/p1-client-probe.sh"):
            with self.subTest(script=rel):
                proc = subprocess.run([bash, "-n", os.path.join(REPO_ROOT, rel)],
                                      capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0,
                                 "%s: %s" % (rel, proc.stderr.strip()))


class ProbeParserBehavior(ProbeMixin, unittest.TestCase):
    """Behavioral controls for the shared password-probe classifier
    (classify_auth_probe: ssh rc + text), run on SYNTHETIC fixtures through
    the probe's own --selftest-auth-methods hook (stdin: rc line, then the
    ssh -vv output).

    These controls exercise the CLASSIFIER only. They are NOT a proof
    about a real password-enabled sshd; the server-side proof (real sshd
    readback, password-enabled negative fixture, rc=0 login refusal) is
    the manager's Linux run.
    """

    SYNTH_PUBLICKEY_ONLY = (
        "OpenSSH_10.0p1, OpenSSL 3.0.15\n"
        "debug2: service_accept: ssh-userauth\n"
        "debug1: Authentications that can continue: publickey\r\n"
        "Permission denied (publickey).\n")
    SYNTH_PUBLICKEY_PASSWORD = (
        "debug1: Offering public key: nope\n"
        "debug1: Authentications that can continue: publickey,password\r\n")
    SYNTH_PUBLICKEY_KBD = (
        "debug1: Authentications that can continue: publickey,keyboard-interactive\n")
    SYNTH_NO_LIST = (
        "ssh: connect to host example.invalid port 2222: Operation timed out\n")
    # Fix-round 2: only the full OpenSSH debug format is evidence —
    # notice-level, prefixed, charset-violating and trailing-junk lines
    # must yield NOT-PROVEN, never a pass/verdict on a pseudo-list.
    SYNTH_NOTICE_LINE = (
        "notice: Authentications that can continue: publickey\n")
    SYNTH_PREFIXED_LINE = (
        "debug1: wedged Authentications that can continue: publickey\n")
    SYNTH_BAD_CHARSET = (
        "debug1: Authentications that can continue: PublicKey\n")
    SYNTH_TRAILING_JUNK = (
        "debug1: Authentications that can continue: publickey extra\n")

    def run_selftest(self, rc, output):
        bash = shutil.which("bash")
        if not bash:
            self.not_proven("bash not found; parser self-test cannot run")
        return subprocess.run(
            [bash, os.path.join(REPO_ROOT, "scripts", "p1-client-probe.sh"),
             "--selftest-auth-methods"],
            input="%d\n%s" % (rc, output), capture_output=True, text=True)

    def assert_verdict(self, rc, output, verdict, code):
        proc = self.run_selftest(rc, output)
        self.assertEqual(proc.returncode, code,
                         "stderr: %s" % (proc.stderr + proc.stdout))
        self.assertIn("[SELFTEST-auth-methods] %s" % verdict, proc.stdout)

    def test_publickey_only_list_is_pass(self):
        self.assert_verdict(255, self.SYNTH_PUBLICKEY_ONLY, "PASS", 0)

    def test_publickey_password_list_is_fail(self):
        self.assert_verdict(255, self.SYNTH_PUBLICKEY_PASSWORD, "FAIL", 1)

    def test_publickey_keyboard_interactive_list_is_fail(self):
        self.assert_verdict(255, self.SYNTH_PUBLICKEY_KBD, "FAIL", 1)

    def test_missing_list_is_not_proven(self):
        self.assert_verdict(255, self.SYNTH_NO_LIST, "NOT-PROVEN", 2)

    def test_notice_line_is_not_evidence(self):
        self.assert_verdict(255, self.SYNTH_NOTICE_LINE, "NOT-PROVEN", 2)

    def test_prefixed_line_is_not_evidence(self):
        self.assert_verdict(255, self.SYNTH_PREFIXED_LINE, "NOT-PROVEN", 2)

    def test_malformed_methods_charset_is_not_evidence(self):
        self.assert_verdict(255, self.SYNTH_BAD_CHARSET, "NOT-PROVEN", 2)

    def test_trailing_junk_is_not_evidence(self):
        self.assert_verdict(255, self.SYNTH_TRAILING_JUNK, "NOT-PROVEN", 2)

    def test_rc0_login_with_publickey_list_is_fail(self):
        # rc=0 = the attempt LOGGED IN; the publickey list beside it does
        # not cancel the failure. Synthetic classifier control, not a live
        # fixture — real-sshd rc=0 behavior is proven by the manager's
        # Linux run.
        self.assert_verdict(0, self.SYNTH_PUBLICKEY_ONLY, "FAIL", 1)


class ComposeBehavior(ProbeMixin, unittest.TestCase):
    """`docker compose config` proves interpolation/validation behavior:
    required-key enforcement and multiline authorized-keys plumbing."""

    def setUp(self):
        if not shutil.which("docker"):
            self.not_proven("docker CLI not found; compose behavior NOT PROVEN")

    @staticmethod
    def rendered_service(env_values):
        env = write_env(env_values)
        try:
            proc = compose_config(env, ["--format", "json"])
            return proc, (json.loads(proc.stdout)["services"]["devbox"] if proc.returncode == 0 else None)
        finally:
            os.unlink(env)

    def test_valid_env_renders(self):
        proc, svc = self.rendered_service(VALID_ENV)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # Single published endpoint, exactly the agreed one (schema-agnostic:
        # render differs across compose versions, the invariant does not).
        ports = svc.get("ports")
        self.assertEqual(len(ports), 1, "exactly one published port expected")
        port_str = json.dumps(ports[0])
        self.assertIn("10.0.0.100", port_str)
        self.assertIn("2222", port_str)
        # The one bind: whole host root, no path creation, no volumes section.
        vols = svc["volumes"]
        self.assertEqual(len(vols), 1, "exactly one bind expected")
        bind = vols[0]
        self.assertEqual(bind["type"], "bind")
        self.assertEqual(bind["source"], "/var/lib/devbox")
        self.assertEqual(bind["target"], "/var/lib/devbox")
        self.assertIs(bind.get("bind", {}).get("create_host_path"), False)
        # Runtime env mapping carries both multiline keys verbatim.
        env = svc["environment"]
        if isinstance(env, list):
            keys_env = [e for e in env if e.startswith("DEVBOX_RUNTIME_AUTHORIZED_KEYS=")][0].split("=", 1)[1]
        else:
            keys_env = env["DEVBOX_RUNTIME_AUTHORIZED_KEYS"]
        self.assertIn("p1-macbook", keys_env)
        self.assertIn("p1-minipc", keys_env)
        self.assertIn("\n", keys_env)
        # Limits made it through interpolation.
        self.assertEqual(float(svc["deploy"]["resources"]["limits"]["cpus"]), 6.0)
        limits = svc["deploy"]["resources"]["limits"]
        pids_value = limits.get("pids", svc.get("pids_limit"))
        self.assertEqual(int(pids_value), 1024, "PIDs limit not rendered: %r" % svc)

    def test_missing_required_key_fails_loud(self):
        values = dict(VALID_ENV)
        del values["DEVBOX_UID"]
        env = write_env(values)
        try:
            proc = compose_config(env)
            self.assertNotEqual(proc.returncode, 0, "missing DEVBOX_UID must fail config")
            self.assertIn("DEVBOX_UID", proc.stderr)
        finally:
            os.unlink(env)

    def test_empty_required_key_fails_loud(self):
        values = dict(VALID_ENV)
        values["DEVBOX_SSH_BIND"] = ""
        env = write_env(values)
        try:
            proc = compose_config(env)
            self.assertNotEqual(proc.returncode, 0, "empty DEVBOX_SSH_BIND must fail config")
            self.assertIn("DEVBOX_SSH_BIND", proc.stderr)
        finally:
            os.unlink(env)

    def test_host_path_is_not_created(self):
        # Behavioral half of create_host_path: false is proven on the Linux
        # node (up against a missing path); here we pin the rendered flag.
        proc, svc = self.rendered_service(VALID_ENV)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIs(svc["volumes"][0]["bind"]["create_host_path"], False)


class DevboxTestResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super(DevboxTestResult, self).__init__(*args, **kwargs)
        self.not_proven = []

    def addError(self, test, err):
        if isinstance(err[1], NotProvenError):
            self.not_proven.append(str(test))
            if self.showAll:
                self.stream.writeln("NOT PROVEN")
            else:
                self.stream.write("N")
                self.stream.flush()
        else:
            super(DevboxTestResult, self).addError(test, err)


def main():
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(stream=sys.stderr, verbosity=2,
                                     resultclass=DevboxTestResult)
    result = runner.run(suite)
    print("-" * 70)
    print("P1 suite: failures=%d errors=%d skipped=%d not_proven=%d "
          "mutation_controls_rejected=%d" %
          (len(result.failures), len(result.errors), len(result.skipped),
           len(result.not_proven), MUTATION_CONTROLS["rejected"]))
    for name in result.not_proven:
        print("NOT PROVEN: %s" % name)
    if result.failures or result.errors:
        return 1
    # Skips and missing tools are NOT PROVEN, never green.
    if result.not_proven or result.skipped:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
