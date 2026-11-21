#!/usr/bin/env bash
# wifi-check watcher for macOS and Linux: pings the router and the internet every few
# seconds for a while, to catch problems that come and go. Read-only.
#
# Usage: watch.sh [MINUTES] [INTERVAL_SECONDS]     (defaults: 10 minutes, every 2 s)
# Writes a CSV log to ~/.wifi-check/watch/<time>.csv and prints a JSON summary at the end.

MIN=${1:-10}
INT=${2:-2}
command -v jq >/dev/null || { echo "jq not found (macOS 15+ has it; otherwise install jq)" >&2; exit 1; }

if [ "$(uname)" = "Darwin" ]; then
  GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
  PINGW="-W 1000"   # macOS: milliseconds
else
  GW=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
  PINGW="-W 1"      # Linux: seconds
fi
NETHOST=1.1.1.1
DIR="$HOME/.wifi-check/watch"; mkdir -p "$DIR"
CSV="$DIR/$(date +%Y%m%d-%H%M%S).csv"
echo "time,router_ms,internet_ms" > "$CSV"
echo "watching for $MIN min every ${INT}s, log: $CSV" >&2

one() {  # host -> ms, or empty when lost
  [ -z "$1" ] && return
  ping -c1 $PINGW "$1" 2>/dev/null | awk -F'time=' '/time=/{split($2,a," "); print a[1]}'
}

END_AT=$(awk -v now="$(date +%s)" -v m="$MIN" 'BEGIN{printf "%d", now + m*60}')
while [ "$(date +%s)" -lt "$END_AT" ]; do
  T=$(date '+%Y-%m-%d %H:%M:%S')
  R=$(one "$GW"); N=$(one "$NETHOST")
  echo "$T,$R,$N" >> "$CSV"
  sleep "$INT"
done 2>/dev/null

# ---------- summary ----------
awk -F, -v spike=100 '
  NR==1 {next}
  {
    n++
    t=$1; r=$2; i=$3
    rbad = (r=="" || r+0>spike); ibad = (i=="" || i+0>spike)
    if (r=="") rl++; else { rs[++rc]=r+0; rsum+=r }
    if (i=="") il++; else { is[++ic]=i+0; isum+=i }
    if (r!="" && r+0>spike) rsp++
    if (i!="" && i+0>spike) isp++
    # incident = consecutive samples where either ping is lost or spiking
    bad = rbad || ibad
    if (bad && !inb) { inb=1; s=t; where="" }
    if (bad) { e=t; where = where (rbad ? "R" : "") (ibad ? "I" : "") }
    if (!bad && inb) { inb=0; print "INC\t" s "\t" e "\t" where }
    if (n==1) first=t; last=t
  }
  END {
    if (inb) print "INC\t" s "\t" e "\t" where
    asort_n(rs, rc); asort_n(is, ic)
    printf "SUM\t%d\t%s\t%s\t%d\t%d\t%d\t%d", n, first, last, rl, il, rsp, isp
    printf "\t%.1f\t%.1f\t%.1f", (rc?rsum/rc:0), pct(rs,rc,95), (rc?rs[rc]:0)
    printf "\t%.1f\t%.1f\t%.1f\n", (ic?isum/ic:0), pct(is,ic,95), (ic?is[ic]:0)
  }
  function asort_n(a, k,   i, j, v) { for (i=2;i<=k;i++) { v=a[i]; j=i-1; while (j>0 && a[j]>v) { a[j+1]=a[j]; j-- } a[j+1]=v } }
  function pct(a, k, p,   idx) { if (!k) return 0; idx=int((p/100)*k + 0.5); if (idx<1) idx=1; if (idx>k) idx=k; return a[idx] }
' "$CSV" | jq -R -s --arg csv "$CSV" --arg gw "$GW" '
  split("\n") | map(select(length>0) | split("\t")) as $rows
  | ($rows | map(select(.[0]=="SUM")) | .[0]) as $s
  | ($rows | map(select(.[0]=="INC")) | map({start: .[1], end: .[2],
      side: (if (.[3]|test("R")) then "home (router ping bad)" else "provider/internet (only internet ping bad)" end)})) as $inc
  | {log_csv: $csv, router: $gw, internet_host: "1.1.1.1",
     samples: ($s[1]|tonumber), from: $s[2], to: $s[3],
     router_ping: {lost: ($s[4]|tonumber), spikes_over_100ms: ($s[6]|tonumber),
                   avg_ms: ($s[8]|tonumber), p95_ms: ($s[9]|tonumber), max_ms: ($s[10]|tonumber)},
     internet_ping: {lost: ($s[5]|tonumber), spikes_over_100ms: ($s[7]|tonumber),
                     avg_ms: ($s[11]|tonumber), p95_ms: ($s[12]|tonumber), max_ms: ($s[13]|tonumber)},
     incidents: ($inc | length), incident_list: ($inc | .[:20])}'
