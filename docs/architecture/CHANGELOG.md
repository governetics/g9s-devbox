# CHANGELOG — семантический лог архитектуры g9s-devbox

Записи — сверху, новые первыми. Одно изменение — одна запись; фазовые статусы живут в [implementation-plan](../project/implementation-plan.md).

## 2026-11-17 — P1: local core и SSH/SFTP (impl-сессия 261117-01)

**Session:** impl `261117-01-p1-local-core` (дом проекта в workbench). Приёмка runtime V01–V18 — «доказано» на Linux-узле; [validation report](../validation/p1-local-core.md) и [runbook оператора](../runbooks/p1-local-core.md).

### Added

- Образ `g9s-devbox:p1-local` ([Dockerfile](../../image/Dockerfile)): pinned `debian:13-slim` по digest, точные package pins (openssh, tini, git, curl, ca-certificates, iproute2, libstdc++6), `tini -g` PID 1; без агентов/VS Code/file-сервисов.
- Runtime-контракт P1: root-bootstrap [entrypoint](../../image/entrypoint.sh) (валидация env до мутаций, state-machine known/empty/unknown, fail-before-sshd, symlink-гварды, fail-closed find), [sshd_config](../../image/sshd_config) (publickey-only `dev`, root/password/kbd-interactive denied, `internal-sftp`), [healthcheck](../../image/healthcheck.sh) (`sshd -t` + listener + state roots + читаемость центрального списка как `dev`).
- Persistent layout и identity: один bind `DEVBOX_HOST_PATH` с `home/workspaces/system/services` и owners/modes; root-owned marker `system/identity` (schema 1, численные UID/GID); seed-only host key `system/ssh/ssh_host_ed25519_key`.
- Центральный authorized_keys как **ephemeral runtime-список** `/etc/ssh/devbox/authorized_keys` (root:root 0755/0644): env — authority, атомарная перематериализация на каждом старте; central-only (без AuthorizedKeysCommand и home-канала) сохранён.
- [compose](../../deploy/compose.yml): один сервис `devbox`, `${KEY:?…}` на всех входах, `DEVBOX_RUNTIME_*`-мэппинг, единственный опубликованный endpoint SSH, `restart: unless-stopped`, limits CPU 6.0 / memory 6656m / pids 1024, логи 10m × 3, stop grace 30s.
- Скрипты: идемпотентный [host-prep](../../scripts/host-prep.sh) и клиентская проба [p1-client-probe](../../scripts/p1-client-probe.sh) (включая `--expect-denied`); static suite [tests/test_p1.py](../../tests/test_p1.py) — 24 теста / 81 rejected mutation control.
- Операторские документы: [runbook P1](../runbooks/p1-local-core.md) и [validation report P1](../validation/p1-local-core.md); честный статус и quickstart в [README](../../README.md).

### Changed

- [implementation-plan](../project/implementation-plan.md): P1 → DONE (2026-11-17); ротация ключей переформулирована как recreate с positive/negative readback (plain `restart` не перечитывает `.env`).
- [vision](vision.md): центральный authorized_keys убран из persistent-состава `system/` — описан как ephemeral runtime-список с env-authority; host keys/marker в `system/` сохранены.
- [architecture](architecture.md): as-is переписан с «реализация отсутствует» на фактический P1-контур (компоненты, сеть, потоки, validation status).

### Fixed

- **Auth-path RCA:** центральный список на прежнем runtime-пути `/var/lib/devbox/system/authorized_keys` (root 0600 под `system/` 0700) делал sshd молчаливо отвергающим каждый pubkey-login — OpenSSH читает AuthorizedKeysFile под identity целевого пользователя (`temporarily_use_uid`), недоступной в `system/`. Решение оператора (вариант A): перенос в `/etc/ssh/devbox/authorized_keys` без смены central-only/env-authority контракта; подтверждён реальными login-пробами обоих ключей и password-fixture negative control.
- `/run/sshd`: guarded idempotent create (plain `restart` того же контейнера больше не падает на уже существующем каталоге) с сохранением fail-closed проверок.

## 2026-11-17 — архитектура MVP g9s-devbox

### Added

- [D-001](decisions/D-001-runtime-devbox.md): Debian 13 slim, `tini + sshd`, client-owned VS Code Server, pinned extensions/CLI и native on-demand Claude Code/OpenCode.
- [D-002](decisions/D-002-sostoyanie-i-postavka.md): единый persistent host-root, UID/GID/state-schema identity, central-only authorized_keys, один local/Path A compose и public GitHub/GHCR delivery.
- [D-003](decisions/D-003-failovyi-obmen.md): sibling SFTPGo/Samba, OpenSSH SFTP fallback, постоянный WebDAV через HTTPS g9s-edge, Samba 445 и selective home/workspaces export.
- Целевая [vision](vision.md) и честный [as-is](architecture.md): реализация ещё отсутствует.
- Вертикальный [implementation-plan](../project/implementation-plan.md) с владельцами real-env действий, operator inputs и матрицей M1–M13.
- Защитные контракты: edge-only SFTPGo allowlist, Samba `wide links=no` при сохранении внутренних symlinks, host-side Samba UID/GID preflight, export negative probes и tree+history secret scan перед public release.

### Changed

- Исходный SFTP-only контур расширен решением оператора до первоклассного файлового обмена через OpenSSH SFTP, WebDAV и SMB.
- Сетевой export включает secrets-bearing home по явному решению оператора, но исключает `system/` и `services/`.

### Removed

- Named volumes как допустимый носитель состояния, которое обязано переживать Path A removal.
- Preinstalled VS Code Server, недокументированный pre-connect extension preload и второй независимый SSH authorized_keys trust-channel как варианты реализации.
