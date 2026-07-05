#!/usr/bin/env bash
# ============================================================
#  netcheck.sh – Netzwerk & WLAN Diagnose für macOS
#  Autor: github.com/Onslaught2508/netcheck
#  Lizenz: MIT
# ============================================================

set -euo pipefail

# ── Farben ───────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Hilfsfunktionen ──────────────────────────────────────────
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}"; \
             echo -e "${BOLD}${CYAN}  $1${RESET}"; \
             echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}"; }
ok()      { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
fail()    { echo -e "  ${RED}✘${RESET}  $1"; }
info()    { echo -e "  ${CYAN}ℹ${RESET}  $1"; }

# ── Abhängigkeiten prüfen & installieren ─────────────────────
check_deps() {
  header "🔍 Abhängigkeiten prüfen"

  # Xcode Command Line Tools (für ping, traceroute etc.)
  if ! xcode-select -p &>/dev/null; then
    warn "Xcode Command Line Tools fehlen – werden installiert..."
    xcode-select --install
    echo "  Bitte Installation abwarten und Skript neu starten."
    exit 1
  else
    ok "Xcode Command Line Tools vorhanden"
  fi

  # Homebrew
  if ! command -v brew &>/dev/null; then
    warn "Homebrew nicht gefunden – wird installiert..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    ok "Homebrew vorhanden ($(brew --version | head -1))"
  fi

  # iperf3
  if ! command -v iperf3 &>/dev/null; then
    warn "iperf3 fehlt – wird via Homebrew installiert..."
    brew install iperf3
  else
    ok "iperf3 vorhanden ($(iperf3 --version | head -1))"
  fi

  # traceroute (meist vorhanden, sicherheitshalber)
  if ! command -v traceroute &>/dev/null; then
    warn "traceroute fehlt – wird installiert..."
    brew install inetutils
  else
    ok "traceroute vorhanden"
  fi

  ok "Alle Abhängigkeiten erfüllt"
}

# ── System-Info ───────────────────────────────────────────────
system_info() {
  header "💻 System-Info"
  info "Hostname:    $(hostname)"
  info "macOS:       $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  info "Datum/Zeit:  $(date '+%Y-%m-%d %H:%M:%S')"
  info "Nutzer:      $(whoami)"
}

# ── Netzwerk-Interfaces ───────────────────────────────────────
network_interfaces() {
  header "🔌 Netzwerk-Interfaces"
  # Aktive Interfaces mit IP
  ifconfig | awk '
    /^[a-z]/ { iface=$1 }
    /inet / && !/127.0.0.1/ {
      printf "  %-12s %s\n", iface, $2
    }
  '
  echo ""
  # Standard-Gateway
  GW=$(netstat -rn | awk '/default/{print $2; exit}')
  info "Standard-Gateway: ${GW:-nicht gefunden}"
}

# ── WLAN-Info ─────────────────────────────────────────────────
wlan_info() {
  header "📶 WLAN – Aktuelles Netzwerk"

  WLAN_RAW=$(system_profiler SPAirPortDataType 2>/dev/null)

  # Verbundenes Netz
  CURRENT=$(echo "$WLAN_RAW" | awk '/Current Network Information:/{found=1} found && /PHY Mode|Channel|Signal|Transmit Rate|MCS/{print; count++} count==5{exit}')

  if [[ -z "$CURRENT" ]]; then
    fail "Kein WLAN verbunden"
    return
  fi

  echo "$CURRENT" | while IFS= read -r line; do
    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')

    # Kanal-Bewertung
    if echo "$trimmed" | grep -q "Channel:"; then
      if echo "$trimmed" | grep -q "2GHz"; then
        warn "$trimmed  ← 2,4 GHz: Interferenzrisiko!"
      else
        ok "$trimmed  ← 5/6 GHz: gut"
      fi

    # PHY-Mode-Bewertung
    elif echo "$trimmed" | grep -q "PHY Mode:"; then
      if echo "$trimmed" | grep -qE "ax|WiFi 6"; then
        ok "$trimmed  ← WiFi 6: aktuell"
      elif echo "$trimmed" | grep -q "ac"; then
        ok "$trimmed  ← WiFi 5: okay"
      elif echo "$trimmed" | grep -q "\.11n"; then
        warn "$trimmed  ← WiFi 4: veraltet"
      else
        info "$trimmed"
      fi

    # Signal-Bewertung
    elif echo "$trimmed" | grep -q "Signal / Noise:"; then
      RSSI=$(echo "$trimmed" | grep -oE '\-[0-9]+' | head -1)
      NOISE=$(echo "$trimmed" | grep -oE '\-[0-9]+' | tail -1)
      SNR=$((RSSI - NOISE))
      if [[ $RSSI -ge -65 ]]; then
        ok "$trimmed  ← Signal gut (SNR: ${SNR} dB)"
      elif [[ $RSSI -ge -75 ]]; then
        warn "$trimmed  ← Signal mittel (SNR: ${SNR} dB)"
      else
        fail "$trimmed  ← Signal schwach (SNR: ${SNR} dB)"
      fi
    else
      info "$trimmed"
    fi
  done

  # Umgebungs-Netze zählen pro Kanal
  header "📡 WLAN-Umgebung (Kanal-Belegung)"
  echo "$WLAN_RAW" | grep "Channel:" | grep -oE '[0-9]+ \([^)]+\)' | sort | uniq -c | sort -rn | while read count channel; do
    if [[ $count -ge 4 ]]; then
      fail "  $count Netze auf Kanal $channel  ← überfüllt"
    elif [[ $count -ge 2 ]]; then
      warn "  $count Netze auf Kanal $channel"
    else
      ok "  $count Netz  auf Kanal $channel"
    fi
  done
}

# ── Ping / Latenz ─────────────────────────────────────────────
latency_check() {
  header "⏱  Latenz-Test"

  TARGETS=("8.8.8.8:Google DNS" "1.1.1.1:Cloudflare DNS" "9.9.9.9:Quad9 DNS")

  for entry in "${TARGETS[@]}"; do
    HOST="${entry%%:*}"
    NAME="${entry##*:}"
    RESULT=$(ping -c 4 -q "$HOST" 2>/dev/null | tail -1)
    AVG=$(echo "$RESULT" | grep -oE '[0-9]+\.[0-9]+' | sed -n '2p')

    if [[ -z "$AVG" ]]; then
      fail "$NAME ($HOST): nicht erreichbar"
    elif (( $(echo "$AVG < 30" | bc -l) )); then
      ok "$NAME ($HOST): ${AVG} ms  ← gut"
    elif (( $(echo "$AVG < 80" | bc -l) )); then
      warn "$NAME ($HOST): ${AVG} ms  ← akzeptabel"
    else
      fail "$NAME ($HOST): ${AVG} ms  ← hoch"
    fi
  done
}

# ── Traceroute ────────────────────────────────────────────────
traceroute_check() {
  header "🗺  Traceroute (max. 15 Hops)"
  traceroute -m 15 -w 2 8.8.8.8 2>/dev/null | head -20 || \
    warn "traceroute nicht verfügbar"
}

# ── DNS-Check ─────────────────────────────────────────────────
dns_check() {
  header "🔎 DNS-Auflösung"
  DOMAINS=("google.com" "github.com" "heise.de")
  for domain in "${DOMAINS[@]}"; do
    START=$(date +%s%3N)
    IP=$(dig +short "$domain" 2>/dev/null | head -1)
    END=$(date +%s%3N)
    MS=$((END - START))
    if [[ -n "$IP" ]]; then
      ok "$domain → $IP  (${MS} ms)"
    else
      fail "$domain → nicht auflösbar"
    fi
  done
}

# ── Bandbreite (iperf3) ───────────────────────────────────────
bandwidth_check() {
  header "🚀 Bandbreiten-Test (iperf3)"
  warn "Hinweis: Testet TCP-Durchsatz zu öffentlichen iperf3-Servern"

  SERVERS=(
    "iperf.par2.as49434.net:9201:Paris"
    "speedtest.serverius.net:5002:Niederlande"
  )

  for entry in "${SERVERS[@]}"; do
    HOST="${entry%%:*}"
    REST="${entry#*:}"
    PORT="${REST%%:*}"
    NAME="${REST##*:}"

    echo -e "\n  ${BOLD}→ $NAME ($HOST:$PORT)${RESET}"

    RESULT=$(iperf3 -c "$HOST" -p "$PORT" -t 5 --connect-timeout 3000 2>&1)

    if echo "$RESULT" | grep -q "iperf Done"; then
      BW=$(echo "$RESULT" | grep "sender" | grep -oE '[0-9.]+ [MGK]bits/sec' | tail -1)
      RETR=$(echo "$RESULT" | grep "sender" | grep -oE '[0-9]+ +sender' | awk '{print $1}')
      ok "Bandbreite: ${BW:-unbekannt}"
      if [[ -n "$RETR" && "$RETR" -gt 50 ]]; then
        fail "Retransmits: $RETR  ← hohe Paketverluste!"
      elif [[ -n "$RETR" && "$RETR" -gt 10 ]]; then
        warn "Retransmits: $RETR  ← leichte Verluste"
      else
        ok "Retransmits: ${RETR:-0}  ← sauber"
      fi
    else
      fail "Server nicht erreichbar oder Timeout"
    fi
  done
}

# ── Zusammenfassung ───────────────────────────────────────────
summary() {
  header "📋 Zusammenfassung"
  echo -e "  Diagnose abgeschlossen: $(date '+%H:%M:%S')"
  echo -e "  Logfile: ${LOGFILE}"
  echo ""
  echo -e "  ${BOLD}Legende:${RESET}"
  echo -e "  ${GREEN}✔${RESET}  Alles gut"
  echo -e "  ${YELLOW}⚠${RESET}  Auffälligkeit – prüfen"
  echo -e "  ${RED}✘${RESET}  Problem erkannt"
  echo ""
}

# ── Hauptprogramm ─────────────────────────────────────────────
LOGFILE="/tmp/netcheck_$(date +%Y%m%d_%H%M%S).log"

# Alles in Logfile UND Terminal ausgeben
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "${BOLD}${CYAN}"
echo "  ███╗   ██╗███████╗████████╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗"
echo "  ████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝"
echo "  ██╔██╗ ██║█████╗     ██║   ██║     ███████║█████╗  ██║     █████╔╝ "
echo "  ██║╚██╗██║██╔══╝     ██║   ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗ "
echo "  ██║ ╚████║███████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗"
echo "  ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝"
echo -e "${RESET}"
echo -e "  ${CYAN}macOS Netzwerk-Diagnose${RESET} | $(date '+%Y-%m-%d %H:%M')"
echo ""

check_deps
system_info
network_interfaces
wlan_info
latency_check
dns_check
traceroute_check
bandwidth_check
summary
