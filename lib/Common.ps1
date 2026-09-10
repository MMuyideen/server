#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for the media-server scripts. Dot-source it:
        . (Join-Path $PSScriptRoot '..\lib\Common.ps1')
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $color = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host ('[{0}] {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Wait-ForDocker {
    param([int]$TimeoutSeconds = 180)

    if (-not (Test-CommandExists docker)) {
        Write-Log 'Docker CLI not on PATH. Reboot to finish WSL/Docker Desktop setup, then retry.' 'WARN'
        return $false
    }

    Write-Log 'Waiting for the Docker engine to become available...'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        docker info 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'Docker engine is ready.' 'OK'
            return $true
        }
        Start-Sleep -Seconds 5
    }
    Write-Log "Docker engine not ready after ${TimeoutSeconds}s. Start Docker Desktop and retry." 'WARN'
    return $false
}

function Start-Container {
    <#
        Recreates a container from scratch so callers stay idempotent.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Image,
        [string[]]$RunArgs = @()
    )

    if (docker ps -aq --filter "name=^/$Name$") {
        Write-Log "Removing existing container '$Name'..."
        docker rm -f $Name | Out-Null
    }

    Write-Log "Starting container '$Name' ($Image)..."
    docker run -d --name $Name --restart unless-stopped --pull always @RunArgs $Image | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Container '$Name' started." 'OK'
    }
    else {
        Write-Log "Failed to start container '$Name' (exit $LASTEXITCODE)." 'ERROR'
    }
}

function Stop-App {
    <#
        Stops an app whether it runs as a Windows service or a bare process
        (the *arr apps and qBittorrent commonly run from a tray/startup entry).
        Returns the names of services that were actually running so the caller
        can bring them back up afterwards.
    #>
    param([Parameter(Mandatory)][string[]]$Name)

    $restart = @()
    foreach ($n in $Name) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') {
            Write-Log "  stopping service '$n'..."
            Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
            $restart += $n
        }
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "  stopping process '$($_.ProcessName)' (pid $($_.Id))..."
            $_ | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    return , $restart
}

function Start-App {
    param([string[]]$ServiceName = @())
    foreach ($n in $ServiceName) {
        Write-Log "  starting service '$n'..."
        Start-Service -Name $n -ErrorAction SilentlyContinue
    }
}

function Restore-ZipBackup {
    <#
        Expands the newest matching *.zip over an app's data directory. Works for
        any Servarr-style backup (Radarr/Sonarr/Prowlarr/Lidarr/Whisparr) and
        Bazarr, which all archive config + database at the zip root.

        <BackupRoot> may be laid out either way - both are searched:
          <BackupRoot>\<AppName>\*.zip           per-app subfolder
          <BackupRoot>\<appname>_backup_*.zip    flat, native Servarr filename
    #>
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        Write-Log "${AppName}: backup root '$BackupRoot' not found - skipping restore." 'WARN'
        return
    }

    $lc = $AppName.ToLowerInvariant()
    $candidates = @(
        Join-Path $BackupRoot $AppName          # subfolder form
        $BackupRoot                             # flat form
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $zip = $candidates | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Filter '*.zip' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -ne $BackupRoot -or $_.Name -like "$lc*" }
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $zip) {
        Write-Log "${AppName}: no matching .zip backup under '$BackupRoot' - skipping restore." 'WARN'
        return
    }

    Write-Log "${AppName}: restoring from '$($zip.Name)' into '$DataDir'..."
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    $svc = Stop-App -Name $AppName
    try {
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $DataDir -Force
        Write-Log "${AppName}: restore complete." 'OK'
    }
    finally {
        Start-App -ServiceName $svc
    }
}

function Restore-FolderBackup {
    <#
        Mirrors a backup tree into an app's config directory (files are added or
        overwritten; existing extras are left in place).
    #>
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$DestDir,
        [Parameter(Mandatory)][string]$BackupDir,
        [string[]]$StopName = @()
    )

    if (-not (Test-Path -LiteralPath $BackupDir) -or
        -not (Get-ChildItem -LiteralPath $BackupDir -Force -ErrorAction SilentlyContinue)) {
        Write-Log "${AppName}: no backup content at '$BackupDir' - skipping restore." 'WARN'
        return
    }

    Write-Log "${AppName}: restoring files from '$BackupDir' into '$DestDir'..."
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    $svc = if ($StopName) { Stop-App -Name $StopName } else { @() }
    try {
        robocopy $BackupDir $DestDir /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Log "${AppName}: robocopy reported errors (code $LASTEXITCODE)." 'WARN'
        }
        else {
            Write-Log "${AppName}: restore complete." 'OK'
        }
    }
    finally {
        Start-App -ServiceName $svc
    }
}
