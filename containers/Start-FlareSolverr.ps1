#Requires -Version 5.1
<#
.SYNOPSIS
    Starts (or recreates) the FlareSolverr container.

.PARAMETER Port
    Host port to bind, loopback only. Default 8191.

.PARAMETER LogLevel
    FlareSolverr LOG_LEVEL. Default info.

.EXAMPLE
    .\Start-FlareSolverr.ps1
#>
[CmdletBinding()]
param(
    [int]$Port       = 8191,
    [string]$LogLevel = 'info'
)

. (Join-Path $PSScriptRoot '..\lib\Common.ps1')

if (-not (Wait-ForDocker)) { exit 1 }

Start-Container -Name 'flaresolverr' -Image 'ghcr.io/flaresolverr/flaresolverr:latest' -RunArgs @(
    '-p', "127.0.0.1:${Port}:8191"
    '-e', "LOG_LEVEL=$LogLevel"
)
