# Implementation Plan — g9s-devbox MVP

Текущее состояние реализации по фазам — дом фазовых статусов и прогресса. История изменений — [CHANGELOG](../architecture/CHANGELOG.md); as-is — [architecture](../architecture/architecture.md); целевая архитектура — [vision](../architecture/vision.md).

## Стадия проекта

`exploration` — установлена 2026-11-13. Архитектура ратифицирована, реализация ещё не начата. Стадия не является основанием ослаблять названные свойства или приёмку.

## Целевой Tech Stack

- Debian 13 slim, OpenSSH server, `tini`, git.
- Desktop VS Code + Remote-SSH; client-managed VS Code Server.
- Claude Code и OpenCode: pinned standalone CLI + pinned remote VS Code extensions.
- SFTPGo WebDAV + `crazymax/samba` как sibling compose services.
- Docker Compose: один шаблон для local `.env` и governetics Path A.
- Публичный GitHub repository `github.com/governetics/g9s-devbox`; публичный GHCR image, immutable versions и digest-pin.

Конкретные версии, ресурсы и сетевые значения не выбираются этим документом вслепую; они утверждаются на соответствующих фазах.

## Инварианты реализации

1. Ратифицированные [D-001](../architecture/decisions/D-001-runtime-devbox.md), [D-002](../architecture/decisions/D-002-sostoyanie-i-postavka.md), [D-003](../architecture/decisions/D-003-failovyi-obmen.md) не меняются молча. Расхождение — `NEEDS_USER_DECISION`.
2. Один vertical slice за фазу; docs-before-commit. Коммит — только после отдельной операторской санкции.
3. Текстовые пины шаблона называются текстовыми и не заменяют runtime/real-env проверки.
4. `converged`, `healthy` и наличие процесса не засчитываются как пользовательская работоспособность.
5. LLM credentials/запросы, public publish, deploy, security mutation и destructive removal требуют самостоятельных чекпойнтов.
6. Секреты не попадают в код, документы, логи или git-историю. Найденный credential — инцидент, не молчаливая чистка.
7. Каждое real-env действие имеет владельца; непройденное — `отказ` либо `не доказано`, никогда молчаливая зелень.

## Фазы

| Фаза | Vertical slice | Статус | Дата |
|---|---|---|---|
| P0 | Архитектура, ADR и приёмочная матрица | DONE | 2026-11-17 |
| P1 | Local core: host-prep, SSH/SFTP, persistent identity, fail-loud baseline | TODO | — |
| P2 | Desktop VS Code, pinned extensions/CLI и git | TODO | — |
| P3 | Local SFTPGo/Samba, selective export и файловая persistence | TODO | — |
| P4 | Agent lifecycle и реальные LLM после credentials checkpoint | TODO | — |
| P5 | Public image, governetics и постоянный WebDAV через edge | TODO | — |
| P6 | Санкционированный removal/redeploy, backup/restore и финальная приёмка | TODO | — |

---

## P0 — архитектура и план

**Выход:** D-001…D-003, vision, as-is, README/CHANGELOG, настоящий план и impl-промпт в design-сессии.

**Gate:** независимые свободное/фокусированное ревью и property-pass; операторская ратификация. Код и compose не реализуются.

## P1 — local core и SSH/SFTP

**Prerequisites до Dockerfile:** оператор называет среду исполнения, `DEVBOX_HOST_PATH`, UID/GID и передаёт минимум два публичных SSH key для ротации через gitignored `.env` либо иной явно выданный secure channel. Конкретные base/tool pins и численные limits согласуются до завершения P1.

Unix ownership/mode/traversal gates засчитываются только на выбранном Linux-хосте с Docker Compose. macOS/Docker Desktop допускается для build и статических compose tests, но не доказывает host-prep ownership; если P1 идёт на macOS, эти строки остаются `не доказано` до Linux real-env. Host-prep выполняет оператор либо агент с явно выданным host/root доступом.

**Реализуется:** базовый образ и runtime `devbox`; host-prep; раскладка `home/workspaces/system/services`; UID/GID marker; central-only authorized_keys; seed-only host keys; fail-before-sshd. На P1 общий `deploy/compose.yml` содержит только `devbox`; P3 добавляет `sftpgo`/`samba` в тот же файл, без второй редакции local/Path A.

Базовый health P1 — `sshd` config/listener/banner и required state roots; не VS Code/LLM. Также задаются `restart: unless-stopped`, JSON-file rotation и явные CPU/memory/PID limits; значения согласуются, не остаются unlimited по умолчанию. Добавляются текстовые и runtime probes.

**Обязательные проверки:**

- `compose config` для валидного local `.env`; отсутствующие/пустые обязательные ключи отказывают громко.
- Несуществующий host-path не создаётся daemon'ом; пустой `${KEY:?…}` останавливает `up`.
- Host-prep идемпотентен; неверные modes/owners и неизвестный непустой state видимы.
- Первый запуск создаёт identity; recreate с тем же root сохраняет host-key fingerprint и marker.
- Несколько authorized keys, добавление и отзыв через restart; user-home authorized_keys не создаёт второй канал.
- Реальный SSH/SFTP login от `dev`; root/password login отклонены; SFTP put/get/rename.
- SFTP read `system/` → denied; `docker.sock` и host-home secrets отсутствуют.
- Runtime client-side scan подтверждает только предусмотренные на фазе поверхности.

**Gate P1:** local CLI probes и отчёт агента; docs обновлены; оператор разрешает коммит отдельной командой.

## P2 — реальный desktop VS Code и агентские инструменты

**Реализуется:** client-managed VS Code Server persistence; versioned extension manifest и operator-visible post-connect runner; pinned standalone Claude Code/OpenCode; auto-update policy; git smoke.

**Операционная матрица:**

| Поверхность | Операция и улика |
|---|---|
| Desktop Remote-SSH | Реальное подключение; remote terminal `id`; workspace open; remote server/extensions |
| Extensions | Manifest ↔ `code --list-extensions --show-versions`; mismatch = отказ |
| Git | Clone/public repo или local init, file write, commit; private push — отдельный credentials checkpoint |
| Claude Code | Standalone version; extension выполняется remote; без реального LLM до P4 |
| OpenCode | Version/debug paths; extension находит CLI; без реального LLM до P4 |
| Persistence | Restart/recreate: server, extensions, settings, CLI versions и workspace сохранены |

**Особые пробы:** baseline kernel/glibc/libstdc++; OpenCode binary discovery; post-connect pin/autoUpdate; client-managed server update; rollback image не считается rollback server.

**Gate P2:** оператор выполняет desktop GUI шаги; агент подтверждает remote CLI/state и записывает отчёт. Несделанный desktop шаг = `не доказано`.

## P3 — файловый обмен local

**Реализуется:** sibling `sftpgo` и `samba`; только home/workspaces export; host-bind service state; arbitrary UID/GID; Samba fail-loud config; OpenSSH SFTP fallback; SFTPGo SFTP off; local WebDAV и SMB probes.

**Обязательные проверки:**

- Finder и другой реальный SMB client: mount/read/write/rename/delete; server-side numeric owner одинаков во всех протоколах.
- OpenSSH SFTP работает в dev permissions; SMB/WebDAV ограничены выбранным export.
- Mount audit + direct/traversal probes: `system/` и `services/` не экспортируются.
- Samba `wide links=no`, `follow symlinks=yes`; internal symlink работает.
- Source и effective Samba UID/GID + numeric service identity сверяются с root-owned marker host-side/deploy preflight; mismatch блокирует writer. `system/` в Samba не монтируется.
- SFTPGo arbitrary UID на пустом и восстановленном state; symlink target вне root отклоняется.
- Samba missing/broken config, отсутствующие export/state paths и пустые keys отказывают громко.
- Restart/recreate сохраняет SFTPGo DB/host keys и Samba passdb/state; named volumes нет.

**Security mutation — только на подготовленных тестовых данных и после operator checkpoint:**

1. Effective `wide links=no` readback → restart/reconnect → safe probes.
2. `yes` → restart/readback/reconnect → absolute/relative escape-positive.
3. Восстановить `no` → restart/readback/reconnect → safe probes повторно.
4. Сохранить улики обеих сторон и финальный effective `no`; иначе фаза не зелёная.

**Gate P3:** operator подтверждает Finder/desktop шаги и mutation checkpoint; агент оформляет ownership/export/persistence отчёт.

## P4 — lifecycle и реальные LLM

**До credentials checkpoint:** только локальные process/session проверки без реальных LLM-запросов.

**Lifecycle-протокол:** до запуска каждая строка фиксирует режим агента (interactive/background), событие (IDE close, SSH disconnect, reconnect, cold start, restart/recreate), ожидаемое поведение, наблюдаемые оси (PID/process tree, turn/session state, output/log, reconnect/resume), критерий зелёного и путь улики. Запрещено подменять ожидание удобным постфактум объяснением.

**Матрица:** Claude Code extension/terminal/`--bg`; OpenCode extension/TUI/native service × IDE close, SSH disconnect/reconnect, cold start, restart/recreate. Отдельно проверяются сохранение auth/session history и отсутствие обещания automatic resume.

**После отдельного credentials checkpoint:** оператор предоставляет credentials безопасным каналом; выполняются реальные Claude Code/OpenCode задачи с tools/streaming и файловыми изменениями. Credentials не попадают в VCS/логи. Использование g9s-llm-gate — конфигурационная опция, не обязательная зависимость.

**Gate P4:** каждая строка имеет улику и честный исход; реальные LLM без checkpoint не выполняются.

## P5 — public image, governetics и edge

**Реализуется/выполняется:** публичный repository/GHCR release path; immutable image; один local/Path A compose; выделенный узел; реальный deploy; WebDAV FQDN/DNS/route через g9s-edge; persistent global SFTPGo allowlist.

**Pre-public gate:** secret scan рабочего дерева и git-истории; найденное — инцидент. Первый public push, image publish и deploy требуют отдельных операторских санкций.

**WebDAV allowlist state machine:**

1. Setup-only `allowlist_status=0` на тестовых данных без public route — не зелень.
2. Non-edge positive control достигает HTTP auth.
3. Entries через loopback/admin + readback: measured edge source, loopback health, internal admin sources.
4. Enable `allowlist_status=1` + readback.
5. Non-edge отказ до auth + edge-positive HTTPS/WebDAV read/write.
6. Lockout recovery только operator maintenance: public route off, явный `allowlist_status=0` + restart, repair/readback, re-enable и обе пробы. До завершения — `не доказано`.

**Remote acceptance:** реальный desktop Remote-SSH; CLI/extensions/git; OpenSSH SFTP; Finder/SMB; WebDAV через public HTTPS; client IP/defender; health/restart/log/resources; runtime scan непредусмотренных портов. `converged` сам по себе не засчитывается.

**Gate P5:** real-env отчёт и operator acceptance. Выпускной тег этим планом не разрешён.

## P6 — removal/redeploy, backup/restore и финал

**Destructive checkpoint:** removal/redeploy только на заранее подготовленных тестовых данных и после отдельной операторской санкции.

**Матрица до/после:** workspace hashes; VS Code Server/extensions/settings; Claude/OpenCode auth/session state; central SSH access и host-key fingerprints; UID/state marker; SFTPGo DB/host keys/users; Samba passdb/state; numeric ownership; отсутствие named volumes и непредусмотренных портов.

**Backup/restore:** отдельно проверить home, workspaces, SSH identity, SFTPGo DB и Samba state. Live SQLite copy не называется consistent без доказанного application-consistent метода. Restore и rollback после state-schema migration не обещаются без испытания.

**Финальный выход:** обновлённые README/as-is/CHANGELOG/план, operator runbooks, validation-отчёт, явные named limits и неподтверждённые пункты. Релиз/тег — отдельный деплой-протокол и решение оператора.

---

## Владельцы real-env действий

| Действие | Исполнитель | Санкция / выход |
|---|---|---|
| Local compose config/up/down CLI, inspect, local SSH/SFTP probes | агент | команды и логи в отчёте |
| Host-prep и Unix ownership/mode gates | оператор либо агент с явно выданным Linux host/root доступом | idempotent run + modes/owners evidence |
| Desktop VS Code GUI, post-connect extension runner | оператор при участии агента | checklist + agent CLI verification |
| Lifecycle-матрица P4: desktop events, agent process/session observations и улики | оператор выполняет GUI/disconnect; агент фиксирует process/session/output и отчёт | предзаданные per-row критерии; без оператора GUI = не доказано |
| Finder/другой desktop SMB client | оператор | агент фиксирует результат и server-side owner |
| WebDAV external client | оператор либо агент с явно предоставленным test credential | HTTPS/route/auth/read-write улики |
| g9s-edge route/DNS | оператор | внешний operator-act до remote acceptance |
| Public repository/package creation и первый publish | оператор; агент только после явной санкции | public repo/GHCR, digest |
| Governetics Configure/Deploy/Reapply | оператор; агент при наличии явно выданного доступа | real-env report |
| Реальные LLM credentials и запросы | оператор на отдельном checkpoint | smoke без секретов в логах/VCS |
| Samba wide-links security mutation | оператор санкционирует на тестовых данных; агент/оператор выполняет по runbook | обе стороны + восстановленный `no` |
| Removal/redeploy | оператор выполняет после отдельной санкции | pre/post hashes/state matrix |
| Runtime reachability и non-edge WebDAV controls | агент с выданным доступом либо оператор с клиентской позиции | positive/negative улики |
| Secret scan дерева и git-истории | агент; operator review первого public push | scan output; credential = инцидент |
| Mount audit и symlink canary | агент server-side + оператор SMB client | mount/effective-config/client logs |
| Host-side Samba UID/GID ↔ marker | агент локально; оператор на Path A host-side канале | source/effective readback; mismatch блокирует writer |
| Отчёт приёмки | агент; оператор подтверждает GUI/credentials/destructive строки | отказ/не доказано не превращается в зелень |

## Что потребуется от оператора

**Пункты 1–3 являются prerequisites до старта P1/Dockerfile**, а не отложенными пожеланиями. Публичные SSH keys передаются через gitignored `.env` или отдельно согласованный secure channel; остальные inputs нужны к своим фазам.

1. Выделенный Linux-хост: архитектура, kernel, Docker/Compose versions, ресурсы, свободный TCP/445 и LAN/VPN reachability; решение, где выполняется P1.
2. `DEVBOX_HOST_PATH`, желаемые UID/GID и host-prep/root доступ для первичной подготовки.
3. Публичные SSH keys в `DEVBOX_AUTHORIZED_KEYS`; при необходимости безопасная ротация.
4. Desktop VS Code + Remote-SSH и выполнение GUI/post-connect шагов.
5. Согласование конкретных pins CLI/extensions/images и численных CPU/memory/PID/log/stop limits после измерений.
6. SFTPGo admin/user credentials, Samba credentials, WebDAV FQDN/backend/proxy parameters — через panel/gitignored secret channel, не в VCS.
7. Настройка g9s-edge route/DNS и разрешение на реальные WebDAV проверки.
8. Создание/доступ к public GitHub repo и GHCR; отдельные санкции на push/publish/deploy.
9. Доступ к governetics и выполнение Configure/Deploy/Reapply либо явно выданные права агенту.
10. Реальные LLM credentials и разрешение запросов только на отдельном checkpoint.
11. Отдельные санкции на Samba security mutation и destructive removal/redeploy на подготовленных тестовых данных.
12. Решение о backup location/credentials перед P6.

## Сводная приёмочная матрица MVP

| ID | Сценарий | Фаза | Доказательство |
|---|---|---|---|
| M1 | Local up; пустой/несуществующий host-path fail-loud | P1 | compose/runtime logs; отсутствие созданного источника |
| M2 | Desktop Remote-SSH; remote server/extensions | P2/P5 | operator GUI + remote version/process/state |
| M3 | Git, Claude Code, OpenCode; LLM только после checkpoint | P2/P4/P5 | local/remote smoke и реальные задачи |
| M4 | IDE close/reopen, SSH disconnect/reconnect во время агента | P4 | предзаданная lifecycle-строка и улика |
| M5 | OpenSSH SFTP read/write | P1/P5 | put/get/rename + permissions |
| M6 | Restart/recreate без потери workspace/settings/auth/service state | P1–P3/P5 | state matrix и fingerprints |
| M7 | Governetics deploy и реальная работоспособность | P5 | real-env acceptance, не только converged |
| M8 | Removal/redeploy с тем же host-path | P6 | санкционированная pre/post матрица |
| M9 | Non-root agents, no docker.sock/host-home secrets/VCS secrets/unexpected ports | P1/P5 | inspect + client scan + tree/history secret scan |
| M10 | Постоянный WebDAV через HTTPS edge и edge-only backend | P5 | HTTPS read/write + allowlist state machine |
| M11 | SMB на 445 через Finder/другие клиенты | P3/P5 | реальные client operations и owner checks |
| M12 | Export home/workspaces, no system/services; единый UID/GID | P3/P5 | mount/negative/symlink/UID probes |
| M13 | Public repo/image без секретов | P5 | tree+history scan до push/release |

Неотмеченная строка не считается работающей по аналогии. Для каждой фазы отчёт различает `доказано`, `отказ` и `не доказано`.
