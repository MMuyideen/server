#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Provisions a Windows media server: *arr stack, Jellyfin, qBittorrent, Docker,
    and supporting containers (FlareSolverr, Clonarr).

.DESCRIPTION
    Idempotent bootstrap script. Safe to re-run: packages already present are
    skipped, directories are only created when missing, and containers are
    recreated cleanly.

    Layout:
      lib\Common.ps1                    shared helpers (dot-sourced)
      containers\Start-FlareSolverr.ps1 stand-alone container script
      containers\Start-Clonarr.ps1      stand-alone container script

.PARAMETER MediaRoot
    Root folder for the media library and app config. Defaults to
    %USERPROFILE%\Downloads\data.

.PARAMETER TimeZone
    IANA timezone passed to containers (e.g. Africa/Lagos for WAT,
    America/New_York).

.PARAMETER ClonarrConfigPath
    Host folder bind-mounted into the Clonarr container at /config.

.PARAMETER BackupRoot
    Optional folder holding backups. The matching app is stopped, its
    config/database restored, then restarted. Zip backups are matched either as
    a per-app subfolder or as flat native Servarr filenames:

      <BackupRoot>\Radarr\*.zip   OR  <BackupRoot>\radarr_backup_*.zip
      ...same for Sonarr / Prowlarr / Lidarr / Whisparr / Bazarr
      <BackupRoot>\qBittorrent\       config tree (qBittorrent.ini, ...)
      <BackupRoot>\Jellyfin\          data tree
      <BackupRoot>\clonarr\           /config tree

    No restore happens unless this is supplied.

.PARAMETER SkipDocker
    Skip WSL, Docker Desktop, and all container steps.

.PARAMETER SkipRestore
    Skip the restore step even when -BackupRoot is given.

.EXAMPLE
    .\Setup-MediaServer.ps1 -MediaRoot D:\media -TimeZone Africa/Lagos

.EXAMPLE
    .\Setup-MediaServer.ps1 -BackupRoot E:\ServerBackups

.NOTES
    WSL and Docker Desktop installs usually require a reboot before the Docker
    engine is usable. Re-run this script after rebooting to finish the container
    steps (or run containers\Start-*.ps1 directly).
#>
[CmdletBinding()]
param(
    [string]$MediaRoot          = (Join-Path $env:USERPROFILE 'Downloads\data'),
    [string]$TimeZone           = 'Africa/Lagos',
    [string]$ClonarrConfigPath,
    [string]$BackupRoot,
    [switch]$SkipDocker,
    [switch]$SkipRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not $ClonarrConfigPath) {
    $ClonarrConfigPath = Join-Path $MediaRoot 'config\clonarr'
}

#region 1. Directory layout --------------------------------------------------

Write-Log "Creating media directory layout under '$MediaRoot'..."
$mediaDirs = 'books', 'movies', 'music', 'tv' | ForEach-Object { Join-Path $MediaRoot "media\$_" }
foreach ($dir in @($mediaDirs) + $ClonarrConfigPath) {
    if (Test-Path $dir) {
        Write-Log "  exists  $dir"
    }
    else {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "  created $dir" 'OK'
    }
}

#endregion

#region 2. winget packages -------------------------------------------------------

if (-not (Test-CommandExists winget)) {
    throw 'winget (App Installer) is not available. Install it from the Microsoft Store, then re-run.'
}

function Install-WingetPackage {
    <#
        Installs a winget package unless it is already present. Treats winget's
        "no applicable upgrade / already installed" exit codes as success.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name = $Id
    )

    winget list --id $Id --exact --accept-source-agreements 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "$Name already installed - skipping." 'OK'
        return
    }

    Write-Log "Installing $Name ($Id)..."
    winget install --id $Id --exact --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity

    # 0 = ok | -1978335189 = no applicable upgrade | -1978335135 = already installed
    if (@(0, -1978335189, -1978335135) -notcontains $LASTEXITCODE) {
        Write-Log "$Name install returned exit code $LASTEXITCODE." 'WARN'
    }
    else {
        Write-Log "$Name installed." 'OK'
    }
}

$packages = [ordered]@{
    'Git.Git'                 = 'Git'
    'Python.Python.3.11'      = 'Python 3.11'
    'qBittorrent.qBittorrent' = 'qBittorrent'
    'TeamRadarr.Radarr'       = 'Radarr'
    'TeamSonarr.Sonarr'       = 'Sonarr'
    'TeamProwlarr.Prowlarr'   = 'Prowlarr'
    'TeamLidarr.Lidarr'       = 'Lidarr'
    'Morpheus.Bazarr'         = 'Bazarr'
    'Jellyfin.Server'         = 'Jellyfin Server'
}

foreach ($id in $packages.Keys) {
    Install-WingetPackage -Id $id -Name $packages[$id]
}

#endregion

#region 3. Restore backups -----------------------------------------------------

if (-not $BackupRoot) {
    Write-Log 'No -BackupRoot given - skipping restore.'
}
elseif ($SkipRestore) {
    Write-Log 'SkipRestore set - skipping restore.' 'WARN'
}
elseif (-not (Test-Path -LiteralPath $BackupRoot)) {
    Write-Log "BackupRoot '$BackupRoot' not found - skipping restore." 'WARN'
}
else {
    Write-Log "Restoring application backups from '$BackupRoot'..."

    # Servarr / Bazarr: newest matching *.zip expanded over the data dir. Accepts
    # both <BackupRoot>\<App>\*.zip and flat <appname>_backup_*.zip filenames.
    $zipApps = [ordered]@{
        Radarr   = Join-Path $env:ProgramData 'Radarr'
        Sonarr   = Join-Path $env:ProgramData 'Sonarr'
        Prowlarr = Join-Path $env:ProgramData 'Prowlarr'
        Lidarr   = Join-Path $env:ProgramData 'Lidarr'
        Whisparr = Join-Path $env:ProgramData 'Whisparr'
        Bazarr   = Join-Path $env:ProgramData 'Bazarr'
    }
    foreach ($app in $zipApps.Keys) {
        Restore-ZipBackup -AppName $app -DataDir $zipApps[$app] -BackupRoot $BackupRoot
    }

    # Folder-tree restores.
    Restore-FolderBackup -AppName 'qBittorrent' -StopName 'qbittorrent' `
        -DestDir (Join-Path $env:APPDATA 'qBittorrent') `
        -BackupDir (Join-Path $BackupRoot 'qBittorrent')

    Restore-FolderBackup -AppName 'Jellyfin' -StopName 'JellyfinServer', 'jellyfin' `
        -DestDir (Join-Path $env:ProgramData 'Jellyfin\Server') `
        -BackupDir (Join-Path $BackupRoot 'Jellyfin')
}

#endregion

#region 4. Docker + containers -----------------------------------------------

if ($SkipDocker) {
    Write-Log 'SkipDocker set - skipping WSL, Docker Desktop, and containers.' 'WARN'
    return
}

if (-not (Test-CommandExists wsl)) {
    Write-Log 'Installing WSL (a reboot may be required afterwards)...'
    wsl --install --no-launch
}
else {
    Write-Log 'WSL already present.' 'OK'
}

Install-WingetPackage -Id 'Docker.DockerDesktop' -Name 'Docker Desktop'

if (-not (Wait-ForDocker)) {
    Write-Log 'Reboot / start Docker Desktop, then re-run this script or containers\Start-*.ps1.' 'WARN'
    return
}

$clonarrArgs = @{ ConfigPath = $ClonarrConfigPath; TimeZone = $TimeZone }
if ($BackupRoot -and -not $SkipRestore) { $clonarrArgs.BackupRoot = $BackupRoot }

& (Join-Path $PSScriptRoot 'containers\Start-FlareSolverr.ps1')
& (Join-Path $PSScriptRoot 'containers\Start-Clonarr.ps1') @clonarrArgs

Write-Log 'Done.' 'OK'

#endregion
