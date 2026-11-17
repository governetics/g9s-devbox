# Architecture — as-is

Текущее состояние системы (as-is). Целевое состояние (to-be) — [vision.md](vision.md); история изменений — [CHANGELOG.md](CHANGELOG.md); индекс решений — [decisions-log.md](decisions/decisions-log.md).

Этот файл — **as-is source of truth**: описывает систему как она есть сейчас, без сессионных нарративов и фазовых статусов (их дом — `../project/implementation-plan.md` и CHANGELOG).

---

## Обзор

На 2026-11-17 продуктовая реализация отсутствует. Создан локальный git-репозиторий с основной веткой `main`; контейнеры, compose, образы, скрипты и опубликованные пакеты ещё не созданы. Remote к репозиторию не подключён, публикация и deploy не выполнялись.

Архитектура MVP ратифицирована оператором и зафиксирована в D-001…D-003. Наличие ADR не означает наличие работающего runtime или подтверждённых real-env свойств.

## Компоненты

Продуктовые компоненты в репозитории пока отсутствуют. Существуют только project-owned документы:

- целевая архитектура [vision.md](vision.md);
- [D-001](decisions/D-001-runtime-devbox.md) — runtime и жизненный цикл;
- [D-002](decisions/D-002-sostoyanie-i-postavka.md) — persistent state и поставка;
- [D-003](decisions/D-003-failovyi-obmen.md) — файловый обмен;
- [план реализации](../project/implementation-plan.md).

Целевые sibling-сервисы `devbox`, `sftpgo`, `samba` ещё не реализованы и не запущены.

## Потоки данных

Фактических потоков данных нет: workspace, persistent state, SSH/SFTP, WebDAV и SMB пока существуют только как ратифицированные контракты to-be архитектуры.
