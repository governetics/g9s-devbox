# D-001. Runtime devbox: client-owned VS Code и native-агенты (2026-11-16)

## Контекст

Devbox предоставляет desktop VS Code Remote-SSH, удалённые расширения и standalone CLI Claude Code/OpenCode, git и OpenSSH SFTP. Пользовательские процессы непривилегированны; `docker.sock`, секреты домашнего каталога хоста, code-server, Microsoft Tunnel/Azure Relay и собственный UI исключены.

VS Code официально отдаёт установку и обновление Remote-SSH Server desktop-клиенту. Alpine/musl не поддерживается; kernel, glibc и libstdc++ являются входными требованиями. Claude Code и OpenCode уже имеют native background modes, поэтому отдельный application supervisor не является отправной необходимостью.

Этот ADR фиксирует runtime контейнера `devbox`. Постоянные пути, SSH trust и поставка закрепляются в [D-002](D-002-sostoyanie-i-postavka.md); файловые sibling-сервисы — в [D-003](D-003-failovyi-obmen.md).

## Решение

**(а) Базовый образ и PID 1.** Используется pinned Debian 13 slim с OpenSSH server, `tini`, git и необходимыми пользовательскими инструментами. При сборке и на узле проверяются kernel ≥4.18, glibc ≥2.28, libstdc++ ≥3.4.25 и остальные документированные prerequisites.

`tini` — PID 1; root-bootstrap проверяет state/identity и затем запускает `sshd -D -e`. `systemd`, s6 и собственный service manager в `devbox` не вводятся. Root требуется bootstrap и SSH privilege separation; login-shells, VS Code Server и агенты выполняются под `DEVBOX_UID:DEVBOX_GID`.

**(б) VS Code Server.** Образ не содержит предустановленный Remote-SSH Server. Desktop VS Code устанавливает и обновляет server при подключении. Persist-единицей является весь `~/.vscode-server` в persistent home. Пустой каталог до первого подключения — нормальное состояние, а не ошибка healthcheck.

Recreate сохраняет server/state, но не запрещает клиенту обновить server при следующем подключении. Откат системного образа поэтому не означает откат client-managed VS Code Server.

**(в) Extensions.** Продукт несёт версионированный manifest с `anthropic.claude-code` и `sst-dev.opencode`. Каждая запись фиксируется как `publisher.id@version`; конкретные версии — вход реализации.

Convergence выполняется после первого Remote-SSH-подключения через documented remote `code` CLI в integrated terminal. Operator-visible runner применяет manifest и сверяет `--list-extensions --show-versions`. `extensions.autoUpdate` отключается, чтобы background update не отменял пины; проверка наличия обновлений может оставаться включённой.

До первого подключения наличие server и extensions не обещается. Pre-connect заполнение внутренних каталогов server и недокументированные CLI paths продуктовым контрактом не являются.

**(г) Standalone CLI.** Официальные пакеты Claude Code и OpenCode устанавливаются в system image с явно закреплёнными версиями. Документированные auto-update механизмы отключаются; обновление означает смену пина, новый immutable image и smoke.

Claude extension содержит собственный bundled CLI и не обязан помещать `claude` в PATH. Версии bundled и standalone Claude CLI по возможности выравниваются, без недокументированного требования равенства. OpenCode extension и standalone CLI версионируются независимо.

**(д) Жизненный цикл агентов.** Claude Code использует native `claude --bg`; OpenCode — per-user native background service/`opencode service`. Always-on `opencode serve` под container supervisor не запускается. Отсутствие idle background service не является контейнерной деградацией. Native user-local socket/listener допускается, если он нужен выбранной версии OpenCode; новые host-published listeners и порты для OpenCode web/API не создаются. Cold start и фактические listener/socket endpoints проверяются real-env.

**(е) Credentials.** Основной пользовательский путь — интерактивный login в integrated terminal внутри devbox; SSH на физический сервер не требуется. Auth-state сохраняется в persistent home; env/token-каналы остаются опцией unattended-режима.

Git credentials в образ не встраиваются. SSH agent forwarding допускается только как осознанный opt-in к доверенному devbox; он позволяет уже аутентифицированной сессии использовать локальный agent и не является вторым authorized_keys login-каналом. Реальные LLM-запросы в приёмке выполняются только после отдельного credentials-чекпойнта.

**(ж) Названные пределы.** SSH disconnect, закрытие окна VS Code и reconnect не имеют априорной гарантии сохранения terminal, extension host или активного turn. Restart/recreate сохраняет файлы, но останавливает процессы и in-flight работу; native background mode не является durable job queue.

При выбранном `tini` ordered application shutdown и чистый SQLite close OpenCode на каждом stop не гарантируются. Container health не доказывает VS Code readiness, authenticated login, extension convergence или работоспособность LLM.

## Отвергнутые альтернативы

- **Ubuntu 24.04 LTS** — технически жизнеспособна, но оператор выбрал Debian; это не отбраковка Ubuntu по дефекту.
- **Alpine/musl** — исключена официальной поддержкой Remote-SSH.
- **Preinstall VS Code Server** — противоречит client-owned установке/обновлению и создаёт быстро устаревающий слой.
- **Preload внутренних extension/server каталогов** — зависит от недокументированного формата и не заменяет post-connect CLI.
- **Boot-blocking extension sync** — зависел бы от server/CLI, который появляется только после client connection.
- **s6 + always-on OpenCode** — даёт ordered shutdown, но добавляет второй lifecycle, listeners и тесты без ратифицированной always-on потребности.
- **Unpinned/latest CLI** — делает recreate недетерминированным и отделяет проверенный образ от исполняемой версии.

## Последствия

CLI принадлежат образу; VS Code Server, extensions и auth-state — persistent home. Manifest extensions становится версионированным артефактом продукта, а его применение — видимым post-connect шагом.

Приёмка включает реальный desktop Remote-SSH, integrated terminal, git, standalone CLI и post-connect version smoke. Lifecycle-матрица покрывает IDE close, SSH disconnect/reconnect, cold start native services, restart и recreate.

До прогона каждая строка lifecycle-матрицы фиксирует ожидаемое поведение, наблюдаемые оси (процесс жив, состояние turn, сохранённый вывод, reconnect/resume), критерий зелёного и форму улики. Зелёный означает соответствие заранее заданному критерию, не обязательное продолжение задачи. «Прервано и документировано» может быть корректным исходом.

План назначает владельца каждой real-env пробы и автора отчёта. Отказы native background services могут быть видны пользователю CLI раньше, чем панели. Никакие runtime-свойства не считаются доказанными design-сессией.

## Открытое

- Конкретные пины базового образа, standalone Claude Code/OpenCode и обоих VS Code extensions.
- Форма manifest и operator-visible post-connect runner без опоры на недокументированные server paths.
- Baseline kernel/glibc/libstdc++ на реальном узле и в собранном образе.
- Cold start/autostart native Claude/OpenCode services после recreate и reconnect.
- OpenCode extension binary discovery и совместимость отдельно версионируемых extension/CLI.
- Судьба активного turn при SSH disconnect, IDE close, restart и host reboot по протоколу выше.
- Сочетание `id@version`, `extensions.autoUpdate:false` и последующей явной смены пина.
- Client-managed VS Code Server update при recreate и rollback системного образа.
- Credentials smoke и реальные LLM-запросы — после отдельной санкции.
- Численные resource limits и stop grace закрепляются через D-002 после измерений.

## Pre-conditions

- D-002 обеспечивает persistent home, неизменный UID/GID, SSH trust и единый local/Path A image contract.
- Desktop VS Code достигает опубликованного SSH-порта по LAN/VPN.
- Узел и образ проходят документированный Linux baseline.
- Оператор предоставляет версии extensions/CLI и credentials на соответствующих чекпойнтах.
- Публикация/выбор конкретного image version отделены от design-сессии.

## Cross-refs

- [D-002](D-002-sostoyanie-i-postavka.md) — persistent state, SSH identity, registry и compose-эксплуатация.
- [D-003](D-003-failovyi-obmen.md) — OpenSSH SFTP fallback и sibling file services.
- [VS Code Linux requirements](https://github.com/microsoft/vscode-docs/blob/0cc882e924eaf8239013fea1d6840be4179cfdb0/docs/remote/linux.md#L44).
- [VS Code Remote-SSH lifecycle/FAQ](https://github.com/microsoft/vscode-docs/blob/0cc882e924eaf8239013fea1d6840be4179cfdb0/docs/remote/faq.md#L48-L52).
- [VS Code extension CLI](https://github.com/microsoft/vscode-docs/blob/0cc882e924eaf8239013fea1d6840be4179cfdb0/docs/configure/command-line.md#L90-L96).
- [Claude Code background sessions](https://code.claude.com/docs/en/agent-view); [OpenCode CLI](https://opencode.ai/docs/cli/).
