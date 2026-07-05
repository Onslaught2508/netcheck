# netcheck – Netzwerk & WLAN Diagnose

Plattformübergreifendes Diagnose-Tool für macOS und Windows.  
Analysiert WLAN-Qualität, Latenz, DNS, Traceroute und Bandbreite – lokal, ohne Cloud-Abhängigkeit.

![Version](https://img.shields.io/badge/version-1.3-blue)
![macOS](https://img.shields.io/badge/macOS-12%2B-lightgrey)
![Windows](https://img.shields.io/badge/Windows-10%2F11-blue)
![Lizenz](https://img.shields.io/badge/Lizenz-MIT-green)

---

## Schnellstart

### macOS
```bash
curl -fsSL https://raw.githubusercontent.com/Onslaught2508/netcheck/main/netcheck.sh | bash
```

### Windows (PowerShell als Administrator)
```powershell
irm https://raw.githubusercontent.com/Onslaught2508/netcheck/main/netcheck.ps1 | iex
```

---

## Was wird geprüft?

| Modul | Beschreibung |
|---|---|
| **Abhängigkeiten** | iperf3, Homebrew (macOS) / winget (Windows) – automatische Installation |
| **System-Info** | Hostname, OS-Version, Nutzer, Zeitstempel |
| **Netzwerk-Interfaces** | Aktive IPv4-Adressen, Standard-Gateway |
| **WLAN – Aktuell** | Funkstandard (WiFi 4/5/6), Band, Kanal, Signal/Rauschen, SNR |
| **WLAN-Umgebung** | Kanal-Belegung durch Nachbar-Netzwerke, Überfüllungs-Warnung |
| **Latenz** | Ping zu Google DNS, Cloudflare DNS, Quad9 – mit Bewertung |
| **DNS-Auflösung** | Auflösungszeit für google.com, github.com, heise.de |
| **Traceroute** | Pfad zu 8.8.8.8, max. 15 Hops |
| **Bandbreite** | TCP-Durchsatz via iperf3, Retransmit-Analyse |

---

## Voraussetzungen

### macOS
- macOS 12 (Monterey) oder neuer
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew – wird automatisch installiert falls fehlend
- iperf3 – wird automatisch via Homebrew installiert falls fehlend

### Windows
- Windows 10 / 11
- PowerShell 5.1 oder neuer
- winget (ab Windows 10 Build 1809 verfügbar)
- iperf3 – wird automatisch via winget installiert falls fehlend

---

## iperf3-Server (Fallback-Logik)

Ab v1.3 verwendet netcheck eine **Fallback-Serverliste**: Das Skript probiert Server
der Reihe nach durch und bricht beim ersten erfolgreichen Test ab.

| Server | Port | Standort | Quelle |
|---|---|---|---|
| `speedtest.serverius.net` | 5002 | Niederlande | Serverius |
| `speedtest.ams1.novogara.net` | 5201 | Amsterdam | Novogara |
| `iperf.online.net` | 5209 | Paris | Online.net |
| `bouygues.testdebit.info` | 5209 | Paris | Bouygues |
| `iperf.he.net` | 5201 | Fremont, USA | Hurricane Electric |

Alle Server werden auf [iperf3serverlist.net](https://iperf3serverlist.net) mit ≥90% Uptime
über 30 Tage überwacht. Sind alle Server nicht erreichbar, gibt das Skript einen Hinweis
mit alternativen Browser-Testlinks aus.

> **Hinweis:** Öffentliche iperf3-Server können temporär überlastet oder offline sein –
> besonders abends und am Wochenende. Das ist kein Fehler des lokalen Netzwerks.

---

## Ausgabe-Beispiel (macOS)

```
══════════════════════════════════════
  📶 WLAN – Aktuelles Netzwerk
══════════════════════════════════════
  ✔  PHY Mode: 802.11ax  ← WiFi 6: aktuell
  ✔  Channel: 36 (5GHz, 80MHz)  ← 5/6 GHz: gut
  ✔  Signal / Noise: -62 dBm / -94 dBm  ← Signal gut (SNR: 32 dB)
  ℹ  Transmit Rate: 612
  ℹ  MCS Index: 6
```

---

## Logfile

Jeder Lauf erzeugt automatisch ein Logfile:

| Plattform | Pfad |
|---|---|
| macOS | `/tmp/netcheck_YYYYMMDD_HHMMSS.log` |
| Windows | `%TEMP%\netcheck_YYYYMMDD_HHMMSS.log` |

---

## Bekannte Einschränkungen

| Einschränkung | Erklärung |
|---|---|
| Ping-Latenz zu Google/Cloudflare erscheint hoch | ICMP wird von großen Providern deprioritisiert – Traceroute-Endlatenzen sind aussagekräftiger |
| iperf3-Server offline | Öffentliche Server haben keine SLA – Fallback-Liste und Alternativlinks vorhanden |
| WLAN-Umgebungsscan (macOS) | Benötigt `system_profiler` – funktioniert nur wenn WLAN aktiv ist |
| Windows: Kanal-Belegung | `netsh` liefert keine Nachbar-Netzwerke – nur eigenes Netzwerk wird bewertet |

---

## Changelog

### v1.3 (2026-07-05)
- **iperf3:** Fallback-Serverliste mit 5 Servern (EU-first, USA als letzter Fallback)
- **iperf3:** `break` nach erstem Erfolg – kein unnötiges Weitertesten
- **iperf3:** Timeout auf 15s reduziert (war 20s)
- **iperf3:** Hinweis mit Alternativ-URLs bei Totalausfall aller Server
- **Server:** Paris `iperf.par2.as49434.net` entfernt (dauerhaft offline)
- **Server:** Amsterdam Novogara, Paris Online.net, Paris Bouygues ergänzt
- **Windows:** `Test-NetConnection` als Vorab-Erreichbarkeitsprüfung vor iperf3-Job

### v1.2 (2026-07-05)
- **Fix:** DNS-Zeitmessung auf `python3` umgestellt – `date +%s%3N` nicht macOS-kompatibel
- **Fix:** iperf3-Hang durch Background-Job mit hartem `kill`-Timeout behoben
- **Fix:** Fehlertext aus iperf3-Output wird jetzt korrekt extrahiert

### v1.1 (2026-07-05)
- **Fix:** macOS-Zeitformat-Kompatibilität bei Datumsberechnungen

### v1.0 (2026-07-05)
- Erstveröffentlichung: macOS (`netcheck.sh`) und Windows (`netcheck.ps1`)

---

## Lizenz

MIT – siehe [LICENSE](LICENSE)

---

## Autor

[Onslaught2508](https://github.com/Onslaught2508)
