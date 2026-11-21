# Judging the line from the provider

Rules of thumb. Exact limits vary by provider and modem, so call values "borderline" rather than "broken" unless they are clearly outside the ranges, and say so in the report. Errors that keep rising matter more than any single reading.

## Cable (DOCSIS)

Status page shows downstream and upstream channel tables. Power is in dBmV (some routers also show dBµV = dBmV + 60).

| Reading | Good | Borderline | Bad |
|---|---|---|---|
| Downstream power | -7 to +7 dBmV | -10 to -7 or +7 to +12 | below -10 or above +15 |
| Downstream SNR/MER, 64QAM | 30 dB or more | 27-30 | under 27 |
| Downstream SNR/MER, 256QAM | 33 dB or more | 30-33 | under 30 |
| Downstream SNR/MER, OFDM (1024/4096QAM) | 35 dB or more | 32-35 | under 32 |
| Upstream transmit power | 38-48 dBmV | 48-51 | above 51 (the modem is shouting to be heard) |
| Lock / ranging status | all locked / success | | any channel unlocked or failed |
| Uncorrectable errors | zero or not rising | slowly rising | rising quickly |

Signs and causes:
- **Large spread in downstream power** (e.g. +6 on low frequencies, -11 on high ones) plus **high upstream power** = signal lost on the way in: long or old coax, a splitter, loose connector or worn wall socket.
- Ask the user to check at home first: remove splitters, use a short good coax cable, tighten connectors. Then ask the provider for a line check and quote the weak readings.

## DSL (ADSL / VDSL)

| Reading | Good | Borderline | Bad |
|---|---|---|---|
| SNR margin (down) | 10 dB or more | 6-10 | under 6 |
| Line attenuation (down) | under 20 dB | 20-40 | over 40 (long distance from the cabinet) |
| CRC / FEC errors | not rising | slowly rising | rising quickly |
| Resyncs since restart | 0 | 1-2 | many |

Causes: long phone extension cable, old in-house wiring, missing or faulty filter/splitter, electrical noise. Plug the router into the first phone socket with a short cable.

## Fibre (FTTH / GPON)

| Reading | Good | Bad |
|---|---|---|
| Optical receive power | -8 to -25 dBm | below -27 dBm or above -8 dBm |
| Link status | up, no flapping | drops in the log |

Causes: bent or dirty fibre patch cable. Don't let the user open or clean the fibre connector themselves; that's for the provider.

## Mobile (4G/5G router)

Check RSRP (good above -90 dBm, bad below -110), SINR (good above 13 dB, bad below 0). Moving the router near a window often helps most.
