# g9s-devbox

Контейнерная среда удалённой разработки под управлением governetics. Целевой контур: официальный desktop VS Code через Remote-SSH, Claude Code и OpenCode на удалённой стороне, постоянные workspace/state и файловый обмен через OpenSSH SFTP, HTTPS WebDAV и SMB.

## Статус

**P1 local core реализован и проверен на Linux-узле (2026-11-17).** Работают и доказаны real-env пробами: один контейнер `devbox` (`tini` + sshd), host-prep, persistent state/identity, central-only authorized_keys, seed-only host keys, SSH/SFTP под непривилегированным `dev`. Итог приёмки — V01–V18 «доказано» в [validation report](docs/validation/p1-local-core.md).

**P2–P6 pending, не обещаны:** desktop VS Code/Remote-SSH, CLI-агенты и LLM, SFTPGo/Samba/WebDAV/SMB, governetics Path A (Configure/Deploy/Reapply), публичный образ, removal/redeploy и backup. Их упоминания в этом README и в [vision](docs/architecture/vision.md) — цель, а не текущая функциональность. Репозиторий локальный: remote/push/publish/deploy не выполнялись.

## Быстрый старт (P1, local CLI)

Краткая версия; полная процедура, отказные ветки, ротация ключей и переносимость — в [operator runbook](docs/runbooks/p1-local-core.md).

```
cp .env.example .env   # заполнить: host path, UID/GID, публичные SSH-ключи, bind/port, limits
set -a; . ./.env; set +a   # trusted loader: экспортировать СВОЙ только что заполненный .env (подробнее — runbook §2.1)
sudo bash scripts/host-prep.sh --path "$DEVBOX_HOST_PATH" --uid "$DEVBOX_UID" --gid "$DEVBOX_GID"
docker compose --env-file .env -f deploy/compose.yml up -d --build
ssh -p 2222 dev@10.0.0.100    # key-only; SFTP — тем же endpoint
```

Ротация ключей = правка `.env` + `up -d --force-recreate` (plain `restart` не перечитывает `.env`); доверенная поверхность — только центральный список, home-файл входа не даёт.

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
- [Runbook оператора P1](docs/runbooks/p1-local-core.md)
- [Validation report P1](docs/validation/p1-local-core.md)
- ADR:
  - [D-001 — runtime и жизненный цикл](docs/architecture/decisions/D-001-runtime-devbox.md)
  - [D-002 — persistent state и поставка](docs/architecture/decisions/D-002-sostoyanie-i-postavka.md)
  - [D-003 — файловый обмен](docs/architecture/decisions/D-003-failovyi-obmen.md)
- [Индекс решений](docs/architecture/decisions/decisions-log.md)
- [Архитектурный CHANGELOG](docs/architecture/CHANGELOG.md)
- [Backlog](docs/project/backlog.md)

## Границы MVP

Не входят Microsoft Tunnel/Azure Relay, code-server, browser IDE, собственный UI, публичные SFTPGo WebClient/WebAdmin, второй SFTP-контур SFTPGo и мультитенантная изоляция. Restart/recreate сохраняет данные, но не обещает продолжение in-flight задач. Persistence не заменяет backup; защита от произвольного tamper со стороны host-root не заявляется.
