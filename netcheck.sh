#!/usr/bin/env bash
# ============================================================
# netcheck.sh – Netzwerk & WLAN Diagnose für macOS/Linux
# v2.3 – Gateway-Ping, DNS-Server, Android-Hotspot, IPv6, Logfile-Rotation
# Autor: github.com/Onslaught2508/netcheck
# Lizenz: MIT
# ============================================================

# ── Farben ───────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; GRAY='\033[0;37m'; RESET='\033[0m'

ok()   { echo -e "${GREEN} [OK] $*${RESET}"; }
warn() { echo -e "${YELLOW} [!!] $*${RESET}"; }
fail() { echo -e "${RED} [XX] $*${RESET}"; }
info() { echo -e "${GRAY} [..] $*${RESET}"; }
header() { echo -e "\n${CYAN}══════════════════════════════════════\n $*\n══════════════════════════════════════${RESET}"; }

# ── Desktop-Pfad ─────────────────────────────────────────────
if [[ "$OSTYPE" == "darwin"* ]]; then
    DESKTOP="$HOME/Desktop"
else
    DESKTOP="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
fi
LOGFILE="$DESKTOP/netcheck_$(date '+%Y%m%d_%H%M%S').log"

# ── Logfile-Rotation (max. 5 Dateien) ────────────────────────
rotate_logs() {
    local count=5
    local dir="$DESKTOP"
    local logs
    mapfile -t logs < <(ls -t "$dir"/netcheck_*.log 2>/dev/null)
    local total=${#logs[@]}
    if (( total >= count )); then
        for (( i=count-1; i<total; i++ )); do
            rm -f "${logs[$i]}"
            info "Altes Logfile gelöscht: $(basename "${logs[$i]}")"
        done
    fi
}
rotate_logs

exec > >(tee -a "$LOGFILE") 2>&1

# ── Banner ───────────────────────────────────────────────────
echo -e "${CYAN}"
cat << 'EOF'
 ███╗   ██╗███████╗████████╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗
 ████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝
 ██╔██╗ ██║█████╗     ██║   ██║     ███████║█████╗  ██║     █████╔╝
 ██║╚██╗██║██╔══╝     ██║   ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗
 ██║ ╚████║███████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗
 ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝
EOF
echo -e " macOS/Linux Netzwerk-Diagnose v2.3 | $(date '+%Y-%m-%d %H:%M')${RESET}"
echo ""

# ── Verbindungsart erkennen ──────────────────────────────────
HAS_WIFI=false; HAS_ETHERNET=false; IS_HOTSPOT=false
HOTSPOT_TYPE=""; WIFI_IF=""; ETH_IF=""

detect_connection_type() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local wifi_if
        wifi_if=$(networksetup -listallhardwareports 2>/dev/null | \
                  awk '/Wi-Fi|AirPort/{found=1} found && /Device:/{print $2; exit}')
        local eth_if
        eth_if=$(networksetup -listallhardwareports 2>/dev/null | \
                 awk '/Ethernet/{found=1} found && /Device:/{print $2; exit}')

        if [[ -n "$wifi_if" ]] && ifconfig "$wifi_if" 2>/dev/null | grep -q 'inet '; then
            HAS_WIFI=true; WIFI_IF="$wifi_if"
            local ip; ip=$(ipconfig getifaddr "$wifi_if" 2>/dev/null)
            if   [[ "$ip" == 172.20.10.* ]]; then IS_HOTSPOT=true; HOTSPOT_TYPE="iOS"
            elif [[ "$ip" == 192.168.43.* ]]; then IS_HOTSPOT=true; HOTSPOT_TYPE="Android"
            elif [[ "$ip" == 192.168.0.* || "$ip" == 192.168.1.* ]]; then
                local ssid
                ssid=$(networksetup -getairportnetwork "$wifi_if" 2>/dev/null | sed 's/Current Wi-Fi Network: //')
                if echo "$ssid" | grep -qiE 'hotspot|phone|android|pixel|samsung|huawei|xiaomi'; then
                    IS_HOTSPOT=true; HOTSPOT_TYPE="Android (vermutet)"
                fi
            fi
        fi
        if [[ -n "$eth_if" ]] && ifconfig "$eth_if" 2>/dev/null | grep -q 'inet '; then
            HAS_ETHERNET=true; ETH_IF="$eth_if"
        fi
    else
        for iface in $(ls /sys/class/net/); do
            [[ "$iface" == "lo" ]] && continue
            local operstate; operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)
            [[ "$operstate" != "up" ]] && continue
            if [[ -d "/sys/class/net/$iface/wireless" ]] || iw dev "$iface" info &>/dev/null 2>&1; then
                HAS_WIFI=true; WIFI_IF="$iface"
                local ip; ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
                if   [[ "$ip" == 172.20.10.* ]]; then IS_HOTSPOT=true; HOTSPOT_TYPE="iOS"
                elif [[ "$ip" == 192.168.43.* ]]; then IS_HOTSPOT=true; HOTSPOT_TYPE="Android"
                elif [[ "$ip" == 192.168.0.* || "$ip" == 192.168.1.* ]]; then
                    local ssid; ssid=$(iwgetid -r "$iface" 2>/dev/null)
                    if echo "$ssid" | grep -qiE 'hotspot|phone|android|pixel|samsung|huawei|xiaomi'; then
                        IS_HOTSPOT=true; HOTSPOT_TYPE="Android (vermutet)"
                    fi
                fi
            elif [[ "$iface" == eth* || "$iface" == en* || "$iface" == eno* || "$iface" == enp* ]]; then
                HAS_ETHERNET=true; ETH_IF="$iface"
            fi
        done
    fi
}

# ── Abhängigkeiten prüfen ────────────────────────────────────
check_dependencies() {
    header "🔍 Abhängigkeiten prüfen"
    for cmd in ping traceroute curl; do
        if command -v "$cmd" &>/dev/null; then ok "$cmd verfügbar"
        else fail "$cmd nicht gefunden"; fi
    done
    if command -v iperf3 &>/dev/null; then ok "iperf3 verfügbar"
    else
        warn "iperf3 nicht gefunden"
        if [[ "$OSTYPE" == "darwin"* ]]; then info "Installation: brew install iperf3"
        else info "Installation: sudo apt install iperf3  oder  sudo dnf install iperf3"; fi
    fi
}

# ── System-Info ──────────────────────────────────────────────
get_system_info() {
    header "💻 System-Info"
    info "Hostname:   $(hostname)"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        info "OS:         $(sw_vers -productName) $(sw_vers -productVersion)"
    else
        info "OS:         $(uname -o) $(uname -r)"
        [[ -f /etc/os-release ]] && info "Distro:     $(. /etc/os-release; echo "$PRETTY_NAME")"
    fi
    info "Nutzer:     $(whoami)"
    info "Datum/Zeit: $(date '+%Y-%m-%d %H:%M:%S')"
    info "Logfile:    $LOGFILE"
}

# ── Netzwerk-Interfaces + IPv6 ───────────────────────────────
get_network_interfaces() {
    header "🔌 Netzwerk-Interfaces"
    if $HAS_WIFI && $HAS_ETHERNET; then
        warn "WLAN und Ethernet gleichzeitig aktiv – Routing-Priorität beachten"
    elif $HAS_WIFI && $IS_HOTSPOT; then
        warn "Verbindungsart: Mobiler Hotspot ($HOTSPOT_TYPE) via $WIFI_IF"
    elif $HAS_WIFI; then info "Verbindungsart: WLAN ($WIFI_IF)"
    elif $HAS_ETHERNET; then info "Verbindungsart: Ethernet/Kabel ($ETH_IF)"
    else fail "Keine aktive Netzwerkverbindung erkannt"; fi

    echo ""
    info "IPv4-Adressen:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ifconfig 2>/dev/null | awk '/^[a-z]/{iface=$1} /inet /{
            if ($2 !~ /^127\./ && $2 !~ /^169\.254\./)
                printf "   %-18s %s\n", iface, $2}'
    else
        ip -4 addr show 2>/dev/null | awk '/^[0-9]/{split($2,a,":");iface=a[1]}
            /inet /{split($2,a,"/");
                if (a[1] !~ /^127\./ && a[1] !~ /^169\.254\./)
                    printf "   %-18s %s\n", iface, a[1]}'
    fi

    echo ""
    info "IPv6-Adressen:"
    local ipv6_global=""
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ipv6_global=$(ifconfig 2>/dev/null | awk '/inet6/{if ($2 !~ /^::1/ && $2 !~ /^fe80/) print $2}')
    else
        ipv6_global=$(ip -6 addr show 2>/dev/null | awk '/inet6/{split($2,a,"/"); if (a[1] !~ /^::1/ && a[1] !~ /^fe80/) print a[1]}')
    fi
    if [[ -n "$ipv6_global" ]]; then
        echo "$ipv6_global" | while read -r addr; do info "  $addr"; done
        ok "Globale IPv6-Adresse vorhanden (Dual-Stack aktiv)"
    else
        warn "Nur Link-Local IPv6 oder kein IPv6 konfiguriert"
    fi

    echo ""
    local gw=""
    if [[ "$OSTYPE" == "darwin"* ]]; then gw=$(netstat -rn 2>/dev/null | awk '/^default/{print $2; exit}')
    else gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}'); fi
    if [[ -n "$gw" ]]; then info "Standard-Gateway: $gw"
    else warn "Standard-Gateway nicht ermittelbar"; fi
}

# ── Gateway-Ping ─────────────────────────────────────────────
test_gateway() {
    header "🚪 Gateway-Erreichbarkeit"
    local gw=""
    if [[ "$OSTYPE" == "darwin"* ]]; then gw=$(netstat -rn 2>/dev/null | awk '/^default/{print $2; exit}')
    else gw=$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}'); fi

    if [[ -z "$gw" ]]; then fail "Kein Standard-Gateway gefunden"; return; fi
    info "Pinge Gateway: $gw"
    local ping_out; ping_out=$(ping -c 4 -W 2 "$gw" 2>/dev/null)
    if [[ $? -ne 0 ]]; then fail "Gateway $gw nicht erreichbar – lokales Netzwerkproblem"; return; fi

    local loss; loss=$(echo "$ping_out" | grep -oE '[0-9]+% packet loss' | grep -oE '[0-9]+')
    local avg;  avg=$(echo "$ping_out"  | grep -oE 'min/avg/max[^=]*= [0-9.]+/([0-9.]+)' | grep -oE '[0-9.]+/[0-9.]+' | cut -d/ -f2)

    if [[ "$loss" == "0" ]]; then ok "Gateway $gw erreichbar – kein Paketverlust"
    elif [[ -n "$loss" ]]; then warn "Gateway $gw erreichbar – Paketverlust: $loss%"
    else ok "Gateway $gw erreichbar"; fi

    if [[ -n "$avg" ]]; then
        info "Latenz zum Gateway: ${avg} ms"
        if (( $(echo "$avg > 10" | bc -l 2>/dev/null || echo 0) )); then
            warn "Latenz > 10 ms – lokale Verbindung prüfen"
        fi
    fi
}

# ── DNS-Server anzeigen ──────────────────────────────────────
show_dns_servers() {
    header "🔎 DNS-Konfiguration"
    info "Konfigurierte DNS-Server:"
    local dns_servers=()
    if [[ "$OSTYPE" == "darwin"* ]]; then
        mapfile -t dns_servers < <(scutil --dns 2>/dev/null | awk '/nameserver/{print $3}' | sort -u)
    else
        if [[ -f /etc/resolv.conf ]]; then
            mapfile -t dns_servers < <(awk '/^nameserver/{print $2}' /etc/resolv.conf)
        fi
    fi
    if [[ ${#dns_servers[@]} -eq 0 ]]; then warn "Keine DNS-Server ermittelbar"; return; fi
    for srv in "${dns_servers[@]}"; do
        local label=""
        case "$srv" in
            8.8.8.8|8.8.4.4)  label="← Google DNS" ;;
            1.1.1.1|1.0.0.1)  label="← Cloudflare DNS" ;;
            9.9.9.9)           label="← Quad9 DNS" ;;
            192.168.*|10.*)    label="← Lokaler/Router-DNS" ;;
        esac
        info "  $srv  $label"
    done
}

# ── WLAN-Info ────────────────────────────────────────────────
get_wifi_info() {
    $HAS_WIFI || return
    header "📶 WLAN-Details"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local airport="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
        if [[ -x "$airport" ]]; then
            local info_out; info_out=$("$airport" -I 2>/dev/null)
            local ssid signal noise channel
            ssid=$(echo "$info_out"    | awk '/ SSID:/{print $2}')
            signal=$(echo "$info_out"  | awk '/agrCtlRSSI:/{print $2}')
            noise=$(echo "$info_out"   | awk '/agrCtlNoise:/{print $2}')
            channel=$(echo "$info_out" | awk '/channel:/{print $2}')
            [[ -n "$ssid" ]]    && info "SSID:    $ssid"
            [[ -n "$channel" ]] && info "Kanal:   $channel"
            if [[ -n "$signal" && -n "$noise" ]]; then
                local snr=$(( signal - noise ))
                info "Signal: $signal dBm | Rauschen: $noise dBm | SNR: $snr dB"
                if   (( snr >= 25 )); then ok   "Signalqualität gut (SNR ≥ 25 dB)"
                elif (( snr >= 15 )); then warn "Signalqualität mäßig (SNR 15–24 dB)"
                else                       fail "Signalqualität schlecht (SNR < 15 dB)"; fi
            fi
        fi
    else
        if command -v iwconfig &>/dev/null; then
            iwconfig "$WIFI_IF" 2>/dev/null | grep -E 'SSID|Quality|Signal|Bit Rate' | while read -r line; do info "  $line"; done
        elif command -v iw &>/dev/null; then
            iw dev "$WIFI_IF" link 2>/dev/null | grep -E 'SSID|signal|tx bitrate' | while read -r line; do info "  $line"; done
        fi
    fi
}

# ── Ethernet-Info ────────────────────────────────────────────
get_ethernet_info() {
    $HAS_ETHERNET || return
    header "🔗 Ethernet-Details"
    info "Interface: $ETH_IF"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local speed; speed=$(networksetup -getMedia "$ETH_IF" 2>/dev/null | awk '/Active/{print $3, $4}')
        [[ -n "$speed" ]] && info "Geschwindigkeit: $speed"
    else
        if command -v ethtool &>/dev/null; then
            local eth_out; eth_out=$(ethtool "$ETH_IF" 2>/dev/null)
            local speed duplex
            speed=$(echo "$eth_out"  | awk '/Speed:/{print $2}')
            duplex=$(echo "$eth_out" | awk '/Duplex:/{print $2}')
            [[ -n "$speed" ]] && info "Geschwindigkeit: $speed"
            if [[ "$duplex" == "Half" ]]; then warn "Half-Duplex erkannt"
            elif [[ -n "$duplex" ]]; then ok "Full-Duplex"; fi
        else
            local speed; speed=$(cat "/sys/class/net/$ETH_IF/speed" 2>/dev/null)
            [[ -n "$speed" ]] && info "Geschwindigkeit: ${speed} Mbit/s"
        fi
    fi
}

# ── Latenz ───────────────────────────────────────────────────
test_latency() {
    header "⏱ Latenz-Test"
    declare -A targets=(["8.8.8.8"]="Google DNS" ["1.1.1.1"]="Cloudflare DNS" ["9.9.9.9"]="Quad9")
    for host in "${!targets[@]}"; do
        local label="${targets[$host]}"
        local ping_out; ping_out=$(ping -c 4 -W 2 "$host" 2>/dev/null)
        if [[ $? -ne 0 ]]; then fail "$label ($host) – nicht erreichbar"; continue; fi
        local avg; avg=$(echo "$ping_out" | grep -oE 'min/avg/max[^=]*= [0-9.]+/([0-9.]+)' | grep -oE '[0-9.]+/[0-9.]+' | cut -d/ -f2)
        if [[ -n "$avg" ]]; then
            local avg_int=${avg%.*}
            if   (( avg_int < 20 )); then ok   "$label: $avg ms"
            elif (( avg_int < 60 )); then warn "$label: $avg ms (erhöht)"
            else                          fail "$label: $avg ms (hoch)"; fi
        else ok "$label ($host) erreichbar"; fi
    done
    info "Hinweis: ICMP wird von großen Providern deprioritisiert"
}

# ── DNS-Auflösung ────────────────────────────────────────────
test_dns_resolution() {
    header "🌐 DNS-Auflösung"
    local domains=("google.com" "github.com" "heise.de")
    for d in "${domains[@]}"; do
        local start end ms
        start=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")
        if host "$d" &>/dev/null 2>&1 || nslookup "$d" &>/dev/null 2>&1; then
            end=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")
            ms=$(( end - start ))
            if   (( ms < 50  )); then ok   "$d: $ms ms"
            elif (( ms < 200 )); then warn "$d: $ms ms (erhöht)"
            else                      fail "$d: $ms ms (hoch)"; fi
        else fail "$d: Auflösung fehlgeschlagen"; fi
    done
}

# ── Traceroute ───────────────────────────────────────────────
run_traceroute() {
    header "🗺 Traceroute (→ 8.8.8.8, max. 15 Hops)"
    $IS_HOTSPOT && warn "Hotspot aktiv – viele * * * Zeilen sind normal"
    if command -v traceroute &>/dev/null; then traceroute -m 15 8.8.8.8 2>/dev/null
    elif command -v tracepath &>/dev/null; then tracepath -m 15 8.8.8.8 2>/dev/null
    else warn "Weder traceroute noch tracepath verfügbar"; fi
}

# ── Bandbreite ───────────────────────────────────────────────
test_bandwidth() {
    header "📊 Bandbreiten-Test (iperf3)"
    if ! command -v iperf3 &>/dev/null; then warn "iperf3 nicht verfügbar – übersprungen"; return; fi
    $IS_HOTSPOT && warn "Hotspot aktiv – Bandbreite durch Mobilfunk begrenzt"
    local servers=("speedtest.serverius.net:5002" "speedtest.ams1.novogara.net:5201"
                   "iperf.online.net:5209" "bouygues.testdebit.info:5209" "iperf.he.net:5201")
    local success=false
    for entry in "${servers[@]}"; do
        local host="${entry%%:*}"; local port="${entry##*:}"
        info "Teste Server: $host:$port"
        local out; out=$(timeout 15 iperf3 -c "$host" -p "$port" -t 5 --connect-timeout 4 2>&1)
        if echo "$out" | grep -qiE 'error|unable|refused|failed|timed out'; then
            warn "  → Nicht erreichbar"; continue; fi
        if echo "$out" | grep -qE 'sender|receiver'; then
            echo "$out" | grep -E 'sender|receiver|Mbits|Gbits' | while read -r line; do echo "  $line"; done
            ok "Test abgeschlossen"; success=true; break; fi
    done
    $success || warn "Alle Server nicht erreichbar – Alternative: fast.com"
}

# ── Zusammenfassung ──────────────────────────────────────────
write_summary() {
    header "✅ Diagnose abgeschlossen"
    info "Logfile gespeichert: $LOGFILE"
}

# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════
detect_connection_type
check_dependencies
get_system_info
get_network_interfaces
test_gateway
show_dns_servers
get_wifi_info
get_ethernet_info
test_latency
test_dns_resolution
run_traceroute
test_bandwidth
write_summary
