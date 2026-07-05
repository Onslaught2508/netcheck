#!/usr/bin/env bash
# ============================================================
#  netcheck.sh – Netzwerk & WLAN Diagnose für macOS und Linux
#  v2.2 – Logfile auf Desktop/Schreibtisch
#  Autor: github.com/Onslaught2508/netcheck
#  Lizenz: MIT
# ============================================================

set -uo pipefail

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

now_ms() { python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || echo "0"; }

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
  esac
}

# ── Verbindungsart erkennen ───────────────────────────────────
detect_connection_type() {
  HAS_WIFI=false
  HAS_ETHERNET=false
  IS_HOTSPOT=false
  WIFI_IF=""
  ETH_IF=""

  if [[ "$OS" == "macos" ]]; then
    local all_ifs
    all_ifs=$(ifconfig 2>/dev/null | awk '/^[a-z]/{iface=$1} /inet [0-9]/{print iface, $2}' \
              | grep -v '127\.0\.0\.1' | grep -v '169\.254\.' || true)

    local wifi_candidate=""
    wifi_candidate=$(networksetup -listallhardwareports 2>/dev/null \
      | awk '/Wi-Fi|AirPort/{found=1} found && /Device:/{print $2; exit}' || true)

    if [[ -n "$wifi_candidate" ]]; then
      if echo "$all_ifs" | grep -q "^${wifi_candidate}:"; then
        HAS_WIFI=true
        WIFI_IF="$wifi_candidate"
        local wifi_ip
        wifi_ip=$(echo "$all_ifs" | awk "/^${wifi_candidate}:/{print \$2}")
        if echo "$wifi_ip" | grep -qE '^172\.20\.10\.'; then
          IS_HOTSPOT=true
        fi
      fi
    fi

    local eth_candidate=""
    eth_candidate=$(networksetup -listallhardwareports 2>/dev/null \
      | awk '/Ethernet|Thunderbolt/{found=1} found && /Device:/{print $2; found=0}' \
      | head -1 || true)

    if [[ -n "$eth_candidate" ]]; then
      if echo "$all_ifs" | grep -q "^${eth_candidate}:"; then
        HAS_ETHERNET=true
        ETH_IF="$eth_candidate"
      fi
    fi

  elif [[ "$OS" == "linux" ]]; then
    for iface in $(ls /sys/class/net/ 2>/dev/null || true); do
      if [[ "$iface" == wl* ]]; then
        if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
          WIFI_IF="$iface"; HAS_WIFI=true
        fi
      elif [[ "$iface" == en* || "$iface" == eth* ]]; then
        if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
          ETH_IF="$iface"; HAS_ETHERNET=true
        fi
      fi
    done
  fi
}

# ── Abhängigkeiten prüfen ─────────────────────────────────────
check_deps() {
  header "🔍 Abhängigkeiten prüfen"

  if [[ "$OS" == "macos" ]]; then
    if xcode-select -p &>/dev/null; then
      ok "Xcode Command Line Tools vorhanden"
    else
      warn "Xcode Command Line Tools fehlen – werden installiert..."
      xcode-select --install 2>/dev/null || true
    fi
    if command -v brew &>/dev/null; then
      ok "Homebrew vorhanden ($(brew --version 2>/dev/null | head -1))"
    else
      warn "Homebrew nicht gefunden – wird installiert..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
    fi
    if command -v iperf3 &>/dev/null; then
      ok "iperf3 vorhanden ($(iperf3 --version 2>/dev/null | head -1))"
    else
      warn "iperf3 fehlt – wird via Homebrew installiert..."
      brew install iperf3 2>/dev/null || warn "iperf3 Installation fehlgeschlagen"
    fi

  elif [[ "$OS" == "linux" ]]; then
    ok "Linux erkannt"
    if ! command -v iperf3 &>/dev/null; then
      warn "iperf3 fehlt – Installationsversuch..."
      if command -v apt-get &>/dev/null; then
        sudo apt-get install -y iperf3 2>/dev/null \
          && ok "iperf3 via apt installiert" \
          || warn "iperf3 Installation fehlgeschlagen – sudo apt install iperf3"
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y iperf3 2>/dev/null \
          && ok "iperf3 via dnf installiert" \
          || warn "iperf3 Installation fehlgeschlagen – sudo dnf install iperf3"
      else
        warn "Kein bekannter Paketmanager – bitte iperf3 manuell installieren"
      fi
    else
      ok "iperf3 vorhanden ($(iperf3 --version 2>/dev/null | head -1))"
    fi
  fi

  if command -v traceroute &>/dev/null || command -v tracepath &>/dev/null; then
    ok "traceroute vorhanden"
  else
    warn "traceroute/tracepath nicht gefunden"
  fi
  ok "Alle Abhängigkeiten geprüft"
}

# ── System-Info ───────────────────────────────────────────────
system_info() {
  header "💻 System-Info"
  info "Hostname:    $(hostname)"
  info "Plattform:   $OS"
  if [[ "$OS" == "macos" ]]; then
    info "macOS:       $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
  elif [[ "$OS" == "linux" ]]; then
    [[ -f /etc/os-release ]] && info "OS:          $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unbekannt}")"
    info "Kernel:      $(uname -r)"
  fi
  info "Datum/Zeit:  $(date '+%Y-%m-%d %H:%M:%S')"
  info "Nutzer:      $(whoami)"
  info "Logfile:     ${LOGFILE}"
}

# ── Netzwerk-Interfaces ───────────────────────────────────────
network_interfaces() {
  header "🔌 Netzwerk-Interfaces"

  if $HAS_WIFI && $HAS_ETHERNET; then
    warn "WLAN und Ethernet gleichzeitig aktiv – Routing-Priorität beachten"
  elif $HAS_WIFI && $IS_HOTSPOT; then
    warn "Verbindungsart: Mobiler Hotspot (${WIFI_IF})  ← eingeschränkte Bandbreite"
  elif $HAS_WIFI; then
    info "Verbindungsart: WLAN (${WIFI_IF})"
  elif $HAS_ETHERNET; then
    info "Verbindungsart: Ethernet/Kabel (${ETH_IF})"
  else
    fail "Keine aktive Netzwerkverbindung erkannt"
  fi

  echo ""
  if [[ "$OS" == "macos" ]]; then
    ifconfig 2>/dev/null | awk '
      /^[a-z]/ { iface=$1 }
      /inet / && !/127.0.0.1/ && !/169\.254\./ { printf "  %-14s %s\n", iface, $2 }
    ' || true
  elif [[ "$OS" == "linux" ]]; then
    ip addr 2>/dev/null | awk '
      /^[0-9]+:/ { iface=$2; sub(/:$/,"",iface) }
      /inet / && !/127\.0\.0\.1/ { printf "  %-14s %s\n", iface, $2 }
    ' || true
  fi

  echo ""
  local gw=""
  if [[ "$OS" == "macos" ]]; then
    gw=$(netstat -rn 2>/dev/null | awk '/default/{print $2; exit}' || true)
  else
    gw=$(ip route 2>/dev/null | awk '/default/{print $3; exit}' || true)
  fi
  info "Standard-Gateway: ${gw:-nicht gefunden}"
}

# ── WLAN-Info ─────────────────────────────────────────────────
wlan_info() {
  if ! $HAS_WIFI; then
    header "📶 WLAN"
    if $HAS_ETHERNET; then
      info "Kein WLAN aktiv – Verbindung läuft über Ethernet (${ETH_IF})"
      ethernet_info
    else
      fail "Keine aktive Netzwerkverbindung"
    fi
    return
  fi

  if $IS_HOTSPOT; then
    header "📶 WLAN – Mobiler Hotspot (${WIFI_IF})"
    warn "Verbindung über mobilen Hotspot erkannt (172.20.10.x)"
    info "WLAN-Kanalanalyse nicht aussagekräftig – Frequenz vom Mobilgerät bestimmt"
    info "Bandbreite durch Mobilfunknetz begrenzt"
  else
    header "📶 WLAN – Aktuelles Netzwerk (${WIFI_IF})"
  fi

  if [[ "$OS" == "macos" ]]; then
    local wlan_raw=""
    wlan_raw=$(system_profiler SPAirPortDataType 2>/dev/null || true)
    local current=""
    current=$(echo "$wlan_raw" | awk '
      /Current Network Information:/{found=1; count=0}
      found && /PHY Mode|Channel|Signal|Transmit Rate|MCS/{print; count++}
      count==5{exit}
    ' || true)

    if [[ -z "$current" ]]; then
      warn "WLAN-Interface vorhanden, aber keine Verbindungsdaten ermittelbar"
      return
    fi

    while IFS= read -r line; do
      local trimmed
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
        local rssi noise snr
        rssi=$(echo "$trimmed" | grep -oE '\-[0-9]+' | head -1)
        noise=$(echo "$trimmed" | grep -oE '\-[0-9]+' | tail -1)
        snr=$((rssi - noise))
        if [[ $rssi -ge -65 ]]; then
          ok "$trimmed  ← Signal gut (SNR: ${snr} dB)"
        elif [[ $rssi -ge -75 ]]; then
          warn "$trimmed  ← Signal mittel (SNR: ${snr} dB)"
        else
          fail "$trimmed  ← Signal schwach (SNR: ${snr} dB)"
        fi
      else
        info "$trimmed"
      fi
    done <<< "$current"

    if ! $IS_HOTSPOT; then
      header "📡 WLAN-Umgebung (Kanal-Belegung)"
      echo "$wlan_raw" | grep "Channel:" | grep -oE '[0-9]+ \([^)]+\)' \
        | sort | uniq -c | sort -rn \
        | while read -r count channel; do
            if [[ $count -ge 4 ]]; then
              fail "  $count Netze auf Kanal $channel  ← überfüllt"
            elif [[ $count -ge 2 ]]; then
              warn "  $count Netze auf Kanal $channel"
            else
              ok "  $count Netz  auf Kanal $channel"
            fi
          done || true
    fi

  elif [[ "$OS" == "linux" ]]; then
    if command -v iw &>/dev/null; then
      local iw_out=""
      iw_out=$(iw dev "$WIFI_IF" link 2>/dev/null || true)
      local ssid freq signal bitrate
      ssid=$(echo "$iw_out"    | awk '/SSID:/{print $2}')
      freq=$(echo "$iw_out"    | awk '/freq:/{print $2}')
      signal=$(echo "$iw_out"  | awk '/signal:/{print $2, $3}')
      bitrate=$(echo "$iw_out" | awk '/tx bitrate:/{print $3, $4}')
      info "SSID:      ${ssid:-unbekannt}"
      info "Bitrate:   ${bitrate:-unbekannt}"
      if [[ -n "$freq" ]]; then
        local freq_int=${freq%.*}
        if [[ $freq_int -ge 5000 ]]; then
          ok "Frequenz: ${freq} MHz  ← 5 GHz: gut"
        else
          warn "Frequenz: ${freq} MHz  ← 2,4 GHz: Interferenzrisiko!"
        fi
      fi
      if [[ -n "$signal" ]]; then
        local rssi
        rssi=$(echo "$signal" | awk '{print $1}')
        if [[ $rssi -ge -65 ]]; then
          ok "Signal: ${signal}  ← gut"
        elif [[ $rssi -ge -75 ]]; then
          warn "Signal: ${signal}  ← mittel"
        else
          fail "Signal: ${signal}  ← schwach"
        fi
      fi
    else
      warn "iw nicht gefunden (sudo apt install iw)"
    fi
  fi
}

# ── Ethernet-Info ─────────────────────────────────────────────
ethernet_info() {
  header "🔌 Ethernet-Details (${ETH_IF})"
  if [[ "$OS" == "macos" ]]; then
    local speed=""
    speed=$(networksetup -getMedia "$ETH_IF" 2>/dev/null | awk '/Active/{print $3, $4}' || true)
    info "Adapter:     ${ETH_IF}"
    info "Geschw.:     ${speed:-nicht ermittelbar}"
  elif [[ "$OS" == "linux" ]]; then
    info "Adapter:     ${ETH_IF}"
    if command -v ethtool &>/dev/null; then
      local speed duplex link
      speed=$(ethtool "$ETH_IF" 2>/dev/null | awk '/Speed:/{print $2}' || true)
      duplex=$(ethtool "$ETH_IF" 2>/dev/null | awk '/Duplex:/{print $2}' || true)
      link=$(ethtool "$ETH_IF" 2>/dev/null | awk '/Link detected:/{print $3}' || true)
      [[ "$link" == "yes" ]] && ok "Link: aktiv" || fail "Link: nicht aktiv"
      info "Geschw.:     ${speed:-unbekannt}"
      info "Duplex:      ${duplex:-unbekannt}"
    else
      warn "ethtool nicht gefunden (sudo apt install ethtool)"
    fi
  fi
}

# ── Latenz-Test ───────────────────────────────────────────────
latency_check() {
  header "⏱  Latenz-Test"
  $IS_HOTSPOT && warn "Hotspot aktiv – Latenz durch Mobilfunknetz beeinflusst"
  local targets=("8.8.8.8:Google DNS" "1.1.1.1:Cloudflare DNS" "9.9.9.9:Quad9 DNS")
  for entry in "${targets[@]}"; do
    local host="${entry%%:*}" name="${entry##*:}"
    local result avg
    result=$(ping -c 4 -q "$host" 2>/dev/null | tail -1 || true)
    avg=$(echo "$result" | grep -oE '[0-9]+\.[0-9]+' | sed -n '2p' || true)
    if [[ -z "$avg" ]]; then
      fail "$name ($host): nicht erreichbar"
    elif (( $(echo "$avg < 30" | bc -l 2>/dev/null || echo 0) )); then
      ok "$name ($host): ${avg} ms  ← gut"
    elif (( $(echo "$avg < 80" | bc -l 2>/dev/null || echo 0) )); then
      warn "$name ($host): ${avg} ms  ← akzeptabel"
    else
      fail "$name ($host): ${avg} ms  ← hoch"
    fi
  done
}

# ── DNS-Check ─────────────────────────────────────────────────
dns_check() {
  header "🔎 DNS-Auflösung"
  local domains=("google.com" "github.com" "heise.de")
  for domain in "${domains[@]}"; do
    local start end ms ip
    start=$(now_ms)
    ip=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
    end=$(now_ms); ms=$((end - start))
    if [[ -n "$ip" ]]; then
      if   [[ $ms -lt 50  ]]; then ok   "$domain → $ip  (${ms} ms)"
      elif [[ $ms -lt 150 ]]; then warn "$domain → $ip  (${ms} ms)  ← etwas langsam"
      else                         fail "$domain → $ip  (${ms} ms)  ← langsam"
      fi
    else
      fail "$domain → nicht auflösbar"
    fi
  done
}

# ── Traceroute ────────────────────────────────────────────────
traceroute_check() {
  header "🗺  Traceroute (max. 15 Hops)"
  $IS_HOTSPOT && info "Hinweis: Hotspot-Gateways blockieren oft ICMP → viele * * * normal"
  if command -v traceroute &>/dev/null; then
    traceroute -m 15 -w 2 8.8.8.8 2>/dev/null | head -20 || true
  elif command -v tracepath &>/dev/null; then
    tracepath -m 15 8.8.8.8 2>/dev/null | head -20 || true
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
  $IS_HOTSPOT && warn "Hotspot aktiv – Bandbreite durch Mobilfunk begrenzt"
  warn "Hinweis: Testet TCP-Durchsatz zu öffentlichen iperf3-Servern"
  warn "Strategie: Fallback-Liste – erster erreichbarer Server gewinnt"

  local servers=(
    "speedtest.serverius.net:5002:Niederlande (Serverius)"
    "speedtest.ams1.novogara.net:5201:Amsterdam (Novogara)"
    "iperf.online.net:5209:Paris (Online.net)"
    "bouygues.testdebit.info:5209:Paris (Bouygues)"
    "iperf.he.net:5201:Fremont/USA (Hurricane Electric)"
  )

  local success=0
  for entry in "${servers[@]}"; do
    local host="${entry%%:*}" rest="${entry#*:}"
    local port="${rest%%:*}" name="${rest##*:}"
    echo -e "\n  ${BOLD}→ $name ($host:$port)${RESET}"
    local result
    result=$(iperf3_with_timeout "$host" "$port" 5 15)
    if [[ "$result" == "TIMEOUT" ]]; then
      fail "Timeout – übersprungen"; continue
    fi
    if echo "$result" | grep -q "iperf Done"; then
      local bw retr
      bw=$(echo "$result"   | grep "sender" | grep -oE '[0-9.]+ [MGK]bits/sec' | tail -1)
      retr=$(echo "$result" | grep "sender" | awk '{print $9}')
      ok "Bandbreite: ${bw:-unbekannt}"
      if [[ -n "$retr" ]] && [[ "$retr" =~ ^[0-9]+$ ]]; then
        if   [[ $retr -gt 50 ]]; then fail "Retransmits: $retr  ← hohe Paketverluste!"
        elif [[ $retr -gt 10 ]]; then warn "Retransmits: $retr  ← leichte Verluste"
        else ok "Retransmits: $retr  ← sauber"; fi
      fi
      success=1; break
    else
      local err
      err=$(echo "$result" | grep -i "error\|refused\|failed\|busy" | head -1 \
            | sed 's/^[[:space:]]*//' || true)
      fail "Fehler: ${err:-kein Ergebnis} – übersprungen"
    fi
  done

  if [[ $success -eq 0 ]]; then
    echo ""
    warn "Alle iperf3-Server nicht erreichbar."
    info "Mögliche Ursachen: Firewall, Sonntagabend-Last, temporäre Ausfälle."
    info "Alternativ: https://fast.com oder https://speedtest.net"
  fi
}

# ── Zusammenfassung ───────────────────────────────────────────
summary() {
  header "📋 Zusammenfassung"
  local conn_type
  if $HAS_WIFI && $HAS_ETHERNET; then   conn_type="WLAN + Ethernet"
  elif $HAS_WIFI && $IS_HOTSPOT; then   conn_type="Mobiler Hotspot (${WIFI_IF})"
  elif $HAS_WIFI; then                  conn_type="WLAN (${WIFI_IF})"
  elif $HAS_ETHERNET; then              conn_type="Ethernet (${ETH_IF})"
  else                                  conn_type="keine aktive Verbindung"
  fi
  echo -e "  Diagnose abgeschlossen: $(date '+%H:%M:%S')"
  echo -e "  Plattform:    $OS"
  echo -e "  Verbindung:   $conn_type"
  echo -e "  Logfile:      ${LOGFILE}"
  echo ""
  echo -e "  ${BOLD}Legende:${RESET}"
  echo -e "  ${GREEN}✔${RESET}  Alles gut"
  echo -e "  ${YELLOW}⚠${RESET}  Auffälligkeit – prüfen"
  echo -e "  ${RED}✘${RESET}  Problem erkannt"
  echo ""
}

# ── Hauptprogramm ─────────────────────────────────────────────

# Desktop-Pfad: macOS deutsch = Schreibtisch, macOS englisch = Desktop, Linux = Desktop
DESKTOP="${HOME}/Desktop"
[[ -d "${HOME}/Schreibtisch" ]] && DESKTOP="${HOME}/Schreibtisch"
LOGFILE="${DESKTOP}/netcheck_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOGFILE") 2>&1

echo -e "${BOLD}${CYAN}"
echo "  ███╗   ██╗███████╗████████╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗"
echo "  ████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝"
echo "  ██╔██╗ ██║█████╗     ██║   ██║     ███████║█████╗  ██║     █████╔╝ "
echo "  ██║╚██╗██║██╔══╝     ██║   ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗ "
echo "  ██║ ╚████║███████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗"
echo "  ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝"
echo -e "${RESET}"
echo -e "  ${CYAN}macOS/Linux Netzwerk-Diagnose v2.2${RESET} | $(date '+%Y-%m-%d %H:%M')"
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
