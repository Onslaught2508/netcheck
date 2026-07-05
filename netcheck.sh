#!/usr/bin/env bash
# ============================================================
#  netcheck.sh – Netzwerk & WLAN Diagnose für macOS
#  v1.2 – Fixes: DNS ms-Messung, iperf3 Hang-Timeout
#  Autor: github.com/Onslaught2508/netcheck
#  Lizenz: MIT
# ============================================================

set -euo pipefail

# ── Farben ───────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Hilfsfunktionen ──────────────────────────────────────────
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}";
           echo -e "${BOLD}${CYAN}  $1${RESET}";
           echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}"; }
ok()     { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
fail()   { echo -e "  ${RED}✘${RESET}  $1"; }
info()   { echo -e "  ${CYAN}ℹ${RESET}  $1"; }

# FIX v1.1/v1.2: macOS date kennt kein %3N → python3 für ms-Messung
now_ms() {
  python3 -c "import time; print(int(time.time() * 1000))"
}

# FIX v1.2: iperf3 mit hartem Timeout via Background-Job
iperf3_with_timeout() {
  local host="$1" port="$2" duration="${3:-5}" timeout_sec="${4:-20}"
  local tmpfile
  tmpfile=$(mktemp /tmp/iperf3_XXXXXX)

  iperf3 -c "$host" -p "$port" -t "$duration" --connect-timeout 5000 \
    > "$tmpfile" 2>&1 &
  local pid=$!

  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [[ $elapsed -ge $timeout_sec ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$tmpfile"
      echo "TIMEOUT"
      return
    fi
  done

  wait "$pid" 2>/dev/null || true
  cat "$tmpfile"
  rm -f "$tmpfile"
}

# ── Abhängigkeiten prüfen & installieren ─────────────────────
check_deps() {
  header "🔍 Abhängigkeiten prüfen"

  if ! xcode-select -p &>/dev/null; then
    warn "Xcode Command Line Tools fehlen – werden installiert..."
    xcode-select --install
    echo "  Bitte Installation abwarten und Skript neu starten."
    exit 1
  else
    ok "Xcode Command Line Tools vorhanden"
  fi

  if ! command -v brew &>/dev/null; then
    warn "Homebrew nicht gefunden – wird installiert..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    ok "Homebrew vorhanden ($(brew --version | head -1))"
  fi

  if ! command -v iperf3 &>/dev/null; then
    warn "iperf3 fehlt – wird via Homebrew installiert..."
    brew install iperf3
  else
    ok "iperf3 vorhanden ($(iperf3 --version | head -1))"
  fi

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
  ifconfig | awk '
    /^[a-z]/ { iface=$1 }
    /inet / && !/127.0.0.1/ {
      printf "  %-12s %s\n", iface, $2
    }
  '
  echo ""
  GW=$(netstat -rn | awk '/default/{print $2; exit}')
  info "Standard-Gateway: ${GW:-nicht gefunden}"
}

# ── WLAN-Info ─────────────────────────────────────────────────
wlan_info() {
  header "📶 WLAN – Aktuelles Netzwerk"

  WLAN_RAW=$(system_profiler SPAirPortDataType 2>/dev/null)

  CURRENT=$(echo "$WLAN_RAW" | awk '
    /Current Network Information:/{found=1; count=0}
    found && /PHY Mode|Channel|Signal|Transmit Rate|MCS/{print; count++}
    count==5{exit}
  ')

  if [[ -z "$CURRENT" ]]; then
    fail "Kein WLAN verbunden"
    return
  fi

  echo "$CURRENT" | while IFS= read -r line; do
    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')

    if echo "$trimmed" | grep -q "Channel:"; then
      if echo "$trimmed" | grep -q "2GHz"; then
        warn "$trimmed  ← 2,4 GHz: Interferenzrisiko!"
      else
        ok "$trimmed  ← 5/6 GHz: gut"
      fi
    elif echo "$trimmed" | grep -q "PHY Mode:"; then
      if echo "$trimmed" | grep -qE "\.11ax"; then
        ok "$trimmed  ← WiFi 6: aktuell"
      elif echo "$trimmed" | grep -q "\.11ac"; then
        ok "$trimmed  ← WiFi 5: okay"
      elif echo "$trimmed" | grep -q "\.11n"; then
        warn "$trimmed  ← WiFi 4: veraltet"
      else
        info "$trimmed"
      fi
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

  header "📡 WLAN-Umgebung (Kanal-Belegung)"
  echo "$WLAN_RAW" | grep "Channel:" | grep -oE '[0-9]+ \([^)]+\)' | sort | uniq -c | sort -rn | \
  while read -r count channel; do
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
    START=$(now_ms)
    IP=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    END=$(now_ms)
    MS=$((END - START))
    if [[ -n "$IP" ]]; then
      if [[ $MS -lt 50 ]]; then
        ok "$domain → $IP  (${MS} ms)"
      elif [[ $MS -lt 150 ]]; then
        warn "$domain → $IP  (${MS} ms)  ← etwas langsam"
      else
        fail "$domain → $IP  (${MS} ms)  ← langsam"
      fi
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

    RESULT=$(iperf3_with_timeout "$HOST" "$PORT" 5 20)

    if [[ "$RESULT" == "TIMEOUT" ]]; then
      fail "Timeout – Server $NAME nicht erreichbar oder zu langsam"
      continue
    fi

    if echo "$RESULT" | grep -q "iperf Done"; then
      BW=$(echo "$RESULT" | grep "sender" | grep -oE '[0-9.]+ [MGK]bits/sec' | tail -1)
      RETR=$(echo "$RESULT" | grep "sender" | awk '{print $9}')
      ok "Bandbreite: ${BW:-unbekannt}"
      if [[ -n "$RETR" ]] && [[ "$RETR" =~ ^[0-9]+$ ]]; then
        if [[ $RETR -gt 50 ]]; then
          fail "Retransmits: $RETR  ← hohe Paketverluste!"
        elif [[ $RETR -gt 10 ]]; then
          warn "Retransmits: $RETR  ← leichte Verluste"
        else
          ok "Retransmits: $RETR  ← sauber"
        fi
      fi
    else
      ERR=$(echo "$RESULT" | grep -i "error\|refused\|failed" | head -1 | sed 's/^[[:space:]]*//')
      fail "Fehler: ${ERR:-kein Ergebnis von $NAME}"
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
exec > >(tee -a "$LOGFILE") 2>&1

echo -e "${BOLD}${CYAN}"
echo "  ███╗   ██╗███████╗████████╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗"
echo "  ████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝"
echo "  ██╔██╗ ██║█████╗     ██║   ██║     ███████║█████╗  ██║     █████╔╝ "
echo "  ██║╚██╗██║██╔══╝     ██║   ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗ "
echo "  ██║ ╚████║███████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗"
echo "  ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝"
echo -e "${RESET}"
echo -e "  ${CYAN}macOS Netzwerk-Diagnose v1.2${RESET} | $(date '+%Y-%m-%d %H:%M')"
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
