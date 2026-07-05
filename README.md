# netcheck – Netzwerk & WLAN Diagnose

Plattformübergreifendes Diagnose-Tool für macOS, Linux und Windows.  
Analysiert Verbindungsart, WLAN-Qualität, Latenz, DNS, Traceroute und Bandbreite –  
lokal, ohne Cloud-Abhängigkeit, Logfile direkt auf dem Desktop.

![macOS](https://img.shields.io/badge/macOS-12%2B-lightgrey)
![Linux](https://img.shields.io/badge/Linux-bash-orange)
![Windows](https://img.shields.io/badge/Windows-10%2F11-blue)
![Lizenz](https://img.shields.io/badge/Lizenz-MIT-green)

---

## Schnellstart

### macOS / Linux
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
| **Verbindungsart** | Erkennt automatisch WLAN, Ethernet, mobilen Hotspot oder beides gleichzeitig |
| **Abhängigkeiten** | iperf3, Homebrew (macOS) / apt/dnf (Linux) / winget (Windows) – automatische Installation |
| **System-Info** | Hostname, OS-Version, Nutzer, Zeitstempel, Logfile-Pfad |
| **Netzwerk-Interfaces** | Aktive IPv4-Adressen, Standard-Gateway |
| **WLAN** | Funkstandard (WiFi 4/5/6), Band, Kanal, Signal/Rauschen, SNR |
| **WLAN-Umgebung** | Kanal-Belegung durch Nachbar-Netzwerke, Überfüllungs-Warnung (macOS) |
| **Ethernet** | Adapter-Info, Verbindungsgeschwindigkeit, Duplex (Linux: ethtool) |
| **Mobiler Hotspot** | Erkennung via IP-Bereich (172.20.10.x), kontextbezogene Hinweise |
| **Latenz** | Ping zu Google DNS, Cloudflare DNS, Quad9 – mit Bewertung |
| **DNS-Auflösung** | Auflösungszeit für google.com, github.com, heise.de |
| **Traceroute** | Pfad zu 8.8.8.8, max. 15 Hops |
| **Bandbreite** | TCP-Durchsatz via iperf3, Retransmit-Analyse, 5-Server-Fallback |

---

## Verbindungsart-Erkennung

Das Skript erkennt vor jedem Test automatisch die aktive Verbindungsart und passt
die Ausgabe entsprechend an:

| Erkannte Verbindung | Verhalten |
|---|---|
| **WLAN** | WLAN-Details, Kanal-Umgebung (macOS), Signal-Bewertung |
| **Ethernet** | Adapter-Info, Geschwindigkeit, Duplex |
| **Mobiler Hotspot** | Hinweis auf eingeschränkte Bandbreite, Kontext bei Traceroute und iperf3 |
| **WLAN + Ethernet** | Beide ausgeben, Warnung zur Routing-Priorität |
| **Nichts aktiv** | Fehlermeldung |

**Hotspot-Erkennung:** IP-Bereich `172.20.10.x` wird als iOS Personal Hotspot erkannt.
Die `* * *`-Zeilen im Traceroute sind bei Hotspot-Verbindungen normal –
iOS blockiert ICMP-Weiterleitungen.

---

## Voraussetzungen

### macOS
- macOS 12 (Monterey) oder neuer
- Xcode Command Line Tools (`xcode-select --install`) – werden automatisch installiert
- Homebrew – wird automatisch installiert falls fehlend
- iperf3 – wird automatisch via Homebrew installiert falls fehlend

### Linux
- bash 4+
- `iw`, `ethtool` für erweiterte WLAN-/Ethernet-Details (optional)
- iperf3 – wird automatisch via `apt` oder `dnf` installiert falls fehlend

### Windows
- Windows 10 / 11
- PowerShell 5.1 oder neuer
- winget (ab Windows 10 Build 1809 verfügbar)
- iperf3 – wird automatisch via winget installiert falls fehlend

> **Hinweis Windows:** Nach der automatischen iperf3-Installation ist der
> Bandbreiten-Test beim **nächsten** Skriptaufruf verfügbar, da winget den
> PATH erst in einer neuen Session vollständig aktualisiert.

---

## Logfile

Das Logfile wird automatisch auf dem **Desktop** abgelegt:

| Plattform | Pfad |
|---|---|
| macOS (englisch) | `~/Desktop/netcheck_YYYYMMDD_HHMMSS.log` |
| macOS (deutsch) | `~/Schreibtisch/netcheck_YYYYMMDD_HHMMSS.log` |
| Linux | `~/Desktop/netcheck_YYYYMMDD_HHMMSS.log` |
| Windows | `%USERPROFILE%\Desktop\netcheck_YYYYMMDD_HHMMSS.log` |

Der Windows-Pfad wird über
`[System.Environment]::GetFolderPath('Desktop')` ermittelt –
das funktioniert auch bei OneDrive-Ordnerumleitung korrekt.

---

## iperf3-Server (Fallback-Logik)

Ab v1.3 verwendet netcheck eine **Fallback-Serverliste**: Das Skript probiert
Server der Reihe nach durch und bricht beim ersten erfolgreichen Test ab.

| Server | Port | Standort |
|---|---|---|
| `speedtest.serverius.net` | 5002 | Niederlande (Serverius) |
| `speedtest.ams1.novogara.net` | 5201 | Amsterdam (Novogara) |
| `iperf.online.net` | 5209 | Paris (Online.net) |
| `bouygues.testdebit.info` | 5209 | Paris (Bouygues) |
| `iperf.he.net` | 5201 | Fremont, USA (Hurricane Electric) |

Alle Server werden auf [iperf3serverlist.net](https://iperf3serverlist.net)
mit ≥ 90 % Uptime über 30 Tage überwacht.

> **Hinweis:** Öffentliche iperf3-Server können temporär überlastet oder offline sein –
> besonders abends und am Wochenende. Das ist kein Fehler des lokalen Netzwerks.  
> Bei Totalausfall aller Server: [fast.com](https://fast.com) oder
> [speedtest.net](https://speedtest.net) als Alternative.

---

## Bekannte Einschränkungen

| Einschränkung | Erklärung |
|---|---|
| Ping-Latenz zu Google/Cloudflare erscheint hoch | ICMP wird von großen Providern deprioritisiert – Traceroute-Endlatenzen sind aussagekräftiger |
| iperf3-Server offline | Öffentliche Server haben keine SLA – Fallback-Liste und Alternativlinks vorhanden |
| WLAN-Umgebungsscan | Nur macOS via `system_profiler` – Windows und Linux liefern keine Nachbar-Netzwerke |
| Traceroute bei Hotspot | iOS blockiert ICMP-Weiterleitungen – viele `* * *` sind normal und kein Fehler |
| iperf3 PATH (Windows) | Nach Erstinstallation via winget erst beim nächsten Skriptstart im PATH |
| Hotspot-Erkennung | Nur iOS Personal Hotspot (172.20.10.x) – Android-Hotspots nutzen andere IP-Bereiche |

---

## Changelog

### netcheck.sh v2.2 (2026-07-05)
- **Logfile:** Ablage auf `~/Desktop` (englisch) bzw. `~/Schreibtisch` (deutsch) statt `/tmp`
- **Logpfad** wird in der System-Info-Sektion angezeigt

### netcheck.ps1 v2.1 (2026-07-05)
- **Logfile:** Ablage auf Desktop via `GetFolderPath('Desktop')` – OneDrive-sicher
- **Logpfad** wird in der System-Info-Sektion angezeigt
- **iperf3-Fehlerfilter:** `busy` als Fehlertext ergänzt

### netcheck.sh v2.1 / netcheck.ps1 v2.0 (2026-07-05)
- **Verbindungsart-Erkennung:** WLAN, Ethernet, Hotspot, beides gleichzeitig
- **Hotspot-Erkennung:** IP-Bereich 172.20.10.x → kontextbezogene Hinweise
- **Ethernet-Modus:** Adapter-Info, Geschwindigkeit, Duplex (Linux: ethtool)
- **Linux-Support:** iw, ip addr, apt/dnf
- **Fix (sh):** `set -e` entfernt – verhinderte lautlose Abbrüche nach Banner
- **Fix (sh):** `networksetup`-Schleife auf `awk`-Einzeiler umgebaut
- **Fix (ps1):** `Get-WlanField`-Hilfsfunktion – behebt `Object[].Trim()`-Fehler

### netcheck.ps1 v1.4 (2026-07-05)
- **Fix:** `Select-String` gibt `MatchInfo`-Objekte zurück – `.Trim()` schlug fehl
- **Fix:** Signal-Extraktion via `$Matches[1]` statt direktem Cast
- **Fix:** WLAN-Abschnitt erkennt Ethernet-only und gibt sinnvollen Hinweis

### netcheck.sh / netcheck.ps1 v1.3 (2026-07-05)
- **iperf3:** Fallback-Serverliste mit 5 Servern (EU-first, USA als letzter Fallback)
- **iperf3:** `break` nach erstem Erfolg
- **iperf3:** Timeout auf 15 s reduziert
- **iperf3:** Hinweis mit Alternativ-URLs bei Totalausfall
- **Server:** Paris `iperf.par2.as49434.net` entfernt (dauerhaft offline)
- **Windows:** `Test-NetConnection` als Vorab-Erreichbarkeitsprüfung

### v1.2 (2026-07-05)
- **Fix:** DNS-Zeitmessung auf `python3` umgestellt (macOS: `date +%s%3N` nicht verfügbar)
- **Fix:** iperf3-Hang durch Background-Job mit hartem Timeout behoben

### v1.1 (2026-07-05)
- **Fix:** macOS-Zeitformat-Kompatibilität

### v1.0 (2026-07-05)
- Erstveröffentlichung: macOS (`netcheck.sh`) und Windows (`netcheck.ps1`)

---

## Lizenz

MIT – siehe [LICENSE](LICENSE)

---

## Autor

[Onslaught2508](https://github.com/Onslaught2508)
