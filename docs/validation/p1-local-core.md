# Validation report — P1 local core (g9s-devbox)

**Дата:** 2026-11-17 · **Фаза:** P1 ([implementation-plan](../project/implementation-plan.md)) · **Сессия:** impl `261117-01` · **Итог: V01–V18 — доказано** на Linux-узле real-env пробами.

Отчёт для операторов. Коды итогов: `доказано` — критерий выполнен и улика сохранена; `отказ` — проверка исполнена, но критерий нарушен; `не доказано` — шаг не выполнен/прерван. Имена файлов улик — артефакты impl-сессии `261117-01` в доме проекта (workbench): `01–07` лежат в корне каталога сессии, `08+` — в его подкаталоге `evidence/`; в таблице ниже — имена файлов, не ссылки. Данный отчёт не является приёмкой P2–P6 и не разрешает commit/push/deploy/публикацию.

## Среда

- **Узел:** `g9s-devbox` (`10.0.0.100`), выделенный Linux-хост в LAN; доступ оператора — прямой key-only SSH (uid/gid `1000:1000`, `sudo -n`); jump-хост использован как независимая LAN client-позиция для port scan.
- **ОС:** Ubuntu 24.04, x86_64, kernel `6.8.0-149-generic`, glibc `2.39`, GLIBCXX `3.4.33` — проходит минимумы будущего toolchain (сами VS Code/агенты — P2, не проверялись).
- **Ресурсы:** 6 CPU; RAM ~7.7 GiB (available ~7.0 GiB); swap ~4 GiB (не считается рабочей памятью workload); свободно на `/` ~178 GiB. До P1 на узле работал один посторонний контейнер; наружу слушал только host SSH `:22`; `/var/lib/devbox` отсутствовал.
- **Docker:** Docker Engine + compose-плагин (local CLI; panel не использовалась).

## Pins и limits (согласованы оператором для этого узла)

- **Base image:** `debian:13-slim` по index digest `sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2` (linux/amd64 manifest `sha256:7378260…392`), создан 2026-11-04.
- **Package pins:** openssh-server/client `1:10.0p1-7+deb13u4` · tini `0.19.0-3+b8` · git `1:2.47.3-0+deb13u1` · curl `8.14.1-2+deb13u7` · ca-certificates `20250419+deb13u1` · iproute2 `6.15.0-1` · libstdc++6 `14.2.0-19`.
- **Limits (верхние границы, не резервирование):** CPU `6.0` (runtime `NanoCPUs=6000000000`) · memory `6656m` (runtime `Memory=6979321856`) · PIDs `1024`; логи json-file `10m × 3`; stop grace `30s`; health `30s / 5s / 3 / 15s`. Per-node: пересчитывать для нового узла (runbook §9).
- **Endpoint:** `10.0.0.100:2222` → контейнерный `22`. Host root: `/var/lib/devbox`.

## Состав артефактов P1

`.env.example` и `.gitignore`; `image/Dockerfile`, `image/entrypoint.sh`, `image/healthcheck.sh`, `image/sshd_config`; `scripts/host-prep.sh`, `scripts/p1-client-probe.sh`; `deploy/compose.yml`; `tests/test_p1.py`; [runbook оператора](../runbooks/p1-local-core.md). Секретов в VCS нет: `.env` gitignored, в логи/отчёт значения ключей не попали.

## Матрица V01–V18 (все — доказано)

| ID | Критерий (сжато) | Улики |
|---|---|---|
| V01 | Маршрут достигает именно `g9s-devbox`; Linux baseline kernel/glibc/libstdc++; sudo | `03-ssh-baseline.log`, `04-node-preflight.log`, `07-direct-access.log`, `45-host-glibcxx.log` |
| V02 | Static/textual pins и shell syntax; mutation self-tests краснеют; текстовые пины ≠ runtime | `21-linux-static-after-auth-fix.log` (24/24, 81 rejected controls, not_proven=0) |
| V03 | Валидный multiline `.env` даёт `compose config`; missing/empty ключи отказывают с именем ключа | `09-linux-static-tests.log`, `21-linux-static-after-auth-fix.log` |
| V04 | Несуществующий host-path отклоняет `up`; daemon не создаёт источник | `14-missing-host-path.log` (rc=1, `SOURCE_CREATED=no`) |
| V05 | Host-prep создаёт корни; идемпотентен; find-failure до мутаций; sentinel non-recursive | `10-host-prep-main.log`, `11-host-prep-find-failure.log`, `12-host-prep-unknown-nested.log`, `28-sentinel-and-start-persistence.log` |
| V06 | Image из согласованного digest; package pins; PID1 tini→sshd; без агентов/file-сервисов | `13-image-build.log`, `22-rebuild-recreate-auth-fix.log`, `16-runtime-inspect.log` |
| V07 | Первый `up`: root-owned marker, ed25519 identity, central list с двумя ключами; healthy | `15-first-up.log`, `16-runtime-inspect.log` (pre-auth-fix), `22-rebuild-recreate-auth-fix.log`, `42-final-state.log` (post-fix) |
| V08 | Оба ключа входят как `dev`; root denied; effective/auth list publickey-only; password-fixture даёт FAIL | `24-client-probe-macbook.log`, `25-client-probe-minipc.log` (по 9/9 PASS), `27-password-fixture-negative.log` (8 PASS + ровно 1 ожидаемый FAIL) |
| V09 | SFTP put/get/rename; `system/` denied; `docker.sock`/host-home mounts отсутствуют | `24…25`, `43-final-client-probe.log` (byte-identical round-trip, все negative PASS) |
| V10 | Runtime mounts/restart/log/CPU/memory/PID limits; client scan видит только ожидаемое | `42-final-state.log` (post-fix limits), `41-client-port-scan-jump.log` |
| V11 | `restart` сохраняет marker/fingerprint/home/workspace; container ID не меняется | `28-sentinel-and-start-persistence.log`, `29-restart-recreate-persistence.log` |
| V12 | `up --force-recreate` сохраняет state/identity/workspace; container ID новый | `29-restart-recreate-persistence.log` |
| V13 | Revoke minipc + recreate: Mac positive / minipc denied; home-only key denied; re-add восстанавливает оба | `30-revoke-recreate.log` … `36-final-minipc-positive.log`, вкл. `33-home-bypass-denied.log`; `46-restart-not-rotation.log` + `47-plain-restart-old-key-positive.log` (one-key `.env` + plain restart: центральный список остался прежним two-key, отозванный ключ продолжает входить); финальный restore — `48-final-restore-after-restart-negative.log`, `49-final-state-after-all-probes.log` (recreate → healthy, оба ключа) |
| V14 | Негодной authorized key отклоняется до sshd, без мутации state | `37-invalid-authorized-key-final.log` (rc=1; marker/fingerprint/workspace hashes совпали) |
| V15 | UID/GID и known-root owner/mode mismatch отклоняются до sshd | `38-identity-negative-suite-complete.log` (CASE_RESULT PASS по всем трём) |
| V16 | При живом marker потерянный host key → fail-before-sshd, не regenerate; restore сохраняет fingerprint | `38-identity-negative-suite-complete.log`, `44-host-key-restore-final.log` |
| V17 | Unknown schema/nonempty отклоняются; entrypoint find-failure не создаёт marker/key/sshd | `38-identity-negative-suite-complete.log`, `39-entrypoint-find-failure.log` |
| V18 | Финал: один healthy `devbox`, оба ключа, workspace hashes, нет лишних listeners/fixtures | `42-final-state.log`, `43-final-client-probe.log`, `49-final-state-after-all-probes.log` |

Примечание к V17: первая попытка find-инъекции внутри suite `38` не сработала (fail-open самой пробы, `CASE_RESULT: FAIL`) — контейнер стартовал; повтор с корректной инъекцией (`39-entrypoint-find-failure.log`) дал немедленный FATAL `rc=42` до seed/marker/sshd и нулевые мутации. Засчитана вторая, корректно исполненная проба.

Примечание к V16: полный цикл loss/restore доказан на отдельном временном корне (`44-host-key-restore-final.log`): до потери снят fingerprint, при живом marker удаление host-key даёт `LOST_KEY_EXIT=1` (FATAL до sshd, seed-only — regenerate отказан), restore из intact-копии возвращает healthy с идентичным приватным fingerprint (`ORIGINAL_PRIVATE_FP` = `RESTORED_PRIVATE_FP`), `CLEANUP: PASS`. Первая попытка того же прогона (`44-host-key-restore.log`) оборвана harness timeout сразу после host-prep, без RESULT — не засчитана; засчитан финальный, корректно завершённый прогон.

## Auth-path RCA и решение оператора (вариант A)

Первоначальный runtime-путь центрального списка — `/var/lib/devbox/system/authorized_keys` (root 0600 под `system/` 0700). При формально healthy sshd реальный login MacBook-ключом завершался `Permission denied (publickey)`; клиентская батарея корректно вышла NOT_PROVEN на precheck (`17-client-probe-macbook.log`, `18-ssh-auth-debug.log`). Изолированный loopback debug-fixture (`19-auth-debug-server.log`) показал последовательность `temporarily_use_uid: 1000/1000` → `restore_uid: 0/0` → `key is not allowed`: **OpenSSH 10 открывает AuthorizedKeysFile под identity целевого пользователя**, а `dev` намеренно не может traverse `system/` 0700. Ключ при этом совпадал с центральным fingerprint; основной контейнер при RCA не мутировался.

**Решение оператора — вариант A:** перенос runtime-списка в ephemeral `/etc/ssh/devbox/authorized_keys` — parent root:root 0755, файл root:root 0644, атомарная перематериализация из env на каждом старте. Это уточнение пути материализации, **не** смена решений D-002: central-only (без AuthorizedKeysCommand, без home-канала), env-authority и seed-only host keys сохранены; `system/` остаётся root-only. Подтверждено повторным build/recreate (`22-rebuild-recreate-auth-fix.log`, `20…23`) и реальными positive/negative login-пробами (V08–V09, V13). ADR-амендмент ревью не потребован. На деревьях, работавших до фикса, инертная старая копия в `system/` возможна; её чистка — отдельное действие оператора (runbook §6).

## Ключевые доказательства подробнее

- **Password fixture (отрицательный контроль чувствительности):** в отдельном loopback-only контейнере с намеренно password-enabled конфигом (`26-password-fixture-setup.log`) клиентская батарея (`27-password-fixture-negative.log`) дала 8 PASS + ровно один ожидаемый FAIL «server OFFERS password/keyboard-interactive» — проба действительно различает auth-поверхности; в боевом контейнере та же строка — PASS «not offered».
- **Ротация и home-bypass:** отзыв ключа `p1-minipc` в `.env` + `up -d --force-recreate` (`30`) → удержанный ключ Mac продолжает входить (`31`), отозванный получает явный `Permission denied (publickey)` (`32`), ключ, подложенный в `~dev/.ssh/authorized_keys`, входа **не** даёт (`33`), возврат обоих ключей восстанавливает оба логина (`34`–`36`). Plain `restart` набор ключей не меняет (runbook §6).
- **Port scan:** первый full-connect scan с Mac показал все 65 535 портов «open» — артефакт промежуточного TCP/proxy/fake-IP контура клиента, **не засчитан** (`40-client-port-scan.log`). Доказательный скан выполнен с LAN jump-позиции (`41-client-port-scan-jump.log`): 65 535 портов, открыты только host SSH `22` и devbox SSH `2222`.

## Изоляция прогона

Основной state-root `/var/lib/devbox` — только тестовые данные P1. Identity failure-мутации выполнялись на отдельных временных корнях под `/tmp`; password-контроль — отдельный loopback-only контейнер; основной state/config в negative fixtures не мутировался. Дорогой image build повторён один раз — после auth-path фикса. Временные fixtures удалены; финальное состояние — один healthy `devbox` с обоими ключами (`42`, `43`).

## Названные пределы P1

- **Local only.** Path A (панель governetics), Configure/Deploy/Reapply, push/publish и публичный образ не выполнялись и не заявляются.
- **Не доказано и не обещается:** desktop VS Code/Remote-SSH, extensions, CLI-агенты, LLM, WebDAV/SMB/SFTPGo, removal/redeploy, backup/restore — фазы P2–P6.
- **Host-root — trust boundary.** Узел/root остаётся держателем границы доверия; защита от произвольного tamper со стороны host-root (прямые правки дерева root'ом на хосте) вне пределов P1. `system/` root-only; центральный список root-owned, `dev` имеет ровно read.
- **Runtime central list ephemeral:** пересоздаётся из env на каждом старте; persistent identity — только marker/host keys в `system/`. Persistence ≠ backup.
- **In-flight работа не сохраняется:** restart/recreate останавливает процессы; продолжение не обещается.
- `healthy` и `docker inspect` не использовались как замена реальным SSH/SFTP операциям; оба ключа проверены отдельно.
