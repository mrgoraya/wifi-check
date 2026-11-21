# Where routers keep their settings

Menus change with firmware, so treat these as starting points and fall back to browsing. If a model is missing, look for: Status / Overview, Wi-Fi or WLAN, Network / LAN, Internet / WAN, Advanced / Expert mode.

## General tips

- Many routers hide channel, width and QoS settings behind an **Advanced** or **Expert** mode switch, often in a hamburger (≡) menu that only appears in a wide window.
- The **default admin password** is usually on a sticker on the router.
- **Device details** are often in collapsed rows; the text is usually already in the page and can be read without clicking.
- **Blocking a device** is usually in the device list (block / pause / edit) or in a MAC filter / access control page. It's weak against devices that change their MAC; changing the Wi-Fi password is the lasting fix.
- **ISP-supplied routers** often have no QoS/SQM. Real bufferbloat fixes then need the user's own router behind the provider's one, with SQM (e.g. OpenWrt, or a router with "Smart Queue" / "Adaptive QoS").

## Vodafone Station (Germany, cable)

- Admin: `http://192.168.0.1`. Firmware and AFTR (DS-Lite) shown on the login page.
- **Status & Hilfe > Status** (`?status_status`): firmware, uptime, firewall, and per-band Wi-Fi **channel and width** (read-only here).
- **Status & Hilfe > DOCSIS Status** (`?status_docsis`): downstream/upstream channel tables for the cable line check.
- **Übersicht** (`?overview`): connected devices; expand a row for IP, band (2,4/5 GHz) and link rate. "Mehr anzeigen" shows the rest.
- **WLAN > Allgemein** (`?wifi_general`): SSID, band steering, guest Wi-Fi. **WLAN > WPS** (`?wifi_wps`).
- Channel and width settings and more options appear only after switching to **Experten-Modus** in the ≡ menu; the menu needs a wide window.
- Pages load slowly; wait a few seconds before reading.
- If the cable line is weak, the user can ask Vodafone for a "Leitungsprüfung" (line check).
- Blocking: each device row in **Übersicht** has a pencil ("Gerät bearbeiten"); look there first. In Experten-Modus, also look under WLAN for MAC filtering / access control.

## FRITZ!Box (AVM)

- Admin: `http://fritz.box` (or `192.168.178.1`).
- Switch on **Ansicht: Erweitert / Advanced view** (bottom of the left menu) for more settings.
- Wi-Fi channel: **WLAN > Funkkanal / Wireless Channel**; it also shows a neighbour-network graph.
- Devices: **Heimnetz > Netzwerk / Home Network > Network**.
- Line: **Internet > DSL-Informationen** (DSL) or **Internet > Kabel-Informationen** (cable).
- Traffic priority: **Internet > Filter > Priorisierung / Prioritization**.
- Blocking: **Heimnetz > Netzwerk**, edit the device, set Internet use to blocked ("gesperrt"); for Wi-Fi access, **WLAN > Sicherheit** can stop new devices joining (MAC filter).

## Telekom Speedport

- Admin: `http://speedport.ip` (or `192.168.2.1`).
- Wi-Fi channel: **WLAN > Funkkanal / WLAN channel** (under advanced settings).
- Line: **Status > DSL information** or the hidden `http://speedport.ip/engineer/html/dsl.html` on some models.
- Blocking: look in **Heimnetz** for the device list and its block option, or the WLAN access / MAC filter settings.

## TP-Link

- Admin: `http://tplinkwifi.net` (or `192.168.0.1` / `192.168.1.1`).
- **Advanced > Wireless > Wireless Settings** for channel/width; **Advanced > QoS** on most models.
- Devices: **Network Map > Clients** (with a Block button on most models).
- Blocking: also **Advanced > Security > Access Control** (blacklist).

## ASUS

- Admin: `http://router.asus.com` (or `192.168.50.1` / `192.168.1.1`).
- **Wireless > General** for channel/width; **Adaptive QoS** (some models have "Smart Queue"-style FQ-CoDel under **Traditional QoS**).
- Devices: **Network Map > Clients**; a client's panel has **Block Internet Access**.
- Blocking Wi-Fi itself: **Wireless > Wireless MAC Filter**.

## Netgear

- Admin: `http://routerlogin.net`.
- **Advanced > Setup > Wireless Setup** for channel; **Setup > QoS** on some models.
- Devices: **Attached Devices**.
- Blocking: **Advanced > Security > Access Control** (turn on, then block the device).

## Google Nest Wifi / Eero / Apple mesh systems

- No web admin page; settings live in the phone app (Google Home, Eero). Tell the user what to check there; the Mac checks still apply.
- Blocking: in the app, open the device and choose block / pause; changing the Wi-Fi password is also done there.

## OpenWrt

- Admin: LuCI at `http://192.168.1.1`.
- **Network > Wireless** for channel/width; SQM via the `luci-app-sqm` package (**Network > SQM QoS**), the best bufferbloat fix available.
- Blocking: **Network > Wireless > Edit > MAC-Filter** (deny list).
