# Register the native PostgreSQL 17 standby as a Windows service (requires Administrator).
# Primary service postgresql-x64-17 is unchanged.
# Usage (elevated PowerShell):
#   cd docker
#   .\scripts\register-postgres-replica-service.ps1

$ErrorActionPreference = 'Stop'
$PgCtl = 'C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe'
$DataDir = 'C:\PostgreSQL\17\data_replica'
$ServiceName = 'postgresql-x64-17-replica'

if (-not (Test-Path $PgCtl)) { throw "PostgreSQL 17 pg_ctl not found at $PgCtl" }
if (-not (Test-Path $DataDir)) { throw "Standby data directory missing: $DataDir" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Error "Run this script in an elevated (Administrator) PowerShell session."
  exit 1
}

& $PgCtl register -N $ServiceName -D $DataDir -S auto
Write-Host "Registered service: $ServiceName"
Start-Service -Name $ServiceName
Get-Service -Name $ServiceName
