# Home network security audit

Rate each item **OK**, **improve** or **fix now**, and explain the risk in one plain sentence. Don't change anything without the user's approval.

| Item | Where to see it | OK | Improve | Fix now |
|---|---|---|---|---|
| Wi-Fi encryption | `wifi.security` / router Wi-Fi page | WPA3, or WPA2/WPA3 mixed | WPA2 only (fine, but WPA3 is better if all devices support it) | WEP, WPA (v1), TKIP or open network |
| WPS | router Wi-Fi / WPS page | off | push-button only | PIN method on |
| Router admin password | ask the user | changed from the sticker default | | still the default, or empty |
| Wi-Fi password | ask the user (never ask them to say it) | long and unique (12+ characters) | short or shared widely | default from the sticker, or simple |
| Firmware | router status page | updated in the last year, or auto-update on | 1-2 years old | older than 2 years, or vendor no longer supports the model |
| Remote admin from the internet | router admin / remote access settings | off | | on with a default or weak password |
| UPnP | `router.upnp_answering`, router settings | off, or on with a reason (game consoles) | on and not needed | |
| Open ports on the router | `router.open_tcp_ports` | 53 (DNS) and 80/443 (admin page) are normal on the inside | 5000 / 49152 (UPnP), 7547 (provider management, normal on provider routers) | 21 (FTP), 23 (Telnet), 139/445 (file sharing) open without the user knowing why |
| Admin page over HTTPS | `router.admin_https` | yes | no (common on home routers, low risk inside the home) | |
| Guest network | router Wi-Fi page | on and isolated for visitors and smart gadgets, or not needed | visitors use the main network | |
| Unknown devices | device list | all recognised | | a device nobody recognises (see SKILL.md section 6) |
| Port forwarding / exposed host | router internet / NAT pages | none, or only ones the user set up on purpose | | forwards or an "exposed host" nobody remembers creating |

Notes:
- The open-port check only looks from inside the home. Whether those ports are reachable from the internet can't be tested from here.
- Provider-managed routers (cable, fibre) often keep 7547 (TR-069) and remote management for the provider. That's normal; mention it, don't alarm.
- Never test a password by trying to log in with guesses.
