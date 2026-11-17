# Runbook P1 — local core и SSH/SFTP (g9s-devbox)

Операторский runbook фазы P1: подготовка узла, запуск одного `devbox`, доступ
по SSH/SFTP, ротация ключей и разбор отказных веток. Только локальный CLI
(`docker compose` на самом узле); panel Configure/Deploy/Reapply и публикация
образа — отдельные санкционированные фазы, здесь не описываются как
работающие.

Честные пределы P1 (не обещается):

- **Local only.** Path A (панель governetics), desktop VS Code Remote-SSH,
  extensions, CLI-агенты и LLM на этой фазе **не доказаны** и не заявляются.
- **In-flight работа не сохраняется.** Restart/recreate останавливает
  процессы; `stop_grace_period` лишь даёт sshd время на завершение, чистого
  shutdown пользовательских задач tini+sshd не гарантирует (D-001 (ж)).
- **Persistence ≠ backup.** Переживание restart/recreate с тем же host-path
  не защищает от потери диска; backup/restore — отдельная фаза (P6).
- **Host-root — trust boundary.** Узел/root остаётся держателем границы
  доверия; защита от произвольного tamper со стороны host-root (прямые
  правки дерева root'ом на хосте) вне пределов P1 и не заявляется.
- Healthcheck доказывает конфиг/listener/state roots и читаемость центрального
  списка как `dev`, но **не** пользовательский login, VS Code или LLM.

## 1. Prerequisites

- Linux-узел с Docker Engine и compose-плагином (на macOS/Docker Desktop
  допустимы только build и статические compose-тесты; ownership-гейты
  host-prep там не засчитываются).
- root-доступ на узле для host-prep (напрямую или через панель/jump — канал
  выбирает оператор).
- Решённые значения: `DEVBOX_HOST_PATH` (абсолютный путь вне системных
  корней; по умолчанию `/var/lib/devbox`), численные `DEVBOX_UID`/`DEVBOX_GID`
  (по умолчанию `1000`/`1000`), минимум **два** публичных SSH-ключа для
  ротации. Приватные ключи остаются у владельцев; в `.env` попадают только
  публичные половины.
- Per-node limits (см. §9): CPU/memory/PIDs пересчитываются под узел.

## 2. `.env`

```
cp .env.example .env   # в корне репозитория продукта
$EDITOR .env
```

- `.env` gitignored; коммитить его нельзя.
- `DEVBOX_AUTHORIZED_KEYS` — **одно присваивание**: обе (или более) строки
  публичных ключей внутри **одних** одинарных кавычек, **один ключ в строке**;
  строки-комментарии (`#`) запрещены, описания живут в comment-поле ключа.
  Два одноимённых присваивания (`DEVBOX_AUTHORIZED_KEYS=…` дважды) — не
  ротация и не расширение набора: парсер возьмёт одно значение, второе молча
  потеряется. Форма значения:

  ```
  DEVBOX_AUTHORIZED_KEYS='ssh-ed25519 AAAAC3Nza…<публичный ключ laptop> operator@laptop
  ssh-ed25519 AAAAC3Nza…<публичный ключ minipc> operator@minipc'
  ```
- Каждый ключ файла обязательный: пустое/отсутствующее значение роняет
  `docker compose config/up` с именем ключа в ошибке (подстановки
  `${KEY:?…}`). Это сознательный барьер против старта «на дефолтах».

Быстрая проверка без запуска:
`docker compose --env-file .env -f deploy/compose.yml config`.

### 2.1 Безопасная загрузка значений в shell

Дальнейшие команды runbook'а ссылаются на значения из `.env`. Безопасная
загрузка **доверенного** файла в текущую сессию:

```
set -a; . ./.env; set +a      # прочитать .env и экспортировать значения
```

`set -a` даёт дочерним командам видеть переменные. Sourcing'уется только
`.env`, который ты только что создал и проверил в корне репозитория
продукта; файлы `.env` из сторонних источников не выполняются. Значения не
печатать: ни `echo "$DEVBOX_…"`, ни `env | grep DEVBOX` — состав и объём
ключей тоже операционные данные, им не место в логах и истории shell'а.
Альтернатива без загрузки — подставлять значения явно аргументами команд
ниже.

## 3. host-prep (на узле, от root, до первого `up`)

```
sudo bash scripts/host-prep.sh --path "$DEVBOX_HOST_PATH" --uid "$DEVBOX_UID" --gid "$DEVBOX_GID"
```

Скрипт создаёт/проверяет только верхние корни и не трогает ничего глубже:

| Путь | Владелец | Права |
|---|---|---|
| `$DEVBOX_HOST_PATH` | root:root | 0755 |
| `home/` | UID:GID | 0750 |
| `workspaces/` | UID:GID | 0750 |
| `system/` | root:root | 0700 |
| `services/` | root:root | 0700 |

Свойства: идемпотентен (повторный запуск безопасен); правки владельца/прав
только не-рекурсивные и логируются; **ничего не удаляет**; marker
`system/identity` не создаёт (это делает контейнер при first boot), но при
наличии читает его и сверяет schema/UID/GID с аргументами; отказывается
работать при symlink по пути, не-абсолютном пути, системном корне и при
неизвестном непустом состоянии дерева.

## 4. Build и up

```
docker compose --env-file .env -f deploy/compose.yml up -d --build
```

Наружу публикуется ровно один endpoint: `DEVBOX_SSH_BIND:DEVBOX_SSH_PORT` →
контейнерный 22. Named volumes отсутствуют; всё переживаемое состояние — один
bind на `DEVBOX_HOST_PATH`.

Первый старт (empty first boot): entrypoint сеет единственный host-key
(ed25519) и пишет root-owned marker `system/identity`
(`schema=1`, численные `uid`/`gid`), затем материализует центральный список
`/etc/ssh/devbox/authorized_keys` из env, создаёт пользователя `dev`
(HOME=`/var/lib/devbox/home`, bash, пароль `*`) и запускает `sshd -D -e`.
Последующие старты тот же код проходит как проверку (recreate), а не
пересоздание.

**Почему центральный список живёт в `/etc/ssh/devbox`, а не в `system/`.**
OpenSSH при проверке `AuthorizedKeysFile` читает файл под identity целевого
пользователя (`temporarily_use_uid(dev)`), а `system/` — root 0700: список
там недоступен `dev`, и sshd молча отклоняет каждый pubkey-login при
формально живом sshd. Запрет `system/` — контракт (host-key и marker), а не
дефект, и он не ослабляется. Поэтому центральный список — файл root:root
0644 в каталоге root:root 0755: публичные ключи — не секреты, `dev`
получает ровно read-доступ, запись — только root. Файл эфемерный (слой
контейнера): authority — env `DEVBOX_AUTHORIZED_KEYS`, каждый старт
перематериализует список атомарно; recreate восстанавливает
persistent-часть состояния (marker, host-key), но не центральный файл — он
не state, а материализация env. Ротация и recreate — прежний процесс (§6):
смена набора ключей = правка `.env` + recreate.

Логи: `docker compose --env-file .env -f deploy/compose.yml logs devbox`
(entrypoint и sshd пишут в stderr/stdout, rotation 10m × 3).

## 5. Конфигурация клиента

`~/.ssh/config` на клиентской машине:

```
Host g9s-devbox
    HostName 10.0.0.100        # DEVBOX_SSH_BIND
    Port 2222                  # DEVBOX_SSH_PORT
    User dev
    IdentityFile ~/.ssh/id_ed25519
```

Host key узла фиксируется в `known_hosts` при первом соединении
(`accept-new`) и не меняется при recreate — смена fingerprint означает
потерю/подмену `system/ssh/` и требует явного разбора (§7), а не слепого
`ssh-keygen -R`.

SFTP идёт тем же endpoint: `sftp g9s-devbox` (put/get/rename в пределах прав
`dev`). TCP-forwarding включён — он нужен будущему VS Code Remote-SSH (P2) и
не создаёт отдельного канала доверия.

## 6. Ротация и отзыв ключей (P1: `.env` + recreate)

1. Отредактируй `DEVBOX_AUTHORIZED_KEYS` в `.env` (добавление строки =
   выдача, удаление строки = отзыв).
2. Применить новый env может только recreate:

   ```
   docker compose --env-file .env -f deploy/compose.yml up -d --force-recreate
   ```

   Контейнер пересоздаётся, entrypoint атомарно перематериализует
   центральный `/etc/ssh/devbox/authorized_keys` из **текущего** `.env`.
3. Readback и пробы: положительная проба новым ключом
   (`scripts/p1-client-probe.sh …`), отрицательная проба отозванным ключом —
   `scripts/p1-client-probe.sh --expect-denied …` (ожидается явный
   `Permission denied (publickey)`). Hot-reload не обещается: открытые
   сессии живут до disconnect.

**`restart` — не ротация.** `docker compose --env-file .env -f
deploy/compose.yml restart` (и `docker restart <container>`) не перечитывает
`.env`: контейнер живёт с env, зафиксированным при его создании. Повторный
старт entrypoint'а перематериализует центральный список из
**неизменившегося старого** env — это полезно для восстановления файла
после ручной порчи, но набор ключей не меняет. Смена набора = только шаг 2.

**recreate vs restart — persistence:**

- `restart` — тот же контейнер, тот же env, state на месте; набор ключей
  не меняется;
- `recreate` (`up -d --force-recreate`, либо `up -d` после смены
  образа/`compose.yml`/env) — новый контейнер из текущих входов; bind-дерево
  (home/workspaces/system/services, marker, host-key) переживает, fingerprint
  до/после сверяется пробой §8;
- `down` + `up` — контейнер удалён и создан заново; по persistence это
  вариант recreate.

Единственный trust-channel — центральный список
`/etc/ssh/devbox/authorized_keys` (эфемерный, см. §4). Ключ, записанный в
`~dev/.ssh/authorized_keys`, входа не даёт: sshd читает только центральный
файл, `AuthorizedKeysCommand` не используется; после отзыва ключа home-bypass
проверяется той же отрицательной пробой `--expect-denied`. На деревьях,
работавших до auth-path-фикса, в `system/` может оставаться старая копия
`authorized_keys`: она инертна (`system/` закрыт 0700, sshd её не читает) и
текущим контрактом не является; её чистка — отдельное осознанное действие
оператора на узле, не операция контейнера.

## 7. Контролируемые отказы и восстановление

Все отказы ниже — штатные: entrypoint пишет причину в stderr и завершается
до запуска sshd; `restart: unless-stopped` повторяет старт, отказ виден в
`docker logs` и в состоянии контейнера.

| Ситуация | Реакция | Восстановление |
|---|---|---|
| Пустой/невалидный `DEVBOX_AUTHORIZED_KEYS` (в т.ч. `#`-строка, битый ключ) | отказ до изменений состояния | исправить `.env`, recreate |
| UID/GID ≠ marker | отказ | осознанная миграция (явная операция, не env-правка); процедуры миграции UID/GID в P1 нет — перенос на другие UID/GID фазой не покрывается |
| `system/identity` отсутствует, но дерево непустое (restore/adoption) | отказ | решение оператора: очистить/принять; автоматического adoption нет |
| Лишний top-level entry в `$DEVBOX_HOST_PATH` — имя вне home/workspaces/system/services/lost+found, в т.ч. при живом marker | отказ на любом старте: top-level scan безусловен (known и empty alike) | убрать/перенести запись вручную; adoption — явное решение оператора |
| Symlink вместо marker `system/identity` или вместо корня (system, system/ssh, services, home, workspaces) | отказ до проверок типа/owner/mode (symlink-гварды) | заменить ссылку настоящим файлом/каталогом и перезапустить |
| Потерян/бит host-key при существующем marker | отказ, seed-only — новый ключ НЕ генерируется | restore возможен только из **заранее существующей** intact-копии `system/ssh/` (приватный+публичный, тот же fingerprint), снятой оператором до потери; **P1 backup не создаёт**. Нет intact-копии — P1 recovery/adoption не предоставляет: готовой процедуры пересборки identity **нет**, «удалить marker и host-keys и пройти first boot заново» восстановлением не является (новый ключ = другая identity, смена будет видна клиентам). Backup/restore как процедура — фаза P6; до неё держать собственную копию `system/ssh/` — решение оператора |
| Потерян `.pub` при живом приватном ключе | `.pub` перезаписывается из приватного (логируется) | не требуется |
| `/etc/ssh/devbox` — symlink, не-каталог или чужие owner/mode | отказ до старта sshd (fail-closed, non-recursive check/create, symlink-гварды) | recreate (новый слой контейнера) либо ручное исправление root'ом внутри контейнера |
| Центральный список нечитаем как `dev` (mode файла/каталога) | отказ entrypoint'а до старта sshd + unhealthy в healthcheck (read-проба как `dev`) | recreate: файл перематериализуется из env (authority — env, файл не state) |
| Расхождение владельцев/прав корней | отказ | повторить host-prep (не-рекурсивно выправит верхние корни) |
| `home/`/`workspaces/` недоступны на запись `dev` | отказ | host-prep + проверка монтирования |
| Unknown schema marker | отказ | миграция state-schema — отдельное release-событие |
| Отсутствует `DEVBOX_HOST_PATH` на хосте | compose откажет (bind `create_host_path:false`) — молчаливого создания пустого дерева нет | выполнить host-prep |

## 8. Пробы (ownership / mount / scan)

- Клиентская батарея (с машины с доступом): `scripts/p1-client-probe.sh
  --target <DEVBOX_SSH_BIND> --port <DEVBOX_SSH_PORT> --identity <приватный
  ключ>` — target это адрес публикации (`DEVBOX_SSH_BIND`, для этого узла
  `10.0.0.100`), port — опубликованный порт (`DEVBOX_SSH_PORT`, `2222`), а не
  контейнерный 22; коды: 0 — все
  пробы прошли, 1 — есть FAIL (вкл. неожиданный успех отрицательной пробы),
  2 — NOT PROVEN (недостижимость/окружение). Для отозванного ключа (и
  home-bypass после отзыва) — тот же скрипт в режиме `--expect-denied`
  (см. §6).
- Ownership/modes на узле: `stat -c '%u %g %a'` по пяти корням — значения из
  таблицы §3; повторный запуск host-prep должен быть no-op после `ok …` по
  всем корням.
- **Linux nested sentinel probe** (доказательство не-рекурсивности
  host-prep): на **известном** дереве (marker существует; на пустом дереве
  до first boot sentinel не класть — entrypoint откажет от nonempty) положи
  в каждый из `home/`/`workspaces/`/`system/`/`services/` вложенный
  sentinel-файл с заведомо «неправильными» owner/mode и уникальным
  содержимым (например `home/.sentinel-probe` с owner `0:0`, mode `0600`,
  случайной строкой внутри); запиши `stat` и checksum; выполни host-prep;
  убедись, что owner/mode/content каждого sentinel **не изменились** —
  скрипт правит только верхние корни, рекурсии нет.
- Marker: `sudo cat "$DEVBOX_HOST_PATH/system/identity"` — schema/uid/gid;
  fingerprint host-key: `sudo ssh-keygen -lf …/system/ssh/ssh_host_ed25519_key`
  (сверяется до/после recreate).
- **find fail-injection (Linux; локально NOT PROVEN)**: проверка fail-closed
  поведения inspection-веток. В отдельном каталоге положи stub-скрипт `find`,
  завершающийся ненулевым кодом, и обязательно сделай его executable — без
  `chmod +x` `command -v find` его не найдёт, подставится настоящий find, и
  injection молча ничего не докажет:

  ```
  mkdir -p /tmp/failstub
  printf '#!/bin/sh\nexit 9\n' > /tmp/failstub/find
  chmod +x /tmp/failstub/find
  ```

  - **host-prep** — только на **существующем подготовленном** ROOT
    (`sudo env PATH=/tmp/failstub:$PATH bash scripts/host-prep.sh …`): если
    ROOT ещё не создан, find вообще не вызывается и stub ничего не доказывает.
  - **entrypoint** — top-level scan безусловен: FATAL ловится на любом старте
    (no-marker/first-boot и known), по фактическому порядку — после проверки
    owner/mode корня (`root:root 0755`) и до ветвления known/empty; вложенные
    nested-сканы остаются только в no-marker ветке.

  Ожидаемый результат обоих — немедленный FATAL «find failed … refusing» ДО
  любых create/chown/chmod/seed/marker/sshd (нулевые мутации при отказе).
  Локальный macOS-suite этот сценарий не исполняет: до Linux-прогона он
  числится NOT PROVEN.
- Mount-аудит: в контейнере смонтирован ровно один bind на
  `/var/lib/devbox`; `docker.sock` и домашние каталоги хоста отсутствуют
  (проверяется и клиентской пробой).
- **Client-side scan опубликованных поверхностей** (операторская инструкция):
  с **независимой LAN client-позиции** — не с самого узла — выполни full TCP
  scan всех 65 535 портов опубликованного адреса (например `nmap -p- -T4
  <DEVBOX_SSH_BIND>`). На выделенном P1-узле ожидание — ровно два открытых
  порта: host SSH `22` и настроенный devbox SSH (`DEVBOX_SSH_PORT`; для этого
  узла `2222`). Результат «все порты open» (fake-IP/proxy-контур клиента) —
  не список поверхностей узла, а признак **невалидной client-позиции**:
  итог NOT_PROVEN, смени позицию и повтори скан. Compose inspect без
  client-side скана не засчитывается (D-002).

## 9. Переносимость: per-node параметры

Значения из `.env.example` измерены для первого узла P1 (6 CPU, RAM ~8 ГБ,
публикация `10.0.0.100:2222`). Для нового узла пересчитать:

- `DEVBOX_CPU_LIMIT`, `DEVBOX_MEMORY_LIMIT`, `DEVBOX_PIDS_LIMIT` — верхние
  границы (не резервирование; swap рабочей памятью не считается);
- `DEVBOX_SSH_BIND`/`DEVBOX_SSH_PORT` — адрес/порт, доступные клиенту по
  LAN/VPN и свободные на узле;
- при смене узла — заново host-prep на новом `DEVBOX_HOST_PATH`; перенос
  дерева на другой host-path = копирование + явная проверка marker/ownership
  (adoption-ветка §7).

## 10. Остановка

```
docker compose --env-file .env -f deploy/compose.yml down   # без -v: named volumes отсутствуют, состояние в bind
```

`down` не трогает `DEVBOX_HOST_PATH`; повторный `up` с тем же путём проходит
как recreate (host-key fingerprint и marker сохраняются — проверить пробой
§8). Полное снятие с узла (removal/redeploy) — санкционированная фаза P6.
