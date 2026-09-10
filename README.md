# server

Windows media-server provisioning scripts. One idempotent PowerShell run installs
the *arr stack, Jellyfin, qBittorrent and Docker, optionally restores each app
from a backup, and starts the supporting containers.

## Layout

| Path | Purpose |
|------|---------|
| `Setup-MediaServer.ps1` | Orchestrator: directories → winget installs → backup restore → WSL/Docker → containers |
| `lib/Common.ps1` | Shared helpers (logging, Docker wait, container recreate, service/process stop-start, zip + folder restore). Dot-sourced, does nothing on its own. |
| `containers/Start-FlareSolverr.ps1` | Stand-alone FlareSolverr container script |
| `containers/Start-Clonarr.ps1` | Stand-alone Clonarr container script (restores `/config` first if given a backup) |

## Requirements

- Windows 10 / 11 (or Windows Server) with **winget** (App Installer)
- PowerShell 5.1+
- Run **as Administrator** (winget, `wsl --install`, service control)

## What gets installed

Git, Python (latest 3.x — resolved from winget at run time, no pinned version),
qBittorrent, Radarr, Sonarr, Prowlarr, Lidarr, Bazarr, Jellyfin Server, WSL,
Docker Desktop, plus the `flaresolverr` and `clonarr` containers.

> Bazarr's winget package requires an install location; the script installs it
> to `%ProgramData%\Bazarr` and restores its backup into `%ProgramData%\Bazarr\data`.

> Whisparr is **not** installed (no reliable winget package) but *is* restored
> if a backup is present — install it manually.

## Usage

```powershell
cd path\to\server
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# defaults: MediaRoot = %USERPROFILE%\Downloads\data, TimeZone = Africa/Lagos,
# BackupRoot = current directory (so backups next to the script are restored)
.\Setup-MediaServer.ps1

# restore from somewhere else, skip restore entirely
.\Setup-MediaServer.ps1 -BackupRoot E:\ServerBackups
.\Setup-MediaServer.ps1 -SkipRestore
```

Can't change execution policy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-MediaServer.ps1
```

### Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-MediaRoot` | `%USERPROFILE%\Downloads\data` | `media\{books,movies,music,tv}` created underneath |
| `-TimeZone` | `Africa/Lagos` | IANA name passed to containers (`Africa/Lagos` = WAT) |
| `-ClonarrConfigPath` | `<MediaRoot>\config\clonarr` | Bind-mounted at `/config` |
| `-BackupRoot` | current directory | Folder searched for backups; see layout below |
| `-SkipDocker` | off | Skip WSL, Docker Desktop and all containers |
| `-SkipRestore` | off | Skip the restore step |

The script is safe to re-run: installed packages are skipped, existing
directories are left alone, containers are recreated cleanly.

## Reboot

The script enables the `Microsoft-Windows-Subsystem-Linux` and
`VirtualMachinePlatform` Windows features and runs `wsl --install` when WSL
isn't fully set up (checking `wsl --status`, not just whether `wsl.exe` exists —
it always does). Any of these means a **reboot is required**; the script stops
and tells you. Re-run `Setup-MediaServer.ps1` after rebooting to finish the
container steps, or run the container scripts directly:

```powershell
.\containers\Start-FlareSolverr.ps1
.\containers\Start-Clonarr.ps1 -ConfigPath D:\media\config\clonarr -TimeZone Africa/Lagos
```

## Backup restore

`-BackupRoot` defaults to the current directory, so the simplest workflow is to
drop the backup archives next to `Setup-MediaServer.ps1` and run it. Point it
elsewhere with `-BackupRoot`, or pass `-SkipRestore` to skip. The matching app
is stopped, restored, then restarted.

| App(s) | Source | Restored to |
|--------|--------|-------------|
| Radarr, Sonarr, Prowlarr, Lidarr, Whisparr, Bazarr | `<BackupRoot>\<App>\*.zip` **or** flat `<app>_backup_*.zip` (newest wins) | `%ProgramData%\<App>` |
| qBittorrent | `<BackupRoot>\qBittorrent.zip` (contains a `qBittorrent` folder) | `%LOCALAPPDATA%` |
| Jellyfin | `<BackupRoot>\Jellyfin\` tree | `%ProgramData%\Jellyfin\Server` |
| clonarr | `<BackupRoot>\clonarr\` tree | `-ClonarrConfigPath` |

> **Warning** — Servarr / qBittorrent backups contain API keys, indexer
> credentials and download-client / WebUI passwords. Because `-BackupRoot`
> defaults to the working directory, be careful not to commit archives left
> beside the script.

## Container ports

| Container | Port |
|-----------|------|
| FlareSolverr | `127.0.0.1:8191` |
| Clonarr | `6060` |
