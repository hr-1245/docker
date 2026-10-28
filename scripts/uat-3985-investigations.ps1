# Bug 3985 UAT — My Queue Investigations vs lab history API (no secrets printed)
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:8080'
$tenant = 'hms'
$user = 'hms-admin'
$pass = $env:HMS_LOCAL_ADMIN_PASSWORD
if (-not $pass) { $pass = 'ofbiz' }

$login = Invoke-RestMethod -Method Post -Uri "$base/hms/control/login" -ContentType 'application/json' -Body (@{
  USERNAME = $user
  PASSWORD = $pass
  userTenantId = $tenant
} | ConvertTo-Json)
if (-not $login.accessToken) {
  Write-Output "LOGIN_FAIL code=$($login.errorCode)"
  exit 1
}
$headers = @{
  Authorization = "Bearer $($login.accessToken)"
  Accept        = 'application/json'
}

Write-Output 'LOGIN_OK'
Write-Output "DEPLOY_PROBE parameterNameField=checking"

$parties = Invoke-RestMethod -Method Get -Uri "$base/hms/control/listParties?userTenantId=$tenant&roleTypeId=PATIENT&pageSize=200" -Headers $headers
$patients = @($parties.parties | Where-Object { $_.partyId -and $_.externalId })
Write-Output "PATIENT_POOL=$($patients.Count)"

$best = $null
$bestCount = 0
$legacyRows = @()
$allSamples = @()

foreach ($p in $patients) {
  $partyId = [string]$p.partyId
  $mrn = [string]$p.externalId
  try {
    $hist = Invoke-RestMethod -Method Get -Uri "$base/hms/control/labPatientHistory?userTenantId=$tenant&partyId=$partyId" -Headers $headers
  } catch {
    continue
  }
  $rows = @($hist.history)
  if ($rows.Count -eq 0) { continue }
  if ($rows.Count -gt $bestCount) {
    $bestCount = $rows.Count
    $best = @{ partyId = $partyId; mrn = $mrn; rows = $rows }
  }
  foreach ($r in $rows) {
    $hasParamField = $null -ne ($r.PSObject.Properties['parameterName'])
    $parent = [string]$r.parentTestName
    $param = [string]$r.parameterName
    if (-not $param) { $param = [string]$r.testName }
    if ($hasParamField -and $parent -and $param -and ($parent -ne $param)) {
      $allSamples += [PSCustomObject]@{ mrn = $mrn; partyId = $partyId; parent = $parent; param = $param; val = $r.resultSummary; unit = $r.unit; ref = $r.referenceRange; reportId = $r.reportId }
    }
    if ($hasParamField -and $parent -and -not [string]$r.paramName -and -not $r.parameterName -and $parent -eq $param) {
      $legacyRows += [PSCustomObject]@{ mrn = $mrn; partyId = $partyId; test = $parent; val = $r.resultSummary }
    }
  }
}

if ($best -and $best.rows.Count -gt 0) {
  $probe = $best.rows[0]
  $hasApiField = $null -ne ($probe.PSObject.Properties['parameterName'])
  Write-Output "DEPLOY_PROBE parameterNameField=$hasApiField parentTestNameField=$($null -ne ($probe.PSObject.Properties['parentTestName']))"
  Write-Output "BEST_PATIENT partyId=$($best.partyId) mrn=$($best.mrn) historyRows=$($best.rows.Count)"
  $best.rows | Select-Object -First 8 | ForEach-Object {
    $pname = if ($_.parameterName) { $_.parameterName } else { $_.testName }
    Write-Output ("  ROW parent={0} param={1} val={2} unit={3} ref={4} date={5} src={6}" -f $_.parentTestName, $pname, $_.resultSummary, $_.unit, $_.referenceRange, $_.date, $_.sourceModule)
  }
} else {
  Write-Output 'BLOCKER no patient with RELEASED lab history in API'
}

Write-Output "MULTI_PARAM_SAMPLES=$($allSamples.Count)"
$allSamples | Select-Object -First 12 | Format-Table -AutoSize | Out-String | Write-Output

if ($best -and $best.rows[0].reportId) {
  $rid = $best.rows[0].reportId
  $report = Invoke-RestMethod -Method Get -Uri "$base/hms/control/labGetReport?userTenantId=$tenant&reportId=$rid" -Headers $headers
  $rep = $report.report
  if ($rep) {
    Write-Output "REPORT_COMPARE reportId=$rid testName=$($rep.testName)"
    $results = @($rep.results)
    foreach ($res in $results | Select-Object -First 1) {
      $params = @($res.parameters)
      if ($params.Count -eq 0 -and $res.resultValue) {
        Write-Output ("  REPORT_PARAM name={0} val={1} unit={2}" -f $res.testName, $res.resultValue, $res.resultUnit)
      } else {
        foreach ($pp in $params | Select-Object -First 6) {
          Write-Output ("  REPORT_PARAM name={0} val={1} unit={2} ref={3}" -f $pp.paramName, $pp.value, $pp.unit, $pp.referenceRange)
        }
      }
    }
  }
}

# Isolation: second patient must not appear in first patient's history
if ($best -and $patients.Count -ge 2) {
  $other = @($patients | Where-Object { $_.partyId -ne $best.partyId } | Select-Object -First 1)
  if ($other) {
    $leak = @($best.rows | Where-Object { $_.partyId -and $_.partyId -ne $best.partyId })
    Write-Output "ISOLATION otherParty=$($other.partyId) leaks=$($leak.Count)"
    if ($leak.Count -gt 0) { exit 5 }
    Write-Output 'ISOLATION_OK'
  }
}

if ($allSamples.Count -lt 2) {
  Write-Output 'UAT_LIMITED insufficient multi-parameter RELEASED rows for full LFT/CBC comparison'
  exit 0
}
Write-Output 'UAT_API_PASS multi-parameter rows present with distinct parent vs parameter names'
