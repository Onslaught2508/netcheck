#!/usr/bin/env bash
# ============================================================
#  netcheck.sh – Netzwerk & WLAN Diagnose für macOS und Linux
#  v2.0 – Verbindungsart-Erkennung (WLAN/Ethernet/Beides)
#  Autor: github.com/Onslaught2508/netcheck
#  Lizenz: MIT
# ============================================================

set -euo pipefail

# ── Farben ───────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}";
           echo -e "${BOLD}${CYAN}  $1${RESET}";
           echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}"; }
ok()     { echo -e "  ${GREEN}✔${RESET}  $1"; }
warn()   { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
fail()   { echo -e "  ${RED}✘${RESET}  $1"; }
info()   { echo -e "  ${CYAN}ℹ${RESET}  $1"; }

# macOS: date kennt kein %3N → python3
now_ms() { python3 -c "import time; print(int(time.time() * 1000))"; }

# iperf3 mit hartem Timeout via Background-Job
iperf3_with_timeout() {
  local host="$1" port="$2" duration="${3:-5}" timeout_sec="${4:-15}"
  local tmpfile
  tmpfile=$(mktemp /tmp/iperf3_XXXXXX)
  iperf3 -c "$host" -p "$port" -t "$duration" --connect-timeout 4000 \
    > "$tmpfile" 2>&1 &
  local pid=$!
  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1; elapsed=$((elapsed + 1))
    if [[ $elapsed -ge $timeout_sec ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$tmpfile"; echo "TIMEOUT"; return
    fi
  done
  wait "$pid" 2>/dev/null || true
  cat "$tmpfile"; rm -f "$tmpfile"
}

# ── Plattform erkennen ────────────────────────────────────────
detect_platform() {
  OS="unknown"
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    *)      OS="unknown" ;;
  esac
}

# ── Verbindungsart erkennen ───────────────────────────────────
# Setzt globale Variablen: HAS_WIFI, HAS_ETHERNET, WIFI_IF, ETH_IF
detect_connection_type() {
  HAS_WIFI=false
  HAS_ETHERNET=false
  WIFI_IF=""
  ETH_IF=""

  if [[ "$OS" == "macos" ]]; then
    # WLAN-Interface: networksetup -listallhardwareports
    while IFS= read -r line; do
      if echo "$line" | grep -q "Wi-Fi\|AirPort"; then
        read -r dev_line || true
        WIFI_IF=$(echo "$dev_line" | awk '{print $2}')
      fi
    done < <(networksetup -listallhardwareports 2>/dev/null)

    # Ethernet-Interface
    while IFS= read -r line; do
      if echo "$line" | grep -qi "ethernet\|thunderbolt"; then
        read -r dev_line || true
        candidate=$(echo "$dev_line" | awk '{print $2}')
        # Nur wenn aktiv (hat IP)
        if ifconfig "$candidate" 2>/dev/null | grep -q "inet "; then
          ETH_IF="$candidate"
        fi
      fi
    done < <(networksetup -listallhardwareports 2>/dev/null)

    # WLAN aktiv? (hat IP und ist assoziiert)
    if [[ -n "$WIFI_IF" ]] && ifconfig "$WIFI_IF" 2>/dev/null | grep -q "inet "; then
      HAS_WIFI=true
    fi
    [[ -n "$ETH_IF" ]] && HAS_ETHERNET=true

  elif [[ "$OS" == "linux" ]]; then
    # WLAN: Interface beginnt mit wl (wlan0, wlp2s0 etc.)
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
      if [[ "$iface" == wl* ]]; then
        if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
          WIFI_IF="$iface"; HAS_WIFI=true; break
        fi
      fi
    done
    # Ethernet: Interface beginnt mit en oder eth (aber nicht lo)
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
      if [[ "$iface" == en* || "$iface" == eth* ]]; then
        if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
          ETH_IF="$iface"; HAS_ETHERNET=true; break
        fi
      fi
    done
  fi
}

# ── Abhängigkeiten prüfen ─────────────────────────────────────
check_deps() {
  header "🔍 Abhängigkeiten prüfen"

  if [[ "$OS" == "macos" ]]; then
    if ! xcode-select -p &>/dev/null; then
      warn "Xcode Command Line Tools fehlen – werden installiert..."
      xcode-select --install; exit 1
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

  elif [[ "$OS" == "linux" ]]; then
    ok "Linux erkannt"
    if ! command -v iperf3 &>/dev/null; then
      warn "iperf3 fehlt – Installationsversuch..."
      if command -v apt-get &>/dev/null; then
        sudo apt-get install -y iperf3 2>/dev/null && ok "iperf3 via apt installiert" \
          || warn "iperf3 Installation fehlgeschlagen – bitte manuell: sudo apt install iperf3"
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y iperf3 2>/dev/null && ok "iperf3 via dnf installiert" \
          || warn "iperf3 Installation fehlgeschlagen – bitte manuell: sudo dnf install iperf3"
      else
        warn "Kein bekannter Paketmanager – bitte iperf3 manuell installieren"
      fi
    else
      ok "iperf3 vorhanden ($(iperf3 --version | head -1))"
    fi
  fi

  if ! command -v traceroute &>/dev/null && ! command -v tracepath &>/dev/null; then
    warn "traceroute/tracepath nicht gefunden"
  else
    ok "traceroute vorhanden"
  fi

  ok "Alle Abhängigkeiten geprüft"
}

# ── System-Info ───────────────────────────────────────────────
system_info() {
  header "💻 System-Info"
  info "Hostname:    $(hostname)"
  info "Plattform:   $OS"
  if [[ "$OS" == "macos" ]]; then
    info "macOS:       $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  elif [[ "$OS" == "linux" ]]; then
    if [[ -f /etc/os-release ]]; then
      info "OS:          $(. /etc/os-release && echo "$PRETTY_NAME")"
    fi
    info "Kernel:      $(uname -r)"
  fi
  info "Datum/Zeit:  $(date '+%Y-%m-%d %H:%M:%S')"
  info "Nutzer:      $(whoami)"
}

# ── Netzwerk-Interfaces ───────────────────────────────────────
network_interfaces() {
  header "🔌 Netzwerk-Interfaces"

  # Verbindungsart-Zusammenfassung
  if $HAS_WIFI && $HAS_ETHERNET; then
    warn "WLAN und Ethernet gleichzeitig aktiv – Routing-Priorität beachten"
  elif $HAS_WIFI; then
    info "Verbindungsart: WLAN (${WIFI_IF})"
  elif $HAS_ETHERNET; then
    info "Verbindungsart: Ethernet/Kabel (${ETH_IF})"
  else
    fail "Keine aktive Netzwerkverbindung erkannt"
  fi

  echo ""

  if [[ "$OS" == "macos" ]]; then
    ifconfig | awk '
      /^[a-z]/ { iface=$1 }
      /inet / && !/127.0.0.1/ { printf "  %-14s %s\n", iface, $2 }
    '
  elif [[ "$OS" == "linux" ]]; then
    ip addr | awk '
      /^[0-9]+:/ { iface=$2; sub(/:$/,"",iface) }
      /inet / && !/127\.0\.0\.1/ { printf "  %-14s %s\n", iface, $2 }
    '
  fi

  echo ""
  if [[ "$OS" == "macos" ]]; then
    GW=$(netstat -rn | awk '/default/{print $2; exit}')
  else
    GW=$(ip route | awk '/default/{print $3; exit}')
  fi
  info "Standard-Gateway: ${GW:-nicht gefunden}"
}

# ── WLAN-Info ─────────────────────────────────────────────────
wlan_info() {
  if ! $HAS_WIFI; then
    header "📶 WLAN"
    if $HAS_ETHERNET; then
      info "Kein WLAN aktiv – Verbindung läuft über Ethernet (${ETH_IF})"
      ethernet_info
    else
      fail "Keine Netzwerkverbindung aktiv"
    fi
    return
  fi

  header "📶 WLAN – Aktuelles Netzwerk (${WIFI_IF})"

  if [[ "$OS" == "macos" ]]; then
    WLAN_RAW=$(system_profiler SPAirPortDataType 2>/dev/null)
    CURRENT=$(echo "$WLAN_RAW" | awk '
      /Current Network Information:/{found=1; count=0}
      found && /PHY Mode|Channel|Signal|Transmit Rate|MCS/{print; count++}
      count==5{exit}
    ')

    if [[ -z "$CURRENT" ]]; then
      fail "WLAN-Interface vorhanden, aber keine Verbindungsdaten"
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

  elif [[ "$OS" == "linux" ]]; then
    # iw oder iwconfig
    if command -v iw &>/dev/null; then
      IW_OUT=$(iw dev "$WIFI_IF" link 2>/dev/null)
      SSID=$(echo "$IW_OUT"    | awk '/SSID:/{print $2}')
      FREQ=$(echo "$IW_OUT"    | awk '/freq:/{print $2}')
      SIGNAL=$(echo "$IW_OUT"  | awk '/signal:/{print $2, $3}')
      BITRATE=$(echo "$IW_OUT" | awk '/tx bitrate:/{print $3, $4}')

      info "SSID:      ${SSID:-unbekannt}"
      info "Bitrate:   ${BITRATE:-unbekannt}"

      if [[ -n "$FREQ" ]]; then
        FREQ_INT=${FREQ%.*}
        if [[ $FREQ_INT -ge 5000 ]]; then
          ok "Frequenz: ${FREQ} MHz  ← 5 GHz: gut"
        else
          warn "Frequenz: ${FREQ} MHz  ← 2,4 GHz: Interferenzrisiko!"
        fi
      fi

      if [[ -n "$SIGNAL" ]]; then
        RSSI=$(echo "$SIGNAL" | awk '{print $1}')
        if [[ $RSSI -ge -65 ]]; then
          ok "Signal: ${SIGNAL}  ← gut"
        elif [[ $RSSI -ge -75 ]]; then
          warn "Signal: ${SIGNAL}  ← mittel"
        else
          fail "Signal: ${SIGNAL}  ← schwach"
        fi
      fi
    else
      warn "iw nicht gefunden – WLAN-Details nicht verfügbar"
      info "Installation: sudo apt install iw"
    fi
  fi
}

# ── Ethernet-Info (nur wenn kein WLAN) ───────────────────────
ethernet_info() {
  header "🔌 Ethernet-Details (${ETH_IF})"

  if [[ "$OS" == "macos" ]]; then
    SPEED=$(networksetup -getMedia "$ETH_IF" 2>/dev/null | grep "Active" | awk '{print $3, $4}')
    info "Adapter:   ${ETH_IF}"
    info "Geschw.:   ${SPEED:-nicht ermittelbar}"
  elif [[ "$OS" == "linux" ]]; then
    if command -v ethtool &>/dev/null; then
      SPEED=$(ethtool "$ETH_IF" 2>/dev/null | awk '/Speed:/{print $2}')
      DUPLEX=$(ethtool "$ETH_IF" 2>/dev/null | awk '/Duplex:/{print $2}')
      LINK=$(ethtool "$ETH_IF" 2>/dev/null | awk '/Link detected:/{print $3}')
      info "Adapter:   ${ETH_IF}"
      if [[ "$LINK" == "yes" ]]; then
        ok "Link:      aktiv"
      else
        fail "Link:      nicht aktiv"
      fi
      info "Geschw.:   ${SPEED:-unbekannt}"
      info "Duplex:    ${DUPLEX:-unbekannt}"
    else
      info "Adapter:   ${ETH_IF}"
      warn "ethtool nicht gefunden – Details nicht verfügbar"
      info "Installation: sudo apt install ethtool"
    fi
  fi
}

# ── Latenz-Test ───────────────────────────────────────────────
latency_check() {
  header "⏱  Latenz-Test"
  TARGETS=("8.8.8.8:Google DNS" "1.1.1.1:Cloudflare DNS" "9.9.9.9:Quad9 DNS")
  for entry in "${TARGETS[@]}"; do
    HOST="${entry%%:*}"; NAME="${entry##*:}"
    if [[ "$OS" == "macos" ]]; then
      RESULT=$(ping -c 4 -q "$HOST" 2>/dev/null | tail -1)
      AVG=$(echo "$RESULT" | grep -oE '[0-9]+\.[0-9]+' | sed -n '2p')
    else
      RESULT=$(ping -c 4 -q "$HOST" 2>/dev/null | tail -1)
      AVG=$(echo "$RESULT" | grep -oE '[0-9]+\.[0-9]+' | sed -n '2p')
    fi
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

# ── DNS-Check ─────────────────────────────────────────────────
dns_check() {
  header "🔎 DNS-Auflösung"
  DOMAINS=("google.com" "github.com" "heise.de")
  for domain in "${DOMAINS[@]}"; do
    START=$(now_ms)
    IP=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
    END=$(now_ms); MS=$((END - START))
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

# ── Traceroute ────────────────────────────────────────────────
traceroute_check() {
  header "🗺  Traceroute (max. 15 Hops)"
  if command -v traceroute &>/dev/null; then
    traceroute -m 15 -w 2 8.8.8.8 2>/dev/null | head -20
  elif command -v tracepath &>/dev/null; then
    tracepath -m 15 8.8.8.8 2>/dev/null | head -20
  else
    warn "Kein traceroute/tracepath verfügbar"
  fi
}

# ── Bandbreite ────────────────────────────────────────────────
bandwidth_check() {
  header "🚀 Bandbreiten-Test (iperf3)"
  if ! command -v iperf3 &>/dev/null; then
    warn "iperf3 nicht verfügbar – Test übersprungen"
    info "Alternativ: https://fast.com oder https://speedtest.net"
    return
  fi

  warn "Hinweis: Testet TCP-Durchsatz zu öffentlichen iperf3-Servern"
  warn "Strategie: Fallback-Liste – erster erreichbarer Server gewinnt"

  SERVERS=(
    "speedtest.serverius.net:5002:Niederlande (Serverius)"
    "speedtest.ams1.novogara.net:5201:Amsterdam (Novogara)"
    "iperf.online.net:5209:Paris (Online.net)"
    "bouygues.testdebit.info:5209:Paris (Bouygues)"
    "iperf.he.net:5201:Fremont/USA (Hurricane Electric)"
  )

  local success=0
  for entry in "${SERVERS[@]}"; do
    HOST="${entry%%:*}"; REST="${entry#*:}"
    PORT="${REST%%:*}"; NAME="${REST##*:}"
    echo -e "\n  ${BOLD}→ $NAME ($HOST:$PORT)${RESET}"
    RESULT=$(iperf3_with_timeout "$HOST" "$PORT" 5 15)
    if [[ "$RESULT" == "TIMEOUT" ]]; then
      fail "Timeout – übersprungen"; continue
    fi
    if echo "$RESULT" | grep -q "iperf Done"; then
      BW=$(echo "$RESULT"   | grep "sender" | grep -oE '[0-9.]+ [MGK]bits/sec' | tail -1)
      RETR=$(echo "$RESULT" | grep "sender" | awk '{print $9}')
      ok "Bandbreite: ${BW:-unbekannt}"
      if [[ -n "$RETR" ]] && [[ "$RETR" =~ ^[0-9]+$ ]]; then
        if [[ $RETR -gt 50 ]]; then fail "Retransmits: $RETR  ← hohe Paketverluste!"
        elif [[ $RETR -gt 10 ]]; then warn "Retransmits: $RETR  ← leichte Verluste"
        else ok "Retransmits: $RETR  ← sauber"; fi
      fi
      success=1; break
    else
      ERR=$(echo "$RESULT" | grep -i "error\|refused\|failed" | head -1 | sed 's/^[[:space:]]*//')
      fail "Fehler: ${ERR:-kein Ergebnis} – übersprungen"
    fi
  done

  if [[ $success -eq 0 ]]; then
    echo ""
    warn "Alle iperf3-Server nicht erreichbar."
    info "Alternativ: https://fast.com oder https://speedtest.net"
  fi
}

# ── Zusammenfassung ───────────────────────────────────────────
summary() {
  header "📋 Zusammenfassung"
  echo -e "  Diagnose abgeschlossen: $(date '+%H:%M:%S')"
  echo -e "  Plattform: $OS | Verbindung: $(
    if $HAS_WIFI && $HAS_ETHERNET; then echo "WLAN + Ethernet"
    elif $HAS_WIFI; then echo "WLAN (${WIFI_IF})"
    elif $HAS_ETHERNET; then echo "Ethernet (${ETH_IF})"
    else echo "keine"; fi
  )"
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
echo -e "  ${CYAN}macOS/Linux Netzwerk-Diagnose v2.0${RESET} | $(date '+%Y-%m-%d %H:%M')"
echo ""

detect_platform
detect_connection_type
check_deps
system_info
network_interfaces
wlan_info
latency_check
dns_check
traceroute_check
bandwidth_check
summary
