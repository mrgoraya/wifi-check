---
name: wifi-check
description: Diagnose what is slowing down home Wi-Fi and internet from a Mac, Linux or Windows computer - signal, channel clashes with neighbours, router lag, lag under load (bufferbloat), DNS, where on the route lag starts, problems that come and go, devices on the network, unknown devices, router security, the router's own settings and the quality of the line from the provider (cable, DSL or fibre) - and give plain-language fixes, then prove they worked with a before/after comparison. Use when the user says their Wi-Fi or internet is slow, laggy or dropping, asks to check their router or who is on their network, or runs /wifi-check.
---

# Wi-Fi check

Diagnose home Wi-Fi from macOS, Linux or Windows. Works with any router and any provider. Everything is read-only: nothing on the computer or router is changed unless the user approves a specific change.

Scripts are in `${CLAUDE_SKILL_DIR}/scripts/` (if `CLAUDE_SKILL_DIR` is empty, use the folder this SKILL.md is in). All collectors print the same JSON shape. Saved results live in `~/.wifi-check/` (Windows: `%USERPROFILE%\.wifi-check\`) on the user's computer only.

| OS | Collect | Watch | Needs |
|---|---|---|---|
| macOS 15+ | `zsh scripts/macos/collect.sh` | `bash scripts/watch.sh` | built in (`jq` ships with macOS 15) |
| Linux | `bash scripts/linux/collect.sh` | `bash scripts/watch.sh` | `jq`, `ip`, `ping`, `curl`; better with `iw`, `nmcli`, `dig`, `traceroute` |
| Windows 10/11 | `powershell -ExecutionPolicy Bypass -File scripts\windows\collect.ps1` | `... -File scripts\windows\watch.ps1 -Minutes 30` | built in |

Platform differences to keep in mind when judging:
- **macOS** gives real signal and noise in dBm and Apple's multi-connection speed test (`speed.responsiveness_rpm`).
- **Linux** gets signal in dBm from `iw`; nearby networks from `nmcli` are percentages converted to approximate dBm (`signal_approx: true`). Speed uses one connection to Cloudflare (`speed.method`), which can under-read lines above ~500 Mbps.
- **Windows** gets Wi-Fi details from `netsh wlan`, whose labels depend on the Windows language (English and German are recognised; other languages may leave Wi-Fi fields null). Signal is usually a percentage converted to approximate dBm; no noise reading, so no SNR. Speed works like Linux.
- If a tool is missing on Linux, the script says which; suggest installing it with the package manager. On Windows, if scripts are blocked, the `-ExecutionPolicy Bypass` form above runs just this script without changing system settings.
- UPnP detection (`router.upnp_answering`) is macOS only; it's `null` elsewhere.

## 1. Ask two quick questions first

- **Plan speed:** "What download/upload speed do you pay for?" (e.g. 250/50 Mbps). Skip if they don't know.
- **Symptom pattern:** always slow, or only sometimes (evenings, video calls, one room)? "Only sometimes" means run the watcher too (section 4).

## 2. Collect

Run the collector for the user's OS (table above) with `--save before` (Windows: `-Save before`).

About 45 s. Prints one JSON object. Options: `--quick` / `-Quick` skips the speed test; `--trace` / `-Trace` forces a traceroute (it runs automatically when internet ping averages over 50 ms); `--save LABEL` / `-Save LABEL` keeps a copy for before/after comparison.

JSON sections: `wifi`, `nearby_networks`, `ping_router`, `ping_internet`, `dns`, `traceroute`, `speed`, `devices`, `router`.

## 3. Judge the results

| Check | Good | Problem |
|---|---|---|
| `wifi.signal_dbm` | above -60 | below -70: too far from the router or walls in the way |
| `wifi.snr_db` | 25 or more | under 20: interference |
| `wifi.tx_rate_mbps` | 400+ on 5 GHz | under 100: weak link or old standard |
| `ping_router.avg_ms` / `max_ms` | under 5 / under 30 | avg over 10 or max over 50: busy channel or a device hogging airtime |
| `ping_router.loss_pct` | 0 | any loss: interference or weak signal |
| `ping_internet.avg_ms` | under 30 | over 50: provider or line problem |
| `speed.bufferbloat_grade` | A+ or A | C or worse: lag when the line is busy (see below) |
| `speed.download_mbps` vs plan | 80 %+ of plan | under 50 %: test wired (section 5) then contact provider |
| `dns.lookups[].ms` | under 50 | over 100: slow DNS server |
| `nearby_networks` | none on our channel at similar strength | a neighbour on the same channel |
| 2.4 GHz width | 20 MHz on channel 1, 6 or 11 | 40 MHz, or channels between 1/6/11, overlap neighbours |

**Bufferbloat grade** (`bufferbloat_added_ms` = latency under load minus idle): A+ under 5 ms, A under 30, B under 60, C under 200, D under 400, F above. Explain it as "how much lag gets added when someone is downloading or uploading". Fix: QoS/SQM on the router (section 7).

**Traceroute:** hop 1 is the router. If the ms jump at hop 1 → the problem is at home (Wi-Fi). If it jumps at the first hops after the router → the provider's network. If only the last hops are slow → the far end, not the user's problem. Single `null` hops are normal (routers that don't answer).

Other notes:
- A strong network on the same 5 GHz channel as ours is often the router's own second network (guest, mesh, per-band SSID). Confirm on the router page before calling it a neighbour.
- `router.ds_lite: true` means IPv4 is shared with other customers through the provider. If latency is high, suggest asking for a full (dual-stack) IPv4 address.

## 4. Watch over time (for problems that come and go)

Run in the background (default 10 minutes, ping every 2 s); for evening problems, suggest a longer run during the bad time:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/watch.sh" 30 2
```

(Windows: `powershell -ExecutionPolicy Bypass -File scripts\windows\watch.ps1 -Minutes 30 -Interval 2`.)

It prints a JSON summary: losses, spikes over 100 ms, avg/95th percentile/max for router and internet, and an `incident_list` with times. Each incident says whether the router ping was bad ("home": Wi-Fi or the router) or only the internet ping ("provider"). Report the pattern in plain words, e.g. "4 dropouts between 20:10 and 20:40, all on the provider side".

## 5. Wired comparison (when speed or lag is bad)

If the computer can be plugged into the router with an Ethernet cable, ask the user to do it, turn Wi-Fi off, and run the collector with `--save wired`. Same problem when wired → not a Wi-Fi problem (router, line or provider). Fine when wired → the Wi-Fi is the problem.

## 6. Router admin page and security (only if the user wants it)

1. Open `router.admin_url` in the browser. If it is the built-in browser pane, show the pane to the user and suggest making it wide; many router pages hide menus in a narrow window.
2. Ask the user to sign in themselves. Never type the router password, and never read it or the Wi-Fi password out of a settings page.
3. Identify the router (brand, model, firmware). Check `references/routers.md` for where that model keeps its settings; if it isn't listed, browse the menus.
4. Read, don't change:
   - **Wi-Fi:** channel and width per band, band steering, guest network, WPS.
   - **Devices:** name, IP, band, link rate.
   - **Traffic priority:** QoS / SQM / bandwidth control, on or off, or not offered.
   - **System:** firmware version and date, uptime, firewall.
   - **Line from the provider:** cable (DOCSIS), DSL or fibre status. Judge it with `references/line-quality.md`. Often the real cause of lag spikes and dropouts, and no Wi-Fi setting fixes it.
5. If hidden details (e.g. collapsed device rows) can't be clicked, reading the page's text is fine; never submit forms to reveal them.

**Security audit.** Combine the script's `router` section with what the router page shows, and use `references/security.md` to rate each item OK / improve / fix now.

**Unknown devices** (when the user asks, or the device list has entries nobody named):
1. Merge the script's `devices` with the router's device list: name, IP, MAC, band, link rate, `randomized_mac`. Mark the router and this computer (`role`: `this_mac` or `this_computer`).
2. Ask the user which devices they recognise. Never decide on your own that a device is an intruder. Help identify: router name, band, maker from a non-randomized MAC, or turn a device's Wi-Fi off and see which entry disappears.
3. Mention the limits: a sleeping device may be missing from the scan (the router list usually still has it), and phones and laptops use private MACs, so one of the user's own devices can look new.
4. For a device that isn't theirs, offer two options:
   - **Block it in the router** (`references/routers.md`). Quick but weak: it can change its MAC, and whoever uses it knows the Wi-Fi password.
   - **Change the Wi-Fi password and turn WPS off** (recommended). Everyone is disconnected; only the user's devices reconnect. The user types the new password themselves; never type, suggest, store or repeat a Wi-Fi password. Warn that every device (TV, smart gadgets) needs the new password.

## 7. Changes

Suggest changes in the report; make one only after the user approves that specific change. Before asking, explain in plain words what it does, what the user will notice (Wi-Fi often restarts for 30-60 s and devices reconnect), the downside, and that it can be undone. Common ones:
- 2.4 GHz width to 20 MHz on channel 1, 6 or 11.
- WPS off.
- QoS / SQM on, set to about 85-90 % of the measured download and upload speed.
- Blocking an unknown device, or changing the Wi-Fi password (section 6).

Remind the user to log out of the router page when done.

## 8. Before / after

After any change (by Claude or the user: router setting, moved router, new cable), wait a minute for things to settle, then:

Run the collector again with `--save after` (Windows: `-Save after`). Compare with the newest `*-before.json` in the `runs` folder and show a small table of the numbers that matter (signal, router ping avg/max, internet ping, download/upload, bufferbloat grade). Say plainly whether it got better, worse, or no clear change. One run is noisy, so call differences under about 20 % "no clear change".

## 9. Report

Plain language; explain any term the first time it appears.
1. One-sentence verdict: what is actually slowing things down.
2. Problems, biggest first, each with the number that shows it and a concrete fix. If the line from the provider is weak, say what to check at home first (cable, splitter, wall socket) and what to tell the provider.
3. Speed vs plan and the bufferbloat grade.
4. Security: items to fix now.
5. What's fine (short list), including the device list.
6. What wasn't checked and why.
