# 🌐 netcheck

Schnelle Netzwerk- & WLAN-Diagnose für **macOS** und **Windows** – direkt aus dem Terminal, ohne manuelle Installation.

Prüft: WLAN-Qualität, Kanal-Belegung, Latenz, DNS-Auflösung, Traceroute und Bandbreite (via iperf3).

---

## 🚀 Schnellstart

### macOS / Linux
```bash
curl -fsSL https://raw.githubusercontent.com/Onslaught2508/netcheck/main/netcheck.sh | bash
```

### Windows (PowerShell als Administrator)
```powershell
irm https://raw.githubusercontent.com/Onslaught2508/netcheck/main/netcheck.ps1 | iex
```

> **Sicherheitshinweis:** Wer lieber prüft bevor er ausführt (empfohlen):
> ```bash
> # macOS: erst herunterladen, prüfen, dann ausführen
> curl -fsSL https://raw.githubusercontent.com/Onslaught2508/netcheck/main/netcheck.sh -o netcheck.sh
> cat netcheck.sh
> chmod +x netcheck.sh && ./netcheck.sh
> ```
> ```powershell
> # Windows: erst herunterladen, prüfen, dann ausführen
> irm https://raw.githubusercontent.com/Onslaught2508/netcheck/main/netcheck.ps1 -OutFile netcheck.ps1
> notepad netcheck.ps1
> powershell -ExecutionPolicy Bypass -File netcheck.ps1
> ```

---

## 📋 Was wird geprüft?

| Modul | macOS | Windows | Beschreibung |
|---|:---:|:---:|---|
| **Abhängigkeiten** | ✅ | ✅ | Homebrew, iperf3, winget – automatisch installiert |
| **System-Info** | ✅ | ✅ | OS-Version, Hostname, Nutzer |
| **Netzwerk-Interfaces** | ✅ | ✅ | Aktive IPs, Standard-Gateway |
| **WLAN-Netzwerk** | ✅ | ✅ | SSID, Band, Kanal, PHY-Mode, Signal/Rauschen |
| **Kanal-Belegung** | ✅ | ✅ | Wie viele Netze teilen denselben Kanal? |
| **Latenz** | ✅ | ✅ | Ping zu Google, Cloudflare, Quad9 |
| **DNS-Auflösung** | ✅ | ✅ | Auflösungszeit für google.com, github.com, heise.de |
| **Traceroute** | ✅ | ✅ | Pfad ins Internet, max. 15 Hops |
| **Bandbreite** | ✅ | ✅ | iperf3-Test gegen Paris & Niederlande |
| **Logfile** | ✅ | ✅ | Ergebnis automatisch gespeichert |

---

## 🔍 Beispielausgabe

```
══════════════════════════════════════
  📶 WLAN – Aktuelles Netzwerk
══════════════════════════════════════
  [OK]  PHY Mode: 802.11ax  ← WiFi 6: aktuell
  [!!]  Channel: 6 (2GHz, 20MHz)  ← 2,4 GHz: Interferenzrisiko!
  [OK]  Signal / Noise: -48 dBm / -97 dBm  ← Signal gut (SNR: 49 dB)

══════════════════════════════════════
  📡 WLAN-Umgebung (Kanal-Belegung)
══════════════════════════════════════
  [XX]  4 Netze auf Kanal 6 (2GHz)  ← überfüllt
  [!!]  2 Netze auf Kanal 11 (2GHz)
  [OK]  1 Netz  auf Kanal 36 (5GHz)

══════════════════════════════════════
  🚀 Bandbreiten-Test (iperf3)
══════════════════════════════════════
  → Paris (iperf.par2.as49434.net:9201)
  [OK]  Bandbreite: 38.2 Mbits/sec
  [OK]  Retransmits: 1  ← sauber
```

---

## ⚙️ Voraussetzungen

### macOS
| Tool | Wird automatisch installiert? |
|---|---|
| Xcode Command Line Tools | ✅ (Prompt) |
| Homebrew | ✅ |
| iperf3 | ✅ via Homebrew |

### Windows
| Tool | Wird automatisch installiert? |
|---|---|
| iperf3 | ✅ via winget |
| ping / tracert / nslookup | ✅ Boardmittel |

> PowerShell 5.1 oder neuer erforderlich (ab Windows 10 vorinstalliert).

---

## 📁 Dateien

```
netcheck/
├── README.md          – diese Datei
├── netcheck.sh        – macOS/Linux Bash-Skript
└── netcheck.ps1       – Windows PowerShell-Skript
```

---

## 🔒 Datenschutz & Sicherheit

- Es werden **keine Daten gesammelt oder übertragen** (außer den iperf3-Testverbindungen zu öffentlichen Servern)
- Logfiles liegen lokal unter `/tmp/netcheck_*.log` (macOS) bzw. `%TEMP%\netcheck_*.log` (Windows)
- Skripte können vor der Ausführung vollständig eingesehen werden (siehe Schnellstart)

---

## 📜 Lizenz

MIT – frei verwendbar, veränderbar, weiterggebbar.

---

## 👤 Autor

[Onslaught2508](https://github.com/Onslaught2508)
