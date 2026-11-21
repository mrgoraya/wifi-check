# wifi-check collector for Windows 10/11 (Windows PowerShell 5.1 or PowerShell 7).
# Read-only: changes nothing on the computer or router.
# Prints one JSON object to stdout (same shape as the macOS and Linux collectors).
#
# Usage: powershell -ExecutionPolicy Bypass -File collect.ps1 [-Quick] [-Trace] [-Save LABEL]
#   -Quick        skip the ~20 s speed test
#   -Trace        always run a traceroute (otherwise only when internet ping is high)
#   -Save LABEL   also save the result to %USERPROFILE%\.wifi-check\runs\<time>-<LABEL>.json
#
# Wi-Fi details come from `netsh wlan`, whose labels depend on the Windows language.
# English and German labels are recognised; on other languages some Wi-Fi fields may be null.

param([switch]$Quick, [switch]$Trace, [string]$Save = "")

$ErrorActionPreference = 'SilentlyContinue'

function Num($v) { if ($null -eq $v -or "$v" -eq '') { return $null }; $d = 0.0
  if ([double]::TryParse(("$v" -replace ',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }; return $null }

# ---------- route ----------
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
$GW = if ($route) { $route.NextHop } else { $null }
$IFX = if ($route) { $route.InterfaceIndex } else { $null }
$IFNAME = if ($route) { $route.InterfaceAlias } else { $null }
$MYIP = if ($IFX) { (Get-NetIPAddress -InterfaceIndex $IFX -AddressFamily IPv4 | Select-Object -First 1).IPAddress } else { $null }

# ---------- netsh parsing helpers ----------
function Get-Field($lines, [string[]]$keys) {
  foreach ($l in $lines) {
    if ($l -match '^\s*([^:]+?)\s*:\s*(.*)$') {
      $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
      foreach ($key in $keys) { if ($k -eq $key) { return $v } }
    }
  }
  return $null
}
function Pct-To-Dbm($p) { $n = Num ("$p" -replace '%', ''); if ($null -eq $n) { return $null }; return [math]::Floor($n / 2 - 100) }
function Chan-Band($ch) { if ($null -eq $ch) { return $null }; if ($ch -le 14) { '2GHz' } else { '5GHz' } }

# ---------- Wi-Fi link ----------
$wl = netsh wlan show interfaces 2>$null
$link = $null
if ($wl) {
  $ch    = Num (Get-Field $wl @('Channel', 'Kanal'))
  $rssi  = Num (Get-Field $wl @('Rssi', 'RSSI'))
  $sig   = if ($null -ne $rssi) { $rssi } else { Pct-To-Dbm (Get-Field $wl @('Signal')) }
  $band  = Get-Field $wl @('Band')
  $link = [ordered]@{
    phy          = Get-Field $wl @('Radio type', 'Funktyp')
    channel      = $ch
    band         = if ($band) { ($band -replace '\s', '') } else { Chan-Band $ch }
    width        = $null
    security     = Get-Field $wl @('Authentication', 'Authentifizierung')
    signal_dbm   = $sig
    signal_approx = ($null -eq $rssi)
    noise_dbm    = $null
    snr_db       = $null
    tx_rate_mbps = Num (Get-Field $wl @('Transmit rate (Mbps)', 'Übertragungsrate (MBit/s)', 'Senderate (MBit/s)'))
    mcs          = $null
  }
}

# ---------- nearby networks ----------
$nearby = @()
$nl = netsh wlan show networks mode=bssid 2>$null
if ($nl) {
  $cur = $null
  foreach ($l in $nl) {
    if ($l -match '^\s*BSSID\s*\d+\s*:') { if ($cur) { $nearby += [pscustomobject]$cur }; $cur = [ordered]@{ channel = $null; band = $null; width = $null; signal_dbm = $null; noise_dbm = $null; phy = $null; signal_approx = $true } ; continue }
    if (-not $cur) { continue }
    if ($l -match '^\s*(Signal)\s*:\s*(\d+)%') { $cur.signal_dbm = Pct-To-Dbm $Matches[2] }
    elseif ($l -match '^\s*(Radio type|Funktyp)\s*:\s*(.+)$') { $cur.phy = $Matches[2].Trim() }
    elseif ($l -match '^\s*(Channel|Kanal)\s*:\s*(\d+)') { $cur.channel = [int]$Matches[2]; $cur.band = Chan-Band $cur.channel }
    elseif ($l -match '^\s*Band\s*:\s*(.+)$') { $cur.band = ($Matches[1] -replace '\s', '') }
    elseif ($l -match '^\s*SSID\s*\d+\s*:') { if ($cur) { $nearby += [pscustomobject]$cur }; $cur = $null }
  }
  if ($cur) { $nearby += [pscustomobject]$cur }
}

# ---------- ping (language-independent, via .NET) ----------
function Ping-Stats($target, $count = 30) {
  $p = New-Object System.Net.NetworkInformation.Ping
  $times = @()
  for ($i = 0; $i -lt $count; $i++) {
    $r = $p.Send($target, 1000)
    if ($r -and $r.Status -eq 'Success') { $times += [double]$r.RoundtripTime }
    Start-Sleep -Milliseconds 200
  }
  $recv = $times.Count
  $stats = [ordered]@{ host = $target; sent = $count; received = $recv; loss_pct = [math]::Round(100 * ($count - $recv) / $count, 1)
    min_ms = $null; avg_ms = $null; max_ms = $null; stddev_ms = $null }
  if ($recv -gt 0) {
    $avg = ($times | Measure-Object -Average).Average
    $stats.min_ms = ($times | Measure-Object -Minimum).Minimum
    $stats.max_ms = ($times | Measure-Object -Maximum).Maximum
    $stats.avg_ms = [math]::Round($avg, 2)
    $stats.stddev_ms = [math]::Round([math]::Sqrt((($times | ForEach-Object { ($_ - $avg) * ($_ - $avg) }) | Measure-Object -Sum).Sum / $recv), 2)
  }
  return $stats
}
$pingRouter = if ($GW) { Ping-Stats $GW } else { $null }
$pingNet = Ping-Stats '1.1.1.1'

# ---------- DNS ----------
$dnsServers = @()
if ($IFX) { $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $IFX).ServerAddresses | Sort-Object -Unique) }
$dnsLookups = foreach ($d in 'google.com', 'youtube.com', 'wikipedia.org') {
  $ms = $null
  try { $t = Measure-Command { Resolve-DnsName -Name $d -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Out-Null }; $ms = [math]::Round($t.TotalMilliseconds) } catch {}
  [ordered]@{ domain = $d; ms = $ms }
}

# ---------- traceroute (via .NET TTL, language-independent) ----------
$traceJson = $null
if ($Trace -or ($pingNet.avg_ms -gt 50)) {
  $traceJson = @()
  $p = New-Object System.Net.NetworkInformation.Ping
  $buf = [byte[]](1..32)
  for ($ttl = 1; $ttl -le 15; $ttl++) {
    $opt = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = $p.Send('1.1.1.1', 1000, $buf, $opt)
    $sw.Stop()
    $ip = if ($r -and $r.Address -and $r.Status -ne 'TimedOut') { $r.Address.ToString() } else { $null }
    $traceJson += [ordered]@{ hop = $ttl; ip = $ip; ms = if ($ip) { $sw.ElapsedMilliseconds } else { $null } }
    if ($r.Status -eq 'Success') { break }
  }
}

# ---------- speed and lag under load (Cloudflare speed test endpoints, single connection) ----------
$speed = $null
if (-not $Quick) {
  Add-Type -AssemblyName System.Net.Http
  $job = Start-Job -ScriptBlock {
    $p = New-Object System.Net.NetworkInformation.Ping; $out = @(); $end = (Get-Date).AddSeconds(21)
    while ((Get-Date) -lt $end) { $r = $p.Send('1.1.1.1', 1000); if ($r.Status -eq 'Success') { $out += $r.RoundtripTime }; Start-Sleep -Milliseconds 200 }
    $out
  }
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds(15)
  # download for up to 10 s
  $dlBytes = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $stream = $client.GetStreamAsync('https://speed.cloudflare.com/__down?bytes=500000000').Result
    $buf = New-Object byte[] 65536
    while ($sw.Elapsed.TotalSeconds -lt 10) { $n = $stream.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $dlBytes += $n }
    $stream.Dispose()
  } catch {}
  $dlSecs = $sw.Elapsed.TotalSeconds
  # upload: send 25 MB chunks until 10 s have passed
  $ulBytes = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
  $chunk = New-Object byte[] 25000000
  try {
    while ($sw.Elapsed.TotalSeconds -lt 10) {
      $content = New-Object System.Net.Http.ByteArrayContent(,$chunk)
      $resp = $client.PostAsync('https://speed.cloudflare.com/__up', $content).Result
      if (-not $resp.IsSuccessStatusCode) { break }; $ulBytes += $chunk.Length
    }
  } catch {}
  $ulSecs = $sw.Elapsed.TotalSeconds
  $loadedTimes = Receive-Job -Job $job -Wait -AutoRemoveJob
  $idle = $pingNet.min_ms
  $loaded = if ($loadedTimes) { [math]::Round((($loadedTimes | Measure-Object -Average).Average), 1) } else { $null }
  $inc = if ($null -ne $idle -and $null -ne $loaded) { $loaded - $idle } else { $null }
  $grade = if ($null -eq $inc) { $null } elseif ($inc -lt 5) { 'A+' } elseif ($inc -lt 30) { 'A' } elseif ($inc -lt 60) { 'B' } elseif ($inc -lt 200) { 'C' } elseif ($inc -lt 400) { 'D' } else { 'F' }
  $speed = [ordered]@{
    download_mbps = if ($dlSecs -gt 0) { [math]::Floor($dlBytes * 8 / 1e6 / $dlSecs) } else { 0 }
    upload_mbps = if ($ulSecs -gt 0) { [math]::Floor($ulBytes * 8 / 1e6 / $ulSecs) } else { 0 }
    idle_latency_ms = $idle; loaded_latency_ms = $loaded; responsiveness_rpm = $null
    bufferbloat_added_ms = if ($null -ne $inc) { [math]::Floor($inc) } else { $null }
    bufferbloat_grade = $grade
    method = 'single-connection HTTP to speed.cloudflare.com; may under-read very fast lines'
  }
}

# ---------- devices ----------
$devices = $null
if ($GW -and $IFX) {
  $net = $GW.Substring(0, $GW.LastIndexOf('.'))
  $tasks = foreach ($i in 1..254) { (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$net.$i", 500) }
  try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks) } catch {}
  $devices = @(Get-NetNeighbor -InterfaceIndex $IFX -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like "$net.*" -and $_.State -in 'Reachable', 'Stale', 'Delay', 'Probe', 'Permanent' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne 'FF-FF-FF-FF-FF-FF' -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and -not $_.IPAddress.EndsWith('.255') } |
    ForEach-Object {
      $mac = ($_.LinkLayerAddress -replace '-', ':').ToLower()
      [ordered]@{ ip = $_.IPAddress; mac = $mac; randomized_mac = ('2', '6', 'a', 'e' -contains $mac.Substring(1, 1)); role = if ($_.IPAddress -eq $GW) { 'router' } else { $null } }
    })
  if ($MYIP) {
    $myMac = ((Get-NetAdapter -InterfaceIndex $IFX).MacAddress -replace '-', ':').ToLower()
    $devices += [ordered]@{ ip = $MYIP; mac = $myMac; randomized_mac = $null; role = 'this_computer' }
  }
}

# ---------- router page and security ----------
$router = $null
if ($GW) {
  $page = ''
  try { $page = (Invoke-WebRequest -Uri "http://$GW" -UseBasicParsing -TimeoutSec 5).Content } catch { try { $page = $_.Exception.Response | Out-String } catch {} }
  $title = if ($page -match '<title>([^<]*)') { $Matches[1] } else { '' }
  $https = $false
  try { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }; Invoke-WebRequest -Uri "https://$GW" -UseBasicParsing -TimeoutSec 4 | Out-Null; $https = $true } catch { if ($_.Exception.Response) { $https = $true } }
  $names = @{ 21 = 'FTP'; 22 = 'SSH'; 23 = 'Telnet'; 53 = 'DNS'; 80 = 'HTTP admin'; 139 = 'SMB'; 443 = 'HTTPS admin'; 445 = 'SMB file sharing'; 1900 = 'UPnP'; 5000 = 'UPnP/web'; 7547 = 'TR-069 provider management'; 8080 = 'alt HTTP'; 8443 = 'alt HTTPS'; 49152 = 'UPnP' }
  $open = @()
  foreach ($port in 21, 22, 23, 53, 80, 139, 443, 445, 1900, 5000, 7547, 8080, 8443, 49152) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { if ($c.ConnectAsync($GW, $port).Wait(1000) -and $c.Connected) { $open += [ordered]@{ port = $port; service = $names[$port] } } } catch {}
    $c.Close()
  }
  $router = [ordered]@{ admin_url = "http://$GW"; page_title = $title; ds_lite = ($page -match 'aftr'); admin_https = $https; open_tcp_ports = $open; upnp_answering = $null }
}

# ---------- assemble ----------
$result = [ordered]@{
  time = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); os = 'windows'; label = if ($Save) { $Save } else { $null }
  route = [ordered]@{ gateway = $GW; interface = $IFNAME; this_mac_ip = $MYIP }
  wifi = $link; nearby_networks = @($nearby)
  ping_router = $pingRouter; ping_internet = $pingNet
  dns = [ordered]@{ servers = @($dnsServers); lookups = @($dnsLookups) }
  traceroute = $traceJson; speed = $speed; devices = $devices; router = $router
}
$json = $result | ConvertTo-Json -Depth 6
$json

if ($Save) {
  $dir = Join-Path $HOME '.wifi-check\runs'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $file = Join-Path $dir ("{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($Save -replace '[^A-Za-z0-9_-]', '_'))
  $json | Out-File -FilePath $file -Encoding utf8
  [Console]::Error.WriteLine("saved: $file")
}
