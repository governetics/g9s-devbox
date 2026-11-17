# g9s-devbox

Контейнерная среда удалённой разработки под управлением governetics: официальный desktop VS Code через Remote-SSH, Claude Code и OpenCode на удалённой стороне, постоянные workspace/state и удобный файловый обмен через OpenSSH SFTP, HTTPS WebDAV и SMB.

## Статус

Архитектура MVP ратифицирована. Реализация контейнеров, compose и публикация образа ещё не выполнены; репозиторий сейчас содержит project-owned архитектурные документы и план. Документы не являются доказательством runtime-работоспособности.

## Целевые возможности

- Один основной `devbox` runtime с непривилегированным пользователем и client-managed VS Code Server.
- Pinned standalone CLI и remote VS Code extensions для Claude Code/OpenCode.
- Host bind-mount состояние, переживающее recreate и removal/redeploy с тем же host-path.
- Sibling SFTPGo и Samba; SFTPGo SFTP выключен, OpenSSH SFTP остаётся fallback.
- Постоянный WebDAV через g9s-edge с HTTPS-терминацией на edge и edge-only backend allowlist.
- Samba на стандартном TCP/445 на отдельном хосте.
- Общий сетевой export `home/` + `workspaces/` с единым UID/GID; `system/` и `services/` не экспортируются.

**Важно:** сетевой export включает secrets-bearing home, включая agent credentials и auth-state. Это осознанно принятый single-operator риск; служебные SSH/service state в export не входят.

## Документация

- [Текущее состояние as-is](docs/architecture/architecture.md)
- [Целевая архитектура](docs/architecture/vision.md)
- [План реализации и приёмочная матрица](docs/project/implementation-plan.md)
- ADR:
  - [D-001 — runtime и жизненный цикл](docs/architecture/decisions/D-001-runtime-devbox.md)
  - [D-002 — persistent state и поставка](docs/architecture/decisions/D-002-sostoyanie-i-postavka.md)
  - [D-003 — файловый обмен](docs/architecture/decisions/D-003-failovyi-obmen.md)
- [Индекс решений](docs/architecture/decisions/decisions-log.md)
- [Архитектурный CHANGELOG](docs/architecture/CHANGELOG.md)
- [Backlog](docs/project/backlog.md)

## Границы MVP

Не входят Microsoft Tunnel/Azure Relay, code-server, browser IDE, собственный UI, публичные SFTPGo WebClient/WebAdmin, второй SFTP-контур SFTPGo и мультитенантная изоляция. Restart/recreate сохраняет данные, но не обещает продолжение in-flight задач. Persistence не заменяет backup.

Инструкции по установке и запуску появятся вместе с реализацией и будут подтверждены real-env приёмкой; до этого команды запуска здесь не публикуются как работающие.
