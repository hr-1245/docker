# Bug 3980 authenticated API smoke (no secrets printed)
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:8080'
$tenant = 'hms'
$user = 'hms-admin'
$pass = $env:HMS_LOCAL_ADMIN_PASSWORD
if (-not $pass) {
  Write-Output 'BLOCKER: Set HMS_LOCAL_ADMIN_PASSWORD to the local hms-admin password (see hms-web README).'
  exit 2
}

$login = Invoke-RestMethod -Method Post -Uri "$base/hms/control/login" -ContentType 'application/json' -Body (@{
  USERNAME = $user
  PASSWORD = $pass
  userTenantId = $tenant
} | ConvertTo-Json)
if (-not $login.accessToken) {
  Write-Output "LOGIN_FAILED: $($login.errorCode) $($login.message)"
  exit 1
}
$headers = @{
  Authorization = "Bearer $($login.accessToken)"
  Accept        = 'application/json'
}

$parties = Invoke-RestMethod -Method Get -Uri "$base/hms/control/listParties?userTenantId=$tenant&roleTypeId=PATIENT&pageSize=100" -Headers $headers
$rows = @($parties.parties | Where-Object { $_.partyId -and $_.partyId -notmatch '^(admin|accounting|_NA_)' })
if ($rows.Count -lt 2) {
  Write-Output "INSUFFICIENT_PATIENTS: found $($rows.Count)"
  exit 3
}

$partyA = $rows[0].partyId
$partyB = $rows[1].partyId
$mrnA = $rows[0].externalId
$mrnB = $rows[1].externalId
$globalOpd = @(Invoke-RestMethod -Method Get -Uri "$base/hms/control/opdQueue?userTenantId=$tenant" -Headers $headers)

function Get-OpdVisits($partyId) {
  Invoke-RestMethod -Method Get -Uri "$base/hms/control/opdQueue?userTenantId=$tenant&partyId=$partyId" -Headers $headers
}

$opdA = @(Get-OpdVisits $partyA)
$opdB = @(Get-OpdVisits $partyB)
$badA = @($opdA | Where-Object { $_.partyId -and $_.partyId -ne $partyA })
$badB = @($opdB | Where-Object { $_.partyId -and $_.partyId -ne $partyB })

$admA = Invoke-RestMethod -Method Get -Uri "$base/hms/control/listAdmissions?userTenantId=$tenant&partyId=$partyA" -Headers $headers
$admB = Invoke-RestMethod -Method Get -Uri "$base/hms/control/listAdmissions?userTenantId=$tenant&partyId=$partyB" -Headers $headers
$admRowsA = @($admA.admissions)
$admRowsB = @($admB.admissions)
$badAdmA = @($admRowsA | Where-Object { $_.partyId -and $_.partyId -ne $partyA })
$badAdmB = @($admRowsB | Where-Object { $_.partyId -and $_.partyId -ne $partyB })

Write-Output "LOGIN_OK tenant=$tenant user=$user"
Write-Output "GLOBAL_OPD_COUNT=$($globalOpd.Count)"
Write-Output "PATIENT_A partyId=$partyA mrn=$mrnA opdCount=$($opdA.Count) ipdCount=$($admRowsA.Count) opdLeaks=$($badA.Count) ipdLeaks=$($badAdmA.Count)"
Write-Output "PATIENT_B partyId=$partyB mrn=$mrnB opdCount=$($opdB.Count) ipdCount=$($admRowsB.Count) opdLeaks=$($badB.Count) ipdLeaks=$($badAdmB.Count)"
if ($globalOpd.Count -gt 0 -and ($opdA.Count + $opdB.Count) -lt $globalOpd.Count) {
  Write-Output 'PARTY_FILTER_ACTIVE'
}

if ($badA.Count -gt 0 -or $badB.Count -gt 0 -or $badAdmA.Count -gt 0 -or $badAdmB.Count -gt 0) {
  Write-Output 'ISOLATION_FAIL'
  exit 4
}
Write-Output 'ISOLATION_OK'
