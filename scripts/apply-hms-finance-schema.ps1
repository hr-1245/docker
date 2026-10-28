# Creates HMS finance ledger tables and grants OFBiz app user access.
# Requires native PostgreSQL admin credentials in docker/.env (POSTGRES_ADMIN_* or NATIVE_POSTGRES_*).
param(
    [string]$EnvFile = (Join-Path (Split-Path $PSScriptRoot -Parent) ".env")
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $EnvFile)) {
    Write-Error "Missing env file: $EnvFile"
}

Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([^#=]+)=(.*)$') {
        Set-Item -Path "env:$($matches[1].Trim())" -Value $matches[2].Trim()
    }
}

$hostName = if ($env:NATIVE_POSTGRES_HOST) { $env:NATIVE_POSTGRES_HOST } elseif ($env:DB_HOST) { $env:DB_HOST } else { "localhost" }
$port = if ($env:NATIVE_POSTGRES_PORT) { $env:NATIVE_POSTGRES_PORT } elseif ($env:DB_PORT) { $env:DB_PORT } else { "5432" }
$db = if ($env:OFBIZ_POSTGRES_OFBIZ_DB) { $env:OFBIZ_POSTGRES_OFBIZ_DB } elseif ($env:DB_NAME) { $env:DB_NAME } else { "ofbiz_hms" }
$appUser = if ($env:OFBIZ_POSTGRES_OFBIZ_USER) { $env:OFBIZ_POSTGRES_OFBIZ_USER } elseif ($env:DB_USER) { $env:DB_USER } else { "hms_app" }
$adminUser = if ($env:NATIVE_POSTGRES_ADMIN_USER) { $env:NATIVE_POSTGRES_ADMIN_USER } elseif ($env:POSTGRES_ADMIN_USER) { $env:POSTGRES_ADMIN_USER } else { "postgres" }
$adminPass = if ($env:NATIVE_POSTGRES_ADMIN_PASSWORD) { $env:NATIVE_POSTGRES_ADMIN_PASSWORD } else { $env:POSTGRES_ADMIN_PASSWORD }

if (-not $adminPass) {
    Write-Error "Set POSTGRES_ADMIN_PASSWORD or NATIVE_POSTGRES_ADMIN_PASSWORD in $EnvFile"
}

$ddlPath = Join-Path (Split-Path $PSScriptRoot -Parent) "postgres\external\hms-finance-ledger-ddl.sql"
$grantSql = @"
GRANT CREATE ON SCHEMA public TO "$appUser";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$appUser";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$appUser";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$appUser";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "$appUser";
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.hms_finance_entry TO "$appUser";
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.hms_finance_audit TO "$appUser";
"@

$pgHost = if ($hostName -eq "localhost" -or $hostName -eq "127.0.0.1") { "host.docker.internal" } else { $hostName }
$grantPath = Join-Path $env:TEMP "hms-finance-grants.sql"
Set-Content -Path $grantPath -Value $grantSql -Encoding UTF8

Write-Host "Applying finance DDL to ${db}@${pgHost}:${port} as ${adminUser} (app user: ${appUser})"

docker run --rm `
    -e PGPASSWORD=$adminPass `
    -v "${ddlPath}:/ddl.sql:ro" `
    -v "${grantPath}:/grants.sql:ro" `
    --add-host=host.docker.internal:host-gateway `
    postgres:16-alpine `
    psql -h $pgHost -p $port -U $adminUser -d $db -v ON_ERROR_STOP=1 -f /ddl.sql -f /grants.sql

if ($LASTEXITCODE -ne 0) {
    Write-Error "psql failed with exit code $LASTEXITCODE"
}

Write-Host "Finance schema applied. Restart hms-api: docker compose restart hms-api"
