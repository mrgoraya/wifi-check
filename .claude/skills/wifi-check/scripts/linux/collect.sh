#!/usr/bin/env bash
# wifi-check collector for Linux. Read-only: changes nothing on the computer or router.
# Prints one JSON object to stdout (same shape as the macOS collector).
#
# Needs: jq, iproute2 (ip), ping, curl. Uses if present: iw, nmcli, dig, traceroute or tracepath.
# Usage: collect.sh [--quick] [--trace] [--save LABEL]
#   --quick        skip the ~20 s speed test
#   --trace        always run a traceroute (otherwise only when internet ping is high)
#   --save LABEL   also save the result to ~/.wifi-check/runs/<time>-<LABEL>.json

QUICK=0 TRACE=0 LABEL=""
while [ $# -gt 0 ]; do
  case $1 in
    --quick) QUICK=1 ;;
    --trace) TRACE=1 ;;
    --save) LABEL=$2; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

have() { command -v "$1" >/dev/null 2>&1; }
for t in jq ip ping curl; do have "$t" || { echo "missing: $t (install it with your package manager)" >&2; exit 1; }; done

read -r GW IF < <(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++){if($i=="via")g=$(i+1); if($i=="dev")d=$(i+1)} print g, d; exit}')
MYIP=$(ip -4 -o addr show dev "${IF:-lo}" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')

# Wi-Fi interface: the default-route one if it is wireless, else the first wireless one
WIF=""
if [ -n "$IF" ] && [ -d "/sys/class/net/$IF/wireless" ]; then WIF=$IF
else for d in /sys/class/net/*/wireless; do [ -d "$d" ] && { WIF=$(basename "$(dirname "$d")"); break; }; done; fi

freq_to_chan() {  # MHz -> channel
  awk -v f="$1" 'BEGIN{ if (f==2484) c=14; else if (f>=2412 && f<2484) c=(f-2407)/5;
    else if (f>=5000 && f<5925) c=(f-5000)/5; else if (f>=5925) c=(f-5950)/5; else c=""; print c }'
}
band_of() { awk -v f="$1" 'BEGIN{ if (f=="") print ""; else if (f<3000) print "2GHz"; else if (f<5925) print "5GHz"; else print "6GHz" }'; }

# ---------- Wi-Fi link ----------
LINK=null
if [ -n "$WIF" ] && have iw; then
  L=$(iw dev "$WIF" link 2>/dev/null)
  FREQ=$(echo "$L" | awk '/freq:/{print int($2)}')
  SIG=$(echo "$L" | awk '/signal:/{print $2}')
  TX=$(echo "$L" | awk '/tx bitrate:/{print int($3)}')
  WIDTH=$(echo "$L" | grep -oE '[0-9]+MHz' | head -1)
  PHY=$(echo "$L" | awk '/tx bitrate:/{ if (/EHT/) print "802.11be"; else if (/HE-MCS/) print "802.11ax"; else if (/VHT/) print "802.11ac"; else if (/MCS/) print "802.11n"; else print "802.11a/b/g" }')
  NOISE=$(iw dev "$WIF" survey dump 2>/dev/null | awk '/in use/{f=1} f && /noise:/{print $2; exit}')
  SEC=""
  have nmcli && SEC=$(nmcli -t -f ACTIVE,SECURITY dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
  LINK=$(jq -n --arg phy "$PHY" --arg ch "$(freq_to_chan "$FREQ")" --arg band "$(band_of "$FREQ")" \
    --arg w "${WIDTH:-}" --arg sec "$SEC" --arg sig "$SIG" --arg noi "$NOISE" --arg tx "$TX" \
    '{phy: $phy, channel: ($ch|tonumber?), band: (if $band=="" then null else $band end),
      width: (if $w=="" then null else $w end), security: (if $sec=="" then null else $sec end),
      signal_dbm: ($sig|tonumber?), noise_dbm: ($noi|tonumber?),
      snr_db: (if ($sig|tonumber?) and ($noi|tonumber?) then ($sig|tonumber) - ($noi|tonumber) else null end),
      tx_rate_mbps: ($tx|tonumber?), mcs: null}')
fi

# ---------- nearby networks (nmcli gives signal as 0-100 %, converted to approx. dBm) ----------
NEARBY="[]"
if have nmcli; then
  NEARBY=$(nmcli -t -f IN-USE,CHAN,FREQ,SIGNAL dev wifi list 2>/dev/null | awk -F: '$1!="*"{print $2 "\t" $3 "\t" $4}' |
    jq -R 'split("\t") as $f | ($f[1] | capture("(?<m>[0-9]+)") .m | tonumber?) as $mhz
      | {channel: ($f[0]|tonumber?),
         band: (if $mhz == null then null elif $mhz < 3000 then "2GHz" elif $mhz < 5925 then "5GHz" else "6GHz" end),
         width: null, signal_dbm: (($f[2]|tonumber?) as $p | if $p then ($p/2 - 100 | floor) else null end),
         noise_dbm: null, phy: null, signal_approx: true}' | jq -s 'unique')
fi

# ---------- ping ----------
ping_json() {  # host count
  ping -c "$2" -i 0.2 -W 1 "$1" 2>/dev/null | awk -v h="$1" '
    /packets transmitted/ {sent=$1; recv=$4; for(i=1;i<=NF;i++) if ($i ~ /%$/) {loss=$i; sub(/%/,"",loss)}}
    /^(rtt|round-trip)/ {split($4,a,"/"); mn=a[1]; av=a[2]; mx=a[3]; sd=a[4]}
    END {print h "\t" sent "\t" recv "\t" loss "\t" mn "\t" av "\t" mx "\t" sd}' |
  jq -R 'split("\t") | {host: .[0], sent: (.[1]|tonumber?), received: (.[2]|tonumber?),
    loss_pct: (.[3]|tonumber?), min_ms: (.[4]|tonumber?), avg_ms: (.[5]|tonumber?),
    max_ms: (.[6]|tonumber?), stddev_ms: (.[7]|tonumber?)}'
}
PING_ROUTER=null; [ -n "$GW" ] && PING_ROUTER=$(ping_json "$GW" 30)
PING_NET=$(ping_json 1.1.1.1 30)

# ---------- DNS ----------
if have resolvectl; then
  DNS_LIST=$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F:]{6,}' | sort -u)
else
  DNS_LIST=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | sort -u)
fi
DNS_SERVERS=$(printf '%s\n' "$DNS_LIST" | sed '/^$/d' | jq -R . | jq -s .)
DNS_LOOKUPS=$(for d in google.com youtube.com wikipedia.org; do
  if have dig; then ms=$(dig +tries=1 +time=3 "$d" 2>/dev/null | awk '/Query time/{print $4}')
  else s=$(date +%s%N); getent hosts "$d" >/dev/null 2>&1 && ms=$(( ($(date +%s%N) - s) / 1000000 )) || ms=""; fi
  jq -n --arg d "$d" --arg ms "$ms" '{domain: $d, ms: ($ms|tonumber?)}'
done | jq -s .)

# ---------- traceroute ----------
TRACE_JSON=null
NET_AVG=$(echo "$PING_NET" | jq '(.avg_ms // 0) | floor')
if [ "$TRACE" = 1 ] || [ "${NET_AVG:-0}" -gt 50 ]; then
  if have traceroute; then
    TRACE_JSON=$(traceroute -n -q 1 -w 1 -m 15 1.1.1.1 2>/dev/null | awk '
      $1 ~ /^[0-9]+$/ { ip=$2; ms=($3 ~ /^[0-9.]+$/) ? $3 : ""; if (ip=="*") ip=""; print $1 "\t" ip "\t" ms }' |
      jq -R 'split("\t") | {hop: (.[0]|tonumber), ip: (if .[1]=="" then null else .[1] end), ms: (.[2]|tonumber?)}' | jq -s .)
  elif have tracepath; then
    TRACE_JSON=$(tracepath -n -m 15 1.1.1.1 2>/dev/null | awk '
      $1 ~ /^[0-9]+:$/ && $2 != "no" { h=$1; sub(/:/,"",h); if (seen[h]++) next; ip=$2; ms=""; for(i=3;i<=NF;i++) if ($i ~ /ms$/) {ms=$i; sub(/ms/,"",ms); break}; print h "\t" ip "\t" ms }' |
      jq -R 'split("\t") | {hop: (.[0]|tonumber), ip: .[1], ms: (.[2]|tonumber?)}' | jq -s .)
  fi
fi

# ---------- speed and lag under load (Cloudflare speed test endpoints, single connection) ----------
SPEED=null
if [ "$QUICK" = 0 ]; then
  IDLE=$(echo "$PING_NET" | jq '.min_ms // empty')
  ping -i 0.2 -W 1 -w 22 1.1.1.1 2>/dev/null | awk -F'time=' '/time=/{split($2,a," "); print a[1]}' > /tmp/wifi-check-load.$$ &
  PP=$!
  DL=$(curl -s -o /dev/null --max-time 10 -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=500000000')
  UL=$(head -c 200000000 /dev/zero | curl -s -o /dev/null --max-time 10 -w '%{speed_upload}' --data-binary @- 'https://speed.cloudflare.com/__up')
  kill "$PP" 2>/dev/null; wait "$PP" 2>/dev/null
  LOADED=$(awk '{s+=$1; n++} END{if(n) printf "%.1f", s/n}' /tmp/wifi-check-load.$$); rm -f /tmp/wifi-check-load.$$
  SPEED=$(jq -n --arg dl "$DL" --arg ul "$UL" --arg idle "$IDLE" --arg loaded "$LOADED" '
    ($idle|tonumber?) as $i | ($loaded|tonumber?) as $l | (if $i and $l then $l - $i else null end) as $inc
    | {download_mbps: (($dl|tonumber? // 0) * 8 / 1e6 | floor), upload_mbps: (($ul|tonumber? // 0) * 8 / 1e6 | floor),
       idle_latency_ms: ($i|floor?), loaded_latency_ms: ($l|floor?), responsiveness_rpm: null,
       bufferbloat_added_ms: ($inc|floor?),
       bufferbloat_grade: (if $inc == null then null elif $inc < 5 then "A+" elif $inc < 30 then "A" elif $inc < 60 then "B"
                           elif $inc < 200 then "C" elif $inc < 400 then "D" else "F" end),
       method: "single-connection curl to speed.cloudflare.com; may under-read very fast lines"}')
fi

# ---------- devices ----------
DEVICES=null
if [ -n "$GW" ]; then
  NET=${GW%.*}
  for i in $(seq 1 254); do ping -c1 -W 1 "$NET.$i" >/dev/null 2>&1 & done; wait
  DEVICES=$(ip -4 neigh show dev "$IF" 2>/dev/null | awk '/lladdr/ && $NF != "FAILED" {print $1 "\t" $3}' | grep "^$NET\." |
    jq -R --arg gw "$GW" '
      split("\t") as $f | ($f[1] | ascii_downcase) as $mac
      | {ip: $f[0], mac: $mac,
         randomized_mac: (($mac[1:2]) as $c | ["2","6","a","e"] | index($c) != null),
         role: (if $f[0]==$gw then "router" else null end)}' | jq -s .)
  [ -n "$MYIP" ] && DEVICES=$(echo "$DEVICES" | jq --arg me "$MYIP" --arg mac "$(cat /sys/class/net/$IF/address 2>/dev/null)" \
    '. + [{ip: $me, mac: $mac, randomized_mac: null, role: "this_computer"}]')
fi

# ---------- router page and security ----------
ROUTER=null
if [ -n "$GW" ]; then
  PAGE=$(curl -s -m 5 "http://$GW" 2>/dev/null)
  TITLE=$(echo "$PAGE" | grep -ioE '<title>[^<]*' | head -1 | sed 's/<title>//I')
  DSLITE=false; echo "$PAGE" | grep -qi 'aftr' && DSLITE=true
  HTTPS=false; curl -sk -m 4 -o /dev/null "https://$GW" 2>/dev/null && HTTPS=true
  PORTS=$(for p in 21 22 23 53 80 139 443 445 1900 5000 7547 8080 8443 49152; do
    timeout 1 bash -c "</dev/tcp/$GW/$p" >/dev/null 2>&1 && echo "$p"
  done | jq -R 'tonumber' | jq -s '
    map({port: ., service: ({"21":"FTP","22":"SSH","23":"Telnet","53":"DNS","80":"HTTP admin",
      "139":"SMB","443":"HTTPS admin","445":"SMB file sharing","1900":"UPnP","5000":"UPnP/web",
      "7547":"TR-069 provider management","8080":"alt HTTP","8443":"alt HTTPS","49152":"UPnP"}[tostring])})')
  ROUTER=$(jq -n --arg gw "$GW" --arg t "$TITLE" --argjson ds $DSLITE --argjson https $HTTPS \
    --argjson ports "${PORTS:-[]}" \
    '{admin_url: ("http://" + $gw), page_title: $t, ds_lite: $ds, admin_https: $https,
      open_tcp_ports: $ports, upnp_answering: null}')
fi

# ---------- assemble ----------
RESULT=$(jq -n \
  --arg time "$(date '+%Y-%m-%dT%H:%M:%S%z')" --arg label "$LABEL" \
  --arg gw "$GW" --arg if "$IF" --arg me "$MYIP" \
  --argjson link "${LINK:-null}" --argjson nearby "${NEARBY:-[]}" \
  --argjson pr "${PING_ROUTER:-null}" --argjson pn "${PING_NET:-null}" \
  --argjson dnss "${DNS_SERVERS:-[]}" --argjson dnsl "${DNS_LOOKUPS:-[]}" \
  --argjson trace "${TRACE_JSON:-null}" --argjson speed "${SPEED:-null}" \
  --argjson devices "${DEVICES:-null}" --argjson router "${ROUTER:-null}" \
  '{time: $time, os: "linux", label: (if $label=="" then null else $label end),
    route: {gateway: (if $gw=="" then null else $gw end), interface: $if, this_mac_ip: $me},
    wifi: $link, nearby_networks: $nearby,
    ping_router: $pr, ping_internet: $pn,
    dns: {servers: $dnss, lookups: $dnsl},
    traceroute: $trace, speed: $speed, devices: $devices, router: $router}')

echo "$RESULT"

if [ -n "$LABEL" ]; then
  DIR="$HOME/.wifi-check/runs"; mkdir -p "$DIR"
  FILE="$DIR/$(date +%Y%m%d-%H%M%S)-$(echo "$LABEL" | tr -c 'A-Za-z0-9_-\n' '_').json"
  echo "$RESULT" > "$FILE"
  echo "saved: $FILE" >&2
fi
