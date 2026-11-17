# D-002. Persistent state, SSH identity и поставка local/Path A (2026-11-16)

## Контекст

Workspace, пользовательский home, VS Code/agent state, SSH identity и file-service state должны переживать restart, recreate и removal/redeploy с тем же host-path. Path A удаляет named volumes через `down -v --remove-orphans`, поэтому они непригодны для переживаемого состояния devbox.

Один и тот же compose-шаблон обязан работать с local `.env` и через governetics `x-g9s-config` без второй редакции. Панель пропускает пустые обязательные значения через completeness; подстановка обязана завершаться `${KEY:?…}`. Writable user parents не должны позволять заменить SSH host keys или service/system state. Настройка UID/GID не должна превращать redeploy в рекурсивный обход дерева. Собственному образу нужен воспроизводимый registry-канал.

## Решение

**(а) Единый host root.** Обязательный `DEVBOX_HOST_PATH` монтируется в `devbox` как `/var/lib/devbox`. Раскладка: `home/`, `workspaces/`, `system/`, `services/`.

Идемпотентный host-prep — версионированный скрипт/runbook продукта, вызываемый до `compose up` оператором либо агентом с явно выданным host/root доступом; это не скрытый compose service. Он создаёт root и производные каталоги с явными владельцами и правами. Все bind-mounts используют длинный синтаксис и `create_host_path:false`; отсутствующие источники не создаются молча. `devbox` получает один root mount; sibling file services получают только выбранные производные binds по D-003. Named volumes для persistent state не объявляются.

**(б) Назначение областей.** `home/` — фактический `$HOME` пользователя `dev`, включая весь `.vscode-server`, `.claude`, `.claude.json`, `.config/opencode`, `.local/share/opencode` и прочее пользовательское состояние. `workspaces/` содержит рабочие проекты.

`system/` — root-only SSH host keys, identity/state-schema marker и runtime SSH trust metadata. `services/` — host-bind состояние SFTPGo/Samba; пользовательские сетевые export'ы туда не входят.

Root mount, `system/` и parent `services/` не принадлежат `dev`. Для `dev` запрещены read, write и traverse `system/`; restrictive permissions проверяются host-prep и negative probes. Сервисные контейнеры получают собственные child binds независимо от пользовательского traversal через общий root.

**(в) UID/GID и marker.** `DEVBOX_UID:DEVBOX_GID` настраиваются при первичной пустой инициализации и фиксируются root-owned marker'ом. Marker также несёт версию state schema; first boot отличается от recreate, restore и неизвестного непустого дерева.

На пустом first boot разрешены только non-recursive операции над подготовленными roots. Redeploy с теми же значениями проверяет marker, владельцев и writability, но не обходит дерево рекурсивно. Смена UID/GID, неизвестная schema, непустой state без marker или потерянные host keys вызывают fail-before-sshd. Adoption/UID migration — отдельная явная операция с отчётом; молчаливый recursive `chown` запрещён.

**(г) SSH identity и единый trust-channel.** Host keys живут в `system/` и создаются только на первичной инициализации. При существующем marker их отсутствие является потерей identity и останавливает запуск, а не вызывает генерацию новых ключей.

Публичные ключи доступа поступают через обязательный `DEVBOX_AUTHORIZED_KEYS` из local `.env`/Path A `envs`. Entrypoint валидирует каждую строку, создаёт root-owned файл и атомарно заменяет центральный authorized_keys при каждом старте. Пустое или негодное значение останавливает запуск до открытия SSH.

`sshd` использует только этот центральный список. Пользовательский `~/.ssh/authorized_keys` и host-file под `DEVBOX_HOST_PATH` не являются вторыми trust-channel: иначе сохранённый в home ключ мог бы пережить отзыв в панели и остаться неучтённым.

Добавление/отзыв ключа выполняется изменением `DEVBOX_AUTHORIZED_KEYS` и описанным restart/recreate; hot reload не обещается. Multiline и Path A configure → recreate подлежат real-env проверке. Публичные ключи не являются приватными credentials, но comments не должны содержать секреты.

**(д) Единый local/Path A шаблон.** Один compose содержит `devbox`, `sftpgo` и `samba`; расходятся только значения ключей и внешняя доставка конфигурации. У каждого объявленного ключа есть consumer; обязательные подстановки используют `${KEY:?…}`.

Маппинг ключей на имена окружения образов выполняется через `environment:`, где требуется, без затенения panel `env_file`. Операторские binds сохраняются; ручное дублирование panel-owned delivery channels не вводится. Пустые/отсутствующие обязательные значения и несуществующие host-path дают deploy-failed/ненулевой старт с причиной в логе.

**(е) Поставка образа.** Исходный репозиторий продукта — публичный `github.com/governetics/g9s-devbox`; образ публикуется в публичный GHCR. Каждый выпуск — immutable versioned image; Path A переписывает выбранную ссылку на digest. Обновление является явной сменой версии/дайджеста с последующим smoke, а не неявным `latest`.

До первого public push и каждого последующего release-акта обязателен secret scan рабочего дерева и git-истории. Найденный credential — инцидент с сигналом оператору, а не молчаливая чистка. `docker save/load` и on-node build не являются Path A-каналом без отдельного доказательства совместимости. Создание remote, публикация и deploy не выполняются design-сессией.

**(ж) Эксплуатация.** Каждый compose service получает healthcheck, `restart: unless-stopped`, JSON-file rotation и явные CPU/memory/PIDs limits. Health `devbox` проверяет конфигурацию/listener SSH и обязательные state roots, но не VS Code, authenticated login или LLM.

`unhealthy` сам по себе не запускает restart; `converged` не равен пользовательской работоспособности. Restart/recreate останавливает процессы и in-flight работу; stop grace не обещает дождаться завершения задач. Persistence не является backup: потеря host disk и application-inconsistent live copy не покрываются решением.

## Отвергнутые альтернативы

- **Named volumes** — несовместимы с требованием пережить штатное Path A removal.
- **Весь root прямо в `$HOME`** — смешивает пользовательский и SSH/service trust state и допускает замену через writable parent.
- **Обязательные nested mounts для каждого tool-state** — увеличивают host-prep и риск скрыть данные; полный home даёт более широкий persist без частного списка файлов.
- **Молчаливый recursive `chown`** — недетерминирован по времени и маскирует restore/UID ошибки.
- **Host-file или user-home authorized_keys как второй канал** — создаёт независимый, плохо отзываемый trust-channel.
- **Два шаблона для local и Path A** — создают двойную книгу топологии.
- **Registry-less save/load или on-node build** — не имеют доказанного digest/Path A контракта.
- **Mutable latest/auto-update image** — исключают воспроизводимость и проверенный upgrade.

## Последствия

Реализация получает одну state ownership matrix и явный host-prep контракт. Приёмка включает local fail-loud, real Path A deploy, restart/recreate и санкционированный removal/redeploy на тестовых данных.

Negative probes доказывают невозможность пользователя заменить `system/`, пройти через parent `services/`, получить лишние binds или использовать неучтённый user-home authorized_keys. Runtime-скан с клиентской позиции проверяет, что достижимы только согласованные поверхности; compose inspect без него не засчитывается.

План назначает владельца deploy/probe/removal и автора отчёта приёмки. Backup/restore проектируется отдельно для home, workspaces, SSH identity и service state. Смена state schema — явное release-событие; rollback после необратимой миграции не обещается.

SSH host-key persistence сохраняет known_hosts identity. Публичный GHCR снимает image pull-secret, но не другие секреты проекта. Ни один runtime/removal пункт не засчитывается по одному чтению шаблона или статусу `converged`.

## Открытое

- Конкретный перечень compose keys, bind/port names, log limits, CPU/memory/PIDs values и stop grace.
- Multiline/несколько SSH public keys и реальное Path A configure → recreate для `DEVBOX_AUTHORIZED_KEYS`.
- Центральный authorized_keys path, права и negative probe независимого user-home trust-channel.
- Host-prep: владельцы/modes root и производных каталогов, включая restrictive traversal `system/` и `services/`.
- Пустой first boot, restore непустого state, adoption, смена UID/GID и потеря host keys.
- Формат marker/state schema и процедуры будущих миграций/rollback.
- Local `compose config`, отсутствующие/пустые значения и host-path на целевой версии Compose.
- Первый immutable image, digest-pin и реальный governetics deploy после отдельных санкций.
- Санкционированный destructive removal/redeploy.
- Backup/restore и application-consistent копия SQLite/service state.
- Реальные ресурсы узла и рабочая нагрузка для численных limits.

## Pre-conditions

- Оператор выделяет `DEVBOX_HOST_PATH` вне named volumes; host-prep до первого `up` выполняет оператор либо агент с явно выданным host/root доступом.
- Поведение Path A соответствует подтверждённым контрактам подстановки, consumer, digest-pin и removal.
- D-001 определяет runtime-потребителей home/UID/SSH trust; D-003 — selective binds и service-state consumers.
- Публичные repository/GHCR и права публикации доступны к моменту отдельного release-акта.
- Разрушающие испытания и реальные LLM credentials имеют самостоятельные санкции.

## Cross-refs

- [D-001](D-001-runtime-devbox.md) — runtime и client/agent state.
- [D-003](D-003-failovyi-obmen.md) — selective export и host-bind состояние файловых сервисов.
- [g9s-mediapump D-002](https://github.com/ancientGlider/g9s-mediapump/blob/8ed7822693d21e087d54e5e78e147448614b6a85/docs/architecture/decisions/D-002-integratsiya-governetics.md) — Path A, fail-loud binds, health и removal.
- [g9s-llm-gate D-002](https://github.com/governetics/g9s-llm-gate/blob/8b3be2833be07f4fa24300a43050eff9f6ddb890/docs/architecture/decisions/D-002-kontrakt-governetics.md) — единый local/Path A шаблон и environment mapping.
- [g9s-edge D-001](https://github.com/governetics/g9s-edge/blob/be12e113a618a0ac10e4ecf2212c54fe5e49d1d4/docs/architecture/decisions/D-001-goveredge-scope.md) — owned custom image и registry publication.
- [g9s-mediapump compose](https://github.com/ancientGlider/g9s-mediapump/blob/8ed7822693d21e087d54e5e78e147448614b6a85/deploy/compose.yml) — long binds, restart, health и log rotation.
