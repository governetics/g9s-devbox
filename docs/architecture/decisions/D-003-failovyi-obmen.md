# D-003. Файловый обмен: OpenSSH SFTP, WebDAV и Samba (2026-11-16)

## Контекст

Devbox требует удобного чтения/записи одних и тех же данных через OpenSSH SFTP, постоянный HTTPS WebDAV и стандартный SMB с единым UID/GID. SFTPGo и Samba не устанавливаются внутрь runtime-контейнера: его PID 1 и native-agent модель не должны зависеть от файловых сервисов.

Path A removal делает named volumes непригодными для SFTPGo DB и Samba passdb/state. Сетевой export включает secrets-bearing home по прямому решению оператора, но не `system/` и `services/`. Рабочий mediapump подтверждён оператором в Finder и других SMB-клиентах; это действующий прецедент. Публичные WebClient/WebAdmin в продукт не добавляются.

## Решение

**(а) Топология.** Compose содержит sibling-сервисы `devbox`, `sftpgo`, `samba` в изолированной сети проекта без общего PID namespace. Проект размещается на отдельном узле, где Samba занимает стандартный TCP/445.

Наружу существуют только согласованные SSH, WebDAV backend для edge и SMB поверхности. OpenCode API/UI и дополнительные file ports не публикуются. Сбой/настройка file service не меняет `tini + sshd` внутри `devbox`.

**(б) OpenSSH SFTP.** OpenSSH SFTP остаётся fallback и использует уже опубликованный SSH endpoint и обычные filesystem permissions пользователя `dev`. SFTP-сервер SFTPGo выключен; отдельного SFTPGo SFTP-порта нет.

OpenSSH SFTP не объявляется новым chroot/ACL-контуром: export-граница SMB/WebDAV на него не распространяется. Отдельная negative probe проверяет, что чтение `/var/lib/devbox/system/` через SFTP отклоняется Unix permissions.

**(в) Постоянный WebDAV через edge.** SFTPGo предоставляет WebDAV; g9s-edge терминирует HTTPS и маршрутизирует выбранный внешний route на host `адрес:порт` SFTPGo. WebDAV — единственная публичная HTTP-функция. WebClient не используется. WebAdmin/REST нужны только bootstrap и ротации: они остаются internal-only, без host publication, с доступом через loopback либо SSH `LocalForward` из devbox к внутреннему `sftpgo` endpoint. Их включение внутри не делает их публичной поверхностью.

Backend bind ограничивается адресом, достижимым edge, а не безусловным `0.0.0.0`. `proxy_allowed` используется только для доверия forwarded header и не считается ACL.

Для запрета прямого не-edge HTTP используется native global SFTPGo IP allowlist. Записи включают измеренный edge source, loopback health и явно необходимые internal admin sources. Allowlist глобален: поэтому наружу остаётся только WebDAV, а internal admin sources перечисляются отдельно. Молчаливый fallback в allowlist-off запрещён.

Setup state machine обязателен:

1. Setup-only `allowlist_status=0` на тестовых данных и без public route — состояние «не доказано», не зелень.
2. Non-edge positive control достигает HTTP auth и доказывает чувствительность последующей negative probe.
3. Entries заполняются и читаются обратно через loopback либо internal-only WebAdmin/REST, доступный по SSH `LocalForward`; публичный admin endpoint не создаётся.
4. `allowlist_status=1` включается и читается обратно.
5. Тот же non-edge клиент отбрасывается до auth; edge-positive проходит.

Lockout recovery — только operator maintenance: public route выключен, явный `allowlist_status=0` + restart, repair/readback, повторное включение и обе пробы. До завершения состояние остаётся «не доказано».

Defender включён; реальный client IP передаётся согласованным forwarded-header механизмом. Backend edge → SFTPGo остаётся HTTP: HTTPS защищает клиентский участок, но не шифрует внутренний edge → backend hop. Прямой не-edge HTTP устраняется allowlist, а не одним bind/`proxy_allowed`.

**(г) SMB и выбранный export.** Samba использует рабочий образ/native configuration approach mediapump и стандартный порт 445. `home/` и `workspaces/` монтируются как `/export/home` и `/export/workspaces`; единственная шара публикует `/export`. `system/` и `services/` в export-контейнер не монтируются.

Образ по умолчанию ставит `wide links=yes`; devbox явно задаёт **`wide links=no`** и сохраняет **`follow symlinks=yes`**. Внутренние symlinks продолжают работать, а absolute/relative переходы за пределы шары запрещаются. Insecure wide links не включаются.

Контрольная мутация выполняется только на подготовленных тестовых данных после operator checkpoint:

1. Effective-config readback `wide links=no`, restart/reconnect.
2. Internal symlink работает; absolute и relative escapes в `/etc` и service state отклоняются.
3. Переключение `yes`, restart, readback и reconnect; escape-positive доказывает чувствительность пробы.
4. Обязательное восстановление `no`, restart/readback/reconnect и повтор безопасных проб.

Улики обеих сторон и финальный effective `no` сохраняются. Без восстановления приёмка не зелёная.

SFTPGo получает только home/workspaces binds; localfs запрещает symlink target вне home root, а создание symlink остаётся выключенным. Service DB находится вне пользовательского export. Mount audit и direct/traversal/symlink/canary probes доказывают границу, а не только отсутствие записей в compose.

**(д) Единый владелец.** Все writers используют один `DEVBOX_UID:DEVBOX_GID`. SFTPGo запускается с arbitrary numeric `user: UID:GID` и пишет export и собственное состояние без root. Samba получает служебную учётную запись с numeric uid/gid и применяет `force user`/`force group`.

Двухступенчатый host-side/deploy preflight не монтирует `system/` в Samba:

- до `up` читает root-owned marker на хосте и проверяет source Samba uid/gid + force user/group;
- после старта operator/agent на host-side канале получает effective Samba config и numeric identity служебного пользователя и сравнивает с marker, fail-loud блокируя SMB-writer при mismatch.

Local и Path A используют одинаковый runbook. Post-fact numeric-owner probe остаётся независимой приёмкой.

Наследуются однородные file/directory masks и `fruit:nfs_aces = no`, чтобы macOS Finder не разрушал UNIX-права. Host-prep задаёт владельцев export roots; молчаливый recursive `chown` запрещён. Следствие единого владельца — отсутствие per-person file ownership/audit на диске.

**(е) Service state и host-prep.** SFTPGo DB/config state и Samba passdb/state размещаются только в отдельных подкаталогах `DEVBOX_HOST_PATH/services/`. Named volumes не используются; removal/redeploy с тем же root сохраняет пользователей и состояние сервисов.

Идемпотентный host-prep создаёт service/export каталоги до `up` и проверяет arbitrary UID writability. Каждый сервис получает только свои state binds; пользовательский root/export не включает чужую service DB.

**(ж) Fail-loud наследие mediapump.** Samba config обязан существовать, разбираться и содержать пользователей/шару; иначе контейнер завершает старт ненулевым кодом. Ошибочный этап native Samba configuration роняет контейнер, а не оставляет частично применённый конфиг.

Обязательные export/state paths проверяются до запуска; пустые обязательные keys используют общий `${KEY:?…}` контракт D-002. Пароли Samba генерируются без `$`, поскольку native YAML/image expansion может молча исказить значение.

Native config авторитетен при старте: изменение пароля/конфигурации требует описанного apply/restart, а ручная client-side смена не считается persistent источником. Healthchecks минимальны; реальные WebDAV/SMB user-path проверки остаются обязательной приёмкой.

**(з) Принятый риск home.** SMB и WebDAV выдают home вместе с agent credentials, auth-state и другими пользовательскими секретами. Любой получивший соответствующий file-service доступ может читать эти секреты в пределах выданных прав; HTTPS не устраняет authorization risk.

Риск принят для single-operator LAN/HTTPS контуров и должен быть явно отражён в README и отчёте приёмки. `system/` и `services/` при этом не экспортируются.

## Отвергнутые альтернативы

- **SFTPGo/Samba внутри `devbox`** — связывают file-service lifecycle с SSH/VS Code/agents и требуют другого supervisor.
- **SFTPGo SFTP вместо OpenSSH fallback** — дублирует протокол и добавляет порт без необходимости.
- **Публичные WebClient/WebAdmin** — расширяют attack/user surface сверх ратифицированного WebDAV.
- **Export всего `DEVBOX_HOST_PATH`** — раскрывал бы SSH trust и service state.
- **Named volumes для service state** — удаляются Path A removal.
- **Разные UID/GID у писателей** — создают чередующиеся отказы записи и неоднородные права.
- **Нестандартный SMB-порт или общий узел с конфликтом 445** — отвергнуты выбором отдельного хоста и стандартного клиентского SMB.
- **`follow symlinks=no`** — запрещал бы полезные внутренние ссылки; требуется только запрет wide links.
- **Прямой LAN HTTP как не названный риск** — не принимается; нужен edge-only allowlist и negative probe.
- **Публичный forward-auth перед WebDAV** — не вводится: аутентификация остаётся в приложении.

## Последствия

Runtime `devbox` сохраняет `tini + sshd`. Реализация наследует рабочие Samba/macOS настройки mediapump, не копируя named volumes и media-specific gates. Прецедент mediapump и upstream-документация не являются доказательством runtime devbox: все свойства остаются целевыми до собственной приёмки этой поставки.

Приёмка включает OpenSSH SFTP, WebDAV через реальный edge, Finder и другие SMB-клиенты, read/write и единый numeric owner. Persistence matrix отдельно проверяет SFTPGo DB и Samba state через restart/recreate и санкционированный removal/redeploy.

Отдельные probes доказывают edge-only backend, Samba/SFTPGo symlink boundaries и исключение system/services. План назначает operator/agent владельцев desktop/network проверок и автора отчёта.

Прямой HTTP edge → backend hop и отсутствие per-person disk audit остаются названными пределами. Secrets-bearing home требует явной документации; сужение export до workspaces было бы новым решением.

## Открытое

- Версии SFTPGo/Samba images, имена пользователей/шары и безопасный канал credentials.
- Начальное администрирование SFTPGo и ротация пользователей без публичного WebAdmin.
- WebDAV host bind/port, trusted edge proxy range, внешний route/FQDN и DNS.
- Измеренный edge source, persistent global allowlist bootstrap/readback/recovery и internal admin sources.
- Source IP, defender и forwarded-header поведение через реальный edge; non-edge negative probe.
- Занятость 445 на выделенном узле и подключение клиентов по имени/IP; network discovery через NAT не обещается.
- Arbitrary numeric user SFTPGo на пустом и восстановленном host-bind state.
- Host-side source/effective Samba UID/GID ↔ marker и блокировка writer при mismatch.
- Эквивалентность прав/владельцев во всех протоколах, включая Finder и чужой nested ownership.
- Fail-loud probes Samba config, export/state paths и пустых обязательных keys.
- Wide-links mutation/readback/restore и финальный effective `no`.
- Неизвестные Samba parameters могут игнорироваться upstream; требуется реальный config test.
- Санкционированный removal/redeploy, backup/restore service DB/passdb и live-copy consistency.
- Численные health/restart/log/resource параметры наследуют общий процесс D-002.

## Pre-conditions

- D-001 даёт OpenSSH SFTP fallback; D-002 — общий host root, UID/GID marker, fail-loud compose и host-prep.
- Выделенный узел допускает Samba на 445; required derived paths подготовлены до `up`.
- g9s-edge достигает WebDAV backend и предоставляет HTTPS route; настройка edge — внешний операторский акт.
- Оператор принимает выдачу secrets-bearing home и отсутствие per-person file ownership.
- Реальные клиенты, DNS/имена, credentials и destructive/security-mutation tests доступны на соответствующих чекпойнтах.

## Cross-refs

- [D-001](D-001-runtime-devbox.md) — SSH/SFTP fallback и неизменный runtime devbox.
- [D-002](D-002-sostoyanie-i-postavka.md) — host root, UID/GID, service state и persistence/removal policy.
- [g9s-mediapump D-001](https://github.com/ancientGlider/g9s-mediapump/blob/8ed7822693d21e087d54e5e78e147448614b6a85/docs/architecture/decisions/D-001-sostav-i-topologiya.md) — SMB/445, единый владелец, macOS и права.
- [g9s-mediapump D-002](https://github.com/ancientGlider/g9s-mediapump/blob/8ed7822693d21e087d54e5e78e147448614b6a85/docs/architecture/decisions/D-002-integratsiya-governetics.md) — WebDAV/edge, SFTP off, defender и Samba fail-loud.
- [g9s-mediapump compose](https://github.com/ancientGlider/g9s-mediapump/blob/8ed7822693d21e087d54e5e78e147448614b6a85/deploy/compose.yml) и [Samba example](https://github.com/ancientGlider/g9s-mediapump/blob/8ed7822693d21e087d54e5e78e147448614b6a85/deploy/samba.example.yml).
- [SFTPGo 2.7 configuration](https://docs.sftpgo.com/2.7/config-file/) и [localfs](https://docs.sftpgo.com/2.7/localfs/).
- [Samba `wide links`](https://www.samba.org/samba/docs/4.23/man-html/smb.conf.5.html#WIDELINKS) и [`follow symlinks`](https://www.samba.org/samba/docs/4.23/man-html/smb.conf.5.html#FOLLOWSYMLINKS).
- [`crazymax/samba` 4.23.8-r0 defaults](https://github.com/crazy-max/docker-samba/blob/9a3f8627d8bb1d9901865ed72941c7fa68610535/rootfs/etc/cont-init.d/01-config.sh#L70-L72).
