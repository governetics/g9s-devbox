# CHANGELOG — семантический лог архитектуры g9s-devbox

Записи — сверху, новые первыми. Одно изменение — одна запись; фазовые статусы живут в [implementation-plan](../project/implementation-plan.md).

## 2026-11-17 — архитектура MVP g9s-devbox

### Added

- [D-001](decisions/D-001-runtime-devbox.md): Debian 13 slim, `tini + sshd`, client-owned VS Code Server, pinned extensions/CLI и native on-demand Claude Code/OpenCode.
- [D-002](decisions/D-002-sostoyanie-i-postavka.md): единый persistent host-root, UID/GID/state-schema identity, central-only authorized_keys, один local/Path A compose и public GitHub/GHCR delivery.
- [D-003](decisions/D-003-failovyi-obmen.md): sibling SFTPGo/Samba, OpenSSH SFTP fallback, постоянный WebDAV через HTTPS g9s-edge, Samba 445 и selective home/workspaces export.
- Целевая [vision](vision.md) и честный [as-is](architecture.md): реализация ещё отсутствует.
- Вертикальный [implementation-plan](../project/implementation-plan.md) с владельцами real-env действий, operator inputs и матрицей M1–M13.
- Защитные контракты: edge-only SFTPGo allowlist, Samba `wide links=no` при сохранении внутренних symlinks, host-side Samba UID/GID preflight, export negative probes и tree+history secret scan перед public release.

### Changed

- Исходный SFTP-only контур расширен решением оператора до первоклассного файлового обмена через OpenSSH SFTP, WebDAV и SMB.
- Сетевой export включает secrets-bearing home по явному решению оператора, но исключает `system/` и `services/`.

### Removed

- Named volumes как допустимый носитель состояния, которое обязано переживать Path A removal.
- Preinstalled VS Code Server, недокументированный pre-connect extension preload и второй независимый SSH authorized_keys trust-channel как варианты реализации.
