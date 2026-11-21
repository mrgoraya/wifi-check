# wifi-check watcher for Windows: pings the router and the internet every few seconds
# for a while, to catch problems that come and go. Read-only.
#
# Usage: powershell -ExecutionPolicy Bypass -File watch.ps1 [-Minutes 10] [-Interval 2]
# Writes a CSV log to %USERPROFILE%\.wifi-check\watch\<time>.csv and prints a JSON summary.

param([double]$Minutes = 10, [double]$Interval = 2)

$ErrorActionPreference = 'SilentlyContinue'
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
$GW = if ($route) { $route.NextHop } else { $null }
$NetHost = '1.1.1.1'
$dir = Join-Path $HOME '.wifi-check\watch'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$csv = Join-Path $dir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
'time,router_ms,internet_ms' | Out-File -FilePath $csv -Encoding ascii
[Console]::Error.WriteLine("watching for $Minutes min every ${Interval}s, log: $csv")

$p = New-Object System.Net.NetworkInformation.Ping
function One($h) { if (-not $h) { return $null }; $r = $p.Send($h, 1000); if ($r -and $r.Status -eq 'Success') { return [double]$r.RoundtripTime }; return $null }

$rows = @()
$end = (Get-Date).AddMinutes($Minutes)
while ((Get-Date) -lt $end) {
  $t = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $r = One $GW; $n = One $NetHost
  "$t,$r,$n" | Out-File -FilePath $csv -Append -Encoding ascii
  $rows += [pscustomobject]@{ time = $t; r = $r; n = $n }
  Start-Sleep -Milliseconds ([int]($Interval * 1000))
}

# ---------- summary ----------
$spike = 100
function Stats($rows, $prop) {
  $ok = @($rows | Where-Object { $null -ne $_.$prop } | ForEach-Object { $_.$prop } | Sort-Object)
  $lost = @($rows | Where-Object { $null -eq $_.$prop }).Count
  $o = [ordered]@{ lost = $lost; spikes_over_100ms = @($ok | Where-Object { $_ -gt $spike }).Count; avg_ms = 0; p95_ms = 0; max_ms = 0 }
  if ($ok.Count) {
    $o.avg_ms = [math]::Round(($ok | Measure-Object -Average).Average, 1)
    $idx = [math]::Min($ok.Count, [math]::Max(1, [int][math]::Round(0.95 * $ok.Count))) - 1
    $o.p95_ms = $ok[$idx]; $o.max_ms = $ok[-1]
  }
  return $o
}
$incidents = @(); $in = $false; $start = $null; $last = $null; $atHome = $false
foreach ($row in $rows) {
  $rbad = ($null -eq $row.r) -or ($row.r -gt $spike)
  $ibad = ($null -eq $row.n) -or ($row.n -gt $spike)
  if (($rbad -or $ibad) -and -not $in) { $in = $true; $start = $row.time; $atHome = $false }
  if ($rbad -or $ibad) { $last = $row.time; if ($rbad) { $atHome = $true } }
  if (-not ($rbad -or $ibad) -and $in) {
    $in = $false
    $incidents += [ordered]@{ start = $start; end = $last; side = if ($atHome) { 'home (router ping bad)' } else { 'provider/internet (only internet ping bad)' } }
  }
}
if ($in) { $incidents += [ordered]@{ start = $start; end = $last; side = if ($atHome) { 'home (router ping bad)' } else { 'provider/internet (only internet ping bad)' } } }

[ordered]@{
  log_csv = $csv; router = $GW; internet_host = $NetHost
  samples = $rows.Count; from = $rows[0].time; to = $rows[-1].time
  router_ping = Stats $rows 'r'
  internet_ping = Stats $rows 'n'
  incidents = $incidents.Count; incident_list = @($incidents | Select-Object -First 20)
} | ConvertTo-Json -Depth 5
