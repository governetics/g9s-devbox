# g9s-devbox — целевая архитектура MVP

**Статус:** ратифицированная to-be архитектура. Реализация ещё не создана; текущее фактическое состояние — [architecture.md](architecture.md). Детали и отвергнутые альтернативы — [D-001](decisions/D-001-runtime-devbox.md), [D-002](decisions/D-002-sostoyanie-i-postavka.md), [D-003](decisions/D-003-failovyi-obmen.md).

## Назначение

Однопользовательская контейнерная среда удалённой разработки под управлением governetics. Основной доступ — официальный desktop VS Code через Remote-SSH по LAN/VPN. Claude Code и OpenCode выполняются на удалённой стороне. Workspace, пользовательское состояние и идентичность сервисов переживают recreate и снятие проекта с узла при повторном deploy с тем же host-path.

## Внешние платформы и термины

- **Governetics Path A** — панель получает compose-шаблон операторского проекта, доставляет объявленные `envs`/files, переписывает image на digest и запускает compose на узле. Снятие проекта выполняет `down -v --remove-orphans`; bind-path на хосте не является named volume. Конкретный configure/recreate и removal контракт подтверждается real-env.
- **g9s-edge** — существующий внешний reverse proxy: терминирует public HTTPS и маршрутизирует WebDAV на backend `адрес:порт`. Его размещение, source IP и forwarded-header настройка — operator inputs, а не предположение devbox.
- **g9s-mediapump** — соседний действующий продукт, чей SFTPGo/Samba config использован как проверенный референс. Его работоспособность не заменяет приёмку devbox.
- **Host-prep** — версионированный скрипт/runbook этого продукта, запускаемый до `up` оператором либо агентом с явно выданным host/root доступом; не фоновый сервис.

## Целевая топология

```text
Desktop VS Code ──SSH──► devbox ──► VS Code Server / Claude Code / OpenCode / git
                           │
SFTP client ───────SSH/SFTP┘
                           │
Browser/client ─HTTPS─► g9s-edge ─HTTP─► sftpgo WebDAV
                           │
Finder/Explorer ─SMB 445─► samba
                           │
             Общий host root: home + workspaces + system + services
```

Три sibling-сервиса не делят PID namespace. SFTPGo и Samba не устанавливаются внутрь `devbox`; их сбой не меняет модель `tini + sshd` основной среды.

## Компоненты

| Компонент | Ответственность | Кто владеет lifecycle/version |
|---|---|---|
| `devbox` | SSH/SFTP, shells, git, VS Code remote runtime, агенты | `tini` + sshd; system image для CLI |
| VS Code Server | Remote extension host и remote tooling | Desktop VS Code устанавливает/обновляет |
| Extensions | Claude Code/OpenCode VS Code integrations | Versioned manifest + post-connect convergence |
| Claude Code | Interactive CLI/extension и длительные `--bg` tasks | Native supervisor для background |
| OpenCode | Interactive CLI/extension и native per-user service | Native on-demand service |
| `sftpgo` | Постоянный WebDAV; virtual users и service state | Отдельный compose service |
| `samba` | Нативная SMB-шара `/export` | Отдельный compose service, TCP/445 |
| `g9s-edge` | Public HTTPS и маршрутизация WebDAV | Внешний существующий проект |

## Persistent state

Единый обязательный `DEVBOX_HOST_PATH` монтируется в devbox как `/var/lib/devbox`.

| Область | Содержимое | Сетевой export |
|---|---|---|
| `home/` | Полный `$HOME`: VS Code Server/extensions/settings, Claude/OpenCode config/state/auth | Да, осознанно secrets-bearing |
| `workspaces/` | Рабочие проекты | Да |
| `system/` | SSH host keys, central authorized_keys metadata, UID/state-schema marker | Нет |
| `services/` | SFTPGo DB/host keys и Samba passdb/state | Нет |

Samba получает только `home/` и `workspaces/` как `/export/home` и `/export/workspaces`; единая шара публикует `/export`. SFTPGo получает аналогично ограниченные binds. OpenSSH SFTP не ограничен этим export-контуром и действует в рамках Unix permissions `dev`; для `dev` read/write/traverse `system/` запрещены и проверяются отдельной пробой.

Named volumes для переживаемого состояния не используются. Версионированный host-prep вызывается оператором либо агентом с host/root доступом и создаёт производные каталоги до `up`; `create_host_path:false` и `${KEY:?…}` делают ошибки конфигурации громкими.

## Identity и права

- Агенты и пользовательские процессы работают под настраиваемым `DEVBOX_UID:DEVBOX_GID`.
- UID/GID фиксируются root-owned marker при первичной инициализации; смена требует явной миграции.
- SFTPGo использует arbitrary numeric user; Samba — numeric uid/gid + force user/group.
- Host-side/deploy preflight сверяет source и effective Samba identity с marker без монтирования `system/` в Samba.
- Центральный root-owned authorized_keys — единственный SSH login trust-channel; user-home и host-file не создают независимого доступа. Agent forwarding лишь использует локальный agent внутри уже аутентифицированной SSH-сессии.
- LLM login выполняется внутри devbox; auth-state сохраняется в home. Git/LLM secrets не записываются в VCS.

## Сетевые поверхности

| Поверхность | Публичный путь | Ограничения |
|---|---|---|
| Remote-SSH + OpenSSH SFTP | Настраиваемый host bind/port → devbox SSH | Key-only, непривилегированный `dev` |
| WebDAV | Client HTTPS → g9s-edge → HTTP backend | SFTPGo global allowlist: edge + loopback + internal admin sources; non-edge denied |
| SMB | LAN/VPN → TCP/445 | Одна шара `/export`; `wide links=no`, `follow symlinks=yes` — внутренние ссылки работают, escape запрещён |
| SFTPGo SFTP | Не публикуется | Выключен |
| SFTPGo WebClient | Не используется | Не входит в контракт MVP |
| SFTPGo WebAdmin/REST | Не публикуются на host | Internal-only bootstrap/rotation через loopback или SSH LocalForward |
| OpenCode web/API | Не публикуется на host | Native user-local socket/listener допускается; public port запрещён |

Backend edge → SFTPGo остаётся HTTP — это названный внутренний hop. Доступ к home через SMB/WebDAV означает доступ к agent credentials и другим секретам пользователя; риск принят для single-operator контура.

## Обновления и жизненный цикл

- Системный образ и standalone CLI обновляются immutable versioned release с digest-pin и smoke.
- VS Code Server обновляется desktop-клиентом независимо; rollback image не откатывает server.
- Extensions применяются post-connect по pinned manifest с autoUpdate off.
- Интерактивные turn/terminal при IDE close и SSH disconnect не имеют априорной гарантии продолжения.
- Restart/recreate сохраняет данные, но останавливает процессы и in-flight работу.
- Persistence не равна backup; host disk loss и live inconsistent SQLite copy не покрываются MVP-конструкцией.

## Non-goals MVP

- Microsoft Tunnel, Azure Relay, code-server, browser IDE и собственный UI.
- SFTPGo WebClient/WebAdmin как публичные поверхности; второй SFTPGo SFTP-контур.
- WebDAV/Samba внутри основного devbox-контейнера.
- Мультитенантная изоляция и per-person Unix ownership на общем export.
- Автоматическое продолжение in-flight задач через restart/recreate.
- Автоматический backup/DR без отдельной реализации и проверки.
- Публикация непредусмотренных портов, `docker.sock` и секреты host home.

## Доказательство

Целевая архитектура не считается работоспособной по документу или `converged`. Вертикальные фазы, владельцы real-env действий, credentials и обязательные local/remote/removal испытания — [implementation-plan.md](../project/implementation-plan.md).
