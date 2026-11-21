#!/bin/zsh
# wifi-check collector for macOS 15+. Read-only: changes nothing on the Mac or router.
# Prints one JSON object to stdout.
#
# Usage: collect.sh [--quick] [--trace] [--save LABEL]
#   --quick        skip the ~20 s speed test
#   --trace        always run a traceroute (otherwise only when internet ping is high)
#   --save LABEL   also save the result to ~/.wifi-check/runs/<time>-<LABEL>.json
#                  (local only, for before/after comparisons)

QUICK=0 TRACE=0 LABEL=""
while (( $# )); do
  case $1 in
    --quick) QUICK=1 ;;
    --trace) TRACE=1 ;;
    --save) LABEL=$2; shift ;;
    *) print -u2 "unknown option: $1"; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null || { print -u2 "jq not found (ships with macOS 15+, or: brew install jq)"; exit 1; }

GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
IF=$(route -n get default 2>/dev/null | awk '/interface/{print $2}')
IF=${IF:-en0}
MYIP=$(ipconfig getifaddr "$IF" 2>/dev/null)
AIRPORT=$(system_profiler SPAirPortDataType 2>/dev/null)

# ---------- Wi-Fi link ----------
LINK=$(print -r -- "$AIRPORT" | awk '
  /Current Network Information/ {f=1; next}
  /Other Local Wi-Fi Networks/ {f=0}
  f && /PHY Mode:/      {sub(/.*PHY Mode: /,"");      phy=$0}
  f && /Channel:/       {sub(/.*Channel: /,"");       ch=$0}
  f && /Security:/      {sub(/.*Security: /,"");      sec=$0}
  f && /Signal \/ Noise:/ {sig=$(NF-4); noi=$(NF-1)}
  f && /Transmit Rate:/ {tx=$NF}
  f && /MCS Index:/     {mcs=$NF}
  END {print phy "\t" ch "\t" sec "\t" sig "\t" noi "\t" tx "\t" mcs}' |
  jq -R 'split("\t") as $f
    | ($f[1] | capture("^(?<c>[0-9]+) \\((?<b>[0-9.]+GHz), (?<w>[0-9]+MHz)\\)") // {}) as $ch
    | {phy: $f[0], channel: ($ch.c|tonumber?), band: $ch.b, width: $ch.w, security: $f[2],
       signal_dbm: ($f[3]|tonumber?), noise_dbm: ($f[4]|tonumber?),
       snr_db: (($f[3]|tonumber?) - ($f[4]|tonumber?)),
       tx_rate_mbps: ($f[5]|tonumber?), mcs: ($f[6]|tonumber?)}')

# ---------- nearby networks ----------
NEARBY=$(print -r -- "$AIRPORT" | awk '
  /Other Local Wi-Fi Networks/ {f=1; next}
  !f {next}
  /^ {12}[^ ].*:$/ { if (ch!="") print ch "\t" sig "\t" noi "\t" phy; ch=sig=noi=phy=""; next }
  /PHY Mode:/ {sub(/.*PHY Mode: /,""); phy=$0}
  /Channel:/  {sub(/.*Channel: /,""); ch=$0}
  /Signal \/ Noise:/ {sig=$(NF-4); noi=$(NF-1)}
  END { if (ch!="") print ch "\t" sig "\t" noi "\t" phy }' |
  jq -R 'split("\t") as $f
    | ($f[0] | capture("^(?<c>[0-9]+) \\((?<b>[0-9.]+GHz), (?<w>[0-9]+MHz)\\)") // {}) as $ch
    | {channel: ($ch.c|tonumber?), band: $ch.b, width: $ch.w,
       signal_dbm: ($f[1]|tonumber?), noise_dbm: ($f[2]|tonumber?), phy: $f[3]}' | jq -s 'unique')

# ---------- ping ----------
ping_json() {  # host count
  ping -c "$2" -i 0.2 "$1" 2>/dev/null | awk -v h="$1" '
    /packets transmitted/ {sent=$1; recv=$4; loss=$7; sub(/%/,"",loss)}
    /round-trip/ {split($4,a,"/"); mn=a[1]; av=a[2]; mx=a[3]; sd=a[4]}
    END {print h "\t" sent "\t" recv "\t" loss "\t" mn "\t" av "\t" mx "\t" sd}' |
  jq -R 'split("\t") | {host: .[0], sent: (.[1]|tonumber?), received: (.[2]|tonumber?),
    loss_pct: (.[3]|tonumber?), min_ms: (.[4]|tonumber?), avg_ms: (.[5]|tonumber?),
    max_ms: (.[6]|tonumber?), stddev_ms: (.[7]|tonumber?)}'
}

if [[ -n "$GW" ]]; then
  PING_ROUTER=$(ping_json "$GW" 30)
else
  PING_ROUTER=null
fi
PING_NET=$(ping_json 1.1.1.1 30)

# ---------- DNS ----------
DNS_SERVERS=$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u | jq -R . | jq -s .)
DNS_LOOKUPS=$(for d in google.com youtube.com wikipedia.org; do
  ms=$(dig +tries=1 +time=3 "$d" 2>/dev/null | awk '/Query time/{print $4}')
  jq -n --arg d "$d" --arg ms "$ms" '{domain: $d, ms: ($ms|tonumber?)}'
done | jq -s .)

# ---------- traceroute (only when useful) ----------
TRACE_JSON=null
NET_AVG=$(print -r -- "$PING_NET" | jq '.avg_ms // 0')
if (( TRACE )) || (( ${NET_AVG%.*} > 50 )); then
  TRACE_JSON=$(traceroute -n -q 1 -w 1 -m 15 1.1.1.1 2>/dev/null | awk '
    NR>0 && $1 ~ /^[0-9]+$/ { ip=$2; ms=($3 ~ /^[0-9.]+$/) ? $3 : ""; if (ip=="*") ip=""; print $1 "\t" ip "\t" ms }' |
    jq -R 'split("\t") | {hop: (.[0]|tonumber), ip: (if .[1]=="" then null else .[1] end), ms: (.[2]|tonumber?)}' | jq -s .)
fi

# ---------- speed and lag under load ----------
SPEED=null
if (( ! QUICK )); then
  SPEED=$(networkQuality -c 2>/dev/null | jq '
    (.base_rtt) as $idle | (if .responsiveness > 0 then 60000 / .responsiveness else null end) as $loaded
    | ($loaded - $idle) as $inc
    | {download_mbps: ((.dl_throughput // 0) / 1e6 | floor),
       upload_mbps: ((.ul_throughput // 0) / 1e6 | floor),
       idle_latency_ms: ($idle | floor), loaded_latency_ms: ($loaded | floor),
       responsiveness_rpm: (.responsiveness | floor),
       bufferbloat_added_ms: ($inc | floor),
       bufferbloat_grade: (if $inc < 5 then "A+" elif $inc < 30 then "A" elif $inc < 60 then "B"
                           elif $inc < 200 then "C" elif $inc < 400 then "D" else "F" end)}' 2>/dev/null || print null)
fi

# ---------- devices ----------
DEVICES=null
if [[ -n "$GW" ]]; then
  NET=${GW%.*}
  for i in {1..254}; do ping -c1 -W 300 "$NET.$i" >/dev/null 2>&1 & done; wait
  DEVICES=$(arp -an | grep -v incomplete | grep "($NET\." | awk '{gsub(/[()]/,"",$2); print $2 "\t" $4}' |
    grep -v "\.255	" |
    jq -R --arg gw "$GW" --arg me "$MYIP" '
      split("\t") as $f
      | ($f[1] | split(":") | map(if length==1 then "0"+. else . end) | join(":")) as $mac
      | {ip: $f[0], mac: $mac,
         randomized_mac: (($mac[1:2] | ascii_downcase) as $c | ["2","6","a","e"] | index($c) != null),
         role: (if $f[0]==$gw then "router" elif $f[0]==$me then "this_mac" else null end)}' | jq -s .)
fi

# ---------- router page and security ----------
ROUTER=null
if [[ -n "$GW" ]]; then
  PAGE=$(curl -s -m 5 "http://$GW" 2>/dev/null)
  TITLE=$(print -r -- "$PAGE" | grep -ioE '<title>[^<]*' | head -1 | sed 's/<title>//I')
  DSLITE=false; print -r -- "$PAGE" | grep -qi 'aftr' && DSLITE=true
  HTTPS=false; curl -sk -m 4 -o /dev/null "https://$GW" 2>/dev/null && HTTPS=true
  PORTS=$(for p in 21 22 23 53 80 139 443 445 1900 5000 7547 8080 8443 49152; do
    nc -z -G 1 -w 1 "$GW" $p >/dev/null 2>&1 && print $p
  done | jq -R 'tonumber' | jq -s '
    map({port: ., service: ({"21":"FTP","22":"SSH","23":"Telnet","53":"DNS","80":"HTTP admin",
      "139":"SMB","443":"HTTPS admin","445":"SMB file sharing","1900":"UPnP","5000":"UPnP/web",
      "7547":"TR-069 provider management","8080":"alt HTTP","8443":"alt HTTPS","49152":"UPnP"}[tostring])})')
  UPNP=false
  printf 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n' |
    nc -u -w 2 239.255.255.250 1900 2>/dev/null | grep -qi "LOCATION:.*$GW" && UPNP=true
  ROUTER=$(jq -n --arg gw "$GW" --arg t "$TITLE" --argjson ds $DSLITE --argjson https $HTTPS \
    --argjson ports "${PORTS:-[]}" --argjson upnp $UPNP \
    '{admin_url: ("http://" + $gw), page_title: $t, ds_lite: $ds, admin_https: $https,
      open_tcp_ports: $ports, upnp_answering: $upnp}')
fi

# ---------- assemble ----------
RESULT=$(jq -n \
  --arg time "$(date '+%Y-%m-%dT%H:%M:%S%z')" --arg label "$LABEL" \
  --arg gw "$GW" --arg if "$IF" --arg me "$MYIP" \
  --argjson link "${LINK:-null}" --argjson nearby "${NEARBY:-[]}" \
  --argjson pr "$PING_ROUTER" --argjson pn "${PING_NET:-null}" \
  --argjson dnss "${DNS_SERVERS:-[]}" --argjson dnsl "${DNS_LOOKUPS:-[]}" \
  --argjson trace "$TRACE_JSON" --argjson speed "$SPEED" \
  --argjson devices "$DEVICES" --argjson router "$ROUTER" \
  '{time: $time, os: "macos", label: (if $label=="" then null else $label end),
    route: {gateway: (if $gw=="" then null else $gw end), interface: $if, this_mac_ip: $me},
    wifi: $link, nearby_networks: $nearby,
    ping_router: $pr, ping_internet: $pn,
    dns: {servers: $dnss, lookups: $dnsl},
    traceroute: $trace, speed: $speed, devices: $devices, router: $router}')

print -r -- "$RESULT"

if [[ -n "$LABEL" ]]; then
  DIR="$HOME/.wifi-check/runs"; mkdir -p "$DIR"
  FILE="$DIR/$(date +%Y%m%d-%H%M%S)-${LABEL//[^A-Za-z0-9_-]/_}.json"
  print -r -- "$RESULT" > "$FILE"
  print -u2 "saved: $FILE"
fi
