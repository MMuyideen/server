#Requires -Version 5.1
<#
.SYNOPSIS
    Starts (or recreates) the Clonarr container, optionally restoring its
    /config tree from a backup first.

.PARAMETER ConfigPath
    Host folder bind-mounted at /config. Created if missing.

.PARAMETER TimeZone
    IANA timezone for the container (e.g. Africa/Lagos for WAT).

.PARAMETER Port
    Host port to bind. Default 6060.

.PARAMETER BackupRoot
    Optional. If <BackupRoot>\clonarr exists, its contents are mirrored into
    -ConfigPath before the container starts.

.EXAMPLE
    .\Start-Clonarr.ps1 -ConfigPath D:\media\config\clonarr -TimeZone Africa/Lagos
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$TimeZone   = 'Africa/Lagos',
    [int]$Port          = 6060,
    [string]$BackupRoot
)

. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

if (-not (Wait-ForDocker)) { exit 1 }

New-Item -ItemType Directory -Path $ConfigPath -Force | Out-Null

if ($BackupRoot) {
    Restore-FolderBackup -AppName 'clonarr' `
        -DestDir $ConfigPath `
        -BackupDir (Join-Path $BackupRoot 'clonarr')
}

Start-Container -Name 'clonarr' -Image 'ghcr.io/prophetse7en/clonarr:latest' -RunArgs @(
    '-p', "${Port}:6060"
    '-v', "${ConfigPath}:/config"
    '-e', "TZ=$TimeZone"
)
