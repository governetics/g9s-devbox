# Architecture Decision Records — Index

Навигационный индекс ADR. Каждое решение = отдельный файл в этом каталоге
(`D-NNN-<slug>.md`); non-md артефакты решения — в sidecar-директории `D-NNN/`.
Новое решение = новый файл + новая строка ниже.

Политика индекса — **prune разрешён**: SUPERSEDED ADR удаляется из таблицы с
пометкой в git-истории; сам файл может остаться (на него смотрят cross-ref).
Амендменты живут append-only секциями `## Amendment A-N` внутри файла ADR.

## Активные

| ID | Дата | Статус | Решение (1 строка) | Амендменты | Файл |
|---|---|---|---|---|---|
| D-001 | 2026-11-16 | ACTIVE | Runtime: Debian+tini+sshd, client-owned VS Code Server, pinned extensions/CLI, native on-demand agents | — | [D-001](D-001-runtime-devbox.md) |
| D-002 | 2026-11-16 | ACTIVE | Persistent host-root, UID/SSH identity, единый local/Path A compose и public registry delivery | — | [D-002](D-002-sostoyanie-i-postavka.md) |
| D-003 | 2026-11-16 | ACTIVE | Sibling SFTPGo/Samba, HTTPS WebDAV, SMB 445, selective home/workspaces export | — | [D-003](D-003-failovyi-obmen.md) |

## Superseded / dropped

| ID | Дата | Кем заменён | Файл |
|---|---|---|---|
| _(пусто)_ | | | |
