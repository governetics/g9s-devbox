# Architecture — as-is

Текущее состояние системы (as-is). Целевое состояние (to-be) — [vision.md](vision.md); история изменений — [CHANGELOG.md](CHANGELOG.md); индекс решений — [decisions-log.md](decisions/decisions-log.md).

Этот файл — **as-is source of truth**: описывает систему как она есть сейчас, без сессионных нарративов и фазовых статусов (их дом — `../project/implementation-plan.md` и CHANGELOG).

---

## Обзор

На 2026-11-17 реализован и real-env проверен **P1 local core** (фаза P1 [implementation-plan](../project/implementation-plan.md), сессия impl `261117-01`): один контейнер `devbox` с `tini` + sshd, host-prep, persistent state/identity, central-only authorized_keys, SSH/SFTP под непривилегированным `dev` и fail-loud baseline. Приёмка V01–V18 — «доказано» на Linux-узле; отчёт — [validation report](../validation/p1-local-core.md).

Не реализовано (P2–P6 pending): desktop VS Code/Remote-SSH, CLI-агенты, LLM, SFTPGo/Samba/WebDAV/SMB, governetics Path A, публичный образ, removal/redeploy, backup. Sibling-сервисы `sftpgo` и `samba` не реализованы и не запущены; `g9s-edge` не подключён. Репозиторий локальный: remote, push/publish и deploy не выполнялись.

Решения зафиксированы в [D-001](decisions/D-001-runtime-devbox.md), [D-002](decisions/D-002-sostoyanie-i-postavka.md), [D-003](decisions/D-003-failovyi-obmen.md).

## Компоненты

Все компоненты ниже существуют в репозитории и работают в runtime P1.

| Компонент | Файл | Что делает фактически |
|---|---|---|
| Образ `g9s-devbox:p1-local` | `image/Dockerfile` | Local build (не опубликован). Base `debian:13-slim` по digest `sha256:a72b…b6b2`; pins: openssh server/client `1:10.0p1-7+deb13u4`, tini `0.19.0-3+b8`, git `1:2.47.3-0+deb13u1`, curl `8.14.1-2+deb13u7`, ca-certificates `20250419+deb13u1`, iproute2 `6.15.0-1`, libstdc++6 `14.2.0-19`. ENTRYPOINT `tini -g` → root bootstrap. Без агентов, VS Code Server, SFTPGo/Samba и supervisor |
| Entrypoint | `image/entrypoint.sh` | Root bootstrap: валидация env (численные UID/GID, каждая строка ключей — валидный OpenSSH public key, `#`-строки отклонены) **до любых мутаций state**; state-machine marker/empty-first-boot/unknown (fail-before-sshd); материализация центрального authorized_keys; пользователь `dev` (пароль `*`, bash); `/run/sshd`; `exec sshd -D -e`. Без recursive chown/chmod, ничего не удаляет |
| sshd | `image/sshd_config` | Port 22 внутри контейнера; `AuthenticationMethods publickey`, `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AllowUsers dev`; единственный `AuthorizedKeysFile /etc/ssh/devbox/authorized_keys` (абсолютный, без `%h/%u`, без `AuthorizedKeysCommand`); HostKey только из `system/ssh`; `internal-sftp` на том же endpoint; TCP/agent forwarding включены (под будущий VS Code Remote-SSH, P2); LogLevel VERBOSE в stderr |
| Healthcheck | `image/healthcheck.sh` | `sshd -t`, реальный listener `:22`, обязательные state roots, центральный список непуст и читаем **как `dev`**. Не доказывает login/VS Code/LLM |
| host-prep | `scripts/host-prep.sh` | Идемпотентная подготовка host-root от root: пять верхних корней с owners/modes (таблица ниже), не-рекурсивные правки, symlink/unknown-state отказы, ничего не удаляет, marker не создаёт |
| Compose | `deploy/compose.yml` | Один сервис `devbox`; все ключи через `${KEY:?…}` (пустое значение роняет config/up); runtime env под именами `DEVBOX_RUNTIME_*` (не затеняют panel env_file); healthcheck 30s/5s/3/15s; `restart: unless-stopped`; `stop_grace_period 30s`; limits `cpus 6.0` / `memory 6656m` / `pids 1024`; логи json-file 10m × 3 |
| Клиентская проба | `scripts/p1-client-probe.sh` | 9 проверок с клиентской позиции (login как `dev`, SFTP round-trip, root/password denial, `system/` denial, отсутствие `docker.sock`/host-home), режим `--expect-denied` для отозванных ключей |
| Тесты | `tests/test_p1.py` | Static/textual suite: 24 теста, 81 rejected mutation control (Linux-прогон); текстовые пины называются текстовыми |

## Сеть и поверхности

Наружу опубликован ровно один endpoint: `DEVBOX_SSH_BIND:DEVBOX_SSH_PORT` → контейнерный 22; на первом узле `10.0.0.100:2222`. Доказательный клиентский scan (с LAN jump-позиции, 65535 портов) видит только host SSH `22` и devbox SSH `2222` (улика `41-client-port-scan-jump.log`). Named volumes отсутствуют; смонтирован ровно один bind — `DEVBOX_HOST_PATH` (`create_host_path: false`) в `/var/lib/devbox`; `docker.sock` и host-home не монтируются.

## Persistent layout и identity

Один host-root (на первом узле `/var/lib/devbox`), раскладка и owners/modes:

| Путь | Владелец | Права | Содержимое |
|---|---|---|---|
| `$DEVBOX_HOST_PATH` | root:root | 0755 | общий корень (trust boundary, проверяется на каждом старте) |
| `home/` | UID:GID | 0750 | `$HOME` пользователя `dev` |
| `workspaces/` | UID:GID | 0750 | рабочие проекты |
| `system/` | root:root | 0700 | marker identity + SSH host keys; `dev` не может read/traverse (проверяется на каждом старте) |
| `services/` | root:root | 0700 | пусто в P1 (зарезервировано под sibling-сервисы P3) |

- **Marker** `system/identity`: root:root 0600, `schema=1`, численные `uid`/`gid`; создаётся entrypoint'ом на first boot, фиксирует UID/GID (mismatch — отказ, миграция — явная операция).
- **Host key** `system/ssh/ssh_host_ed25519_key` (+ pub): сеется один раз (seed-only); при живом marker потеря/порча ключа — отказ, regenerate нет; `.pub` может быть перезаписан из приватного. Fingerprint переживает restart/recreate (`29-restart-recreate-persistence.log`).
- **Центральный authorized_keys — runtime, не persistent state.** `/etc/ssh/devbox/authorized_keys`: root:root 0644, parent root:root 0755, ephemeral-слой контейнера. Authority — env `DEVBOX_AUTHORIZED_KEYS`; каждый старт атомарно перематериализует список; recreate применяет новый env, plain `restart` — нет. Путь выбран runtime-RCA (см. ниже): OpenSSH читает AuthorizedKeysFile под identity целевого пользователя, а `system/` 0700 для `dev` недоступен.

## Потоки данных

1. **Operator → gitignored `.env` → compose**: значения оператора (host path, UID/GID, публичные ключи, bind/port, limits) подставляются `${KEY:?…}`; отсутствующее/пустое значение роняет `config`/`up` до старта daemon'а.
2. **Operator/root → host-prep → host-root**: создание/проверка пяти верхних корней; entrypoint затем валидирует то же дерево на каждом старте (fail-loud, включая unknown nonempty, лишний top-level entry, symlink-гварды, find-отказы).
3. **compose → entrypoint → sshd**: build образа, `up`, root bootstrap (валидация env → state machine → центральный список → пользователь `dev`) → foreground `sshd -D -e`.
4. **SSH/SFTP client → `10.0.0.100:2222` → `dev` → home/workspaces**: key-only login как `dev`; shell и internal-sftp на одном endpoint; put/get/rename доказаны byte-identical round-trip'ом; `system/`/`services/` недоступны.
5. **Runtime state → healthcheck → Docker health**: `sshd -t` + listener + roots + читаемость центрального списка как `dev`; `healthy` ≠ user login.
6. **Ротация**: правка `.env` + `up -d --force-recreate` → перематериализация центрального списка; отозванный ключ и home-bypass проверяются отрицательными пробами (`30`–`36`).

## Validation status

Runtime-приёмка P1 (2026-11-17, Linux-узел): **V01–V18 — доказано** — статические/build/compose-пробы, идемпотентность host-prep, identity/state machine (UID/GID/schema/lost-key/unknown/find-отказы), реальные SSH/SFTP positive/negative пробы обоими ключами, password-fixture negative control, restart/recreate persistence, revoke/re-add через recreate, client port scan, финальное состояние. Полная матрица с уликами — [validation report](../validation/p1-local-core.md).

Не доказано (P2–P6): VS Code/агенты/LLM, Path A, файловые сервисы, публичный образ, removal/redeploy, backup. Persistence ≠ backup; продолжение in-flight процессов через restart/recreate не обещается; защита от tamper со стороны host-root не заявляется.

## Auth-path RCA (кратко)

Первоначальный runtime-путь списка `/var/lib/devbox/system/authorized_keys` (root 0600, `system/` 0700) давал живой sshd, отвергающий каждый pubkey-login: OpenSSH открывает AuthorizedKeysFile под `temporarily_use_uid(dev)` (`19-auth-debug-server.log`), а `dev` не может traverse `system/`. Решение оператора (вариант A): список перенесён в ephemeral `/etc/ssh/devbox` (root:root 0755/0644) — уточнение пути материализации, не смена central-only/env-authority решения D-002; `system/` остаётся root-only контрактом. Подробность — runbook §4 и validation report.
