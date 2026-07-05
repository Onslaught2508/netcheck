# ============================================================
# netcheck.ps1 – Netzwerk & WLAN Diagnose für Windows
# v2.3 – Gateway-Ping, DNS-Server, Android-Hotspot, IPv6, Logfile-Rotation
# Autor: github.com/Onslaught2508/netcheck
# Lizenz: MIT
# Ausführung: powershell -ExecutionPolicy Bypass -File netcheck.ps1
# ============================================================
#Requires -Version 5.1

# ── Farben & Hilfsfunktionen ─────────────────────────────────
function Write-Header($text) {
    Write-Host "`n══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " $text" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════" -ForegroundColor Cyan
}
function Write-Ok($text)   { Write-Host " [OK] $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host " [!!] $text" -ForegroundColor Yellow }
function Write-Fail($text) { Write-Host " [XX] $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host " [..] $text" -ForegroundColor Gray }

function Get-WlanField([string[]]$lines, [string]$pattern) {
    $match = $lines | Select-String $pattern | Select-Object -First 1
    if ($match) { return ($match.Line -replace "^.*?:\s*", "").Trim() }
    return ""
}

function Get-LinkSpeedMbit($adapter) {
    $raw = $adapter.LinkSpeed
    if ($raw -is [long] -or $raw -is [int] -or $raw -is [uint64]) {
        return [math]::Round($raw / 1MB, 0)
    }
    $str = "$raw".Trim()
    if ($str -match '([\d.]+)\s*(G|Gbps|Gbit)') { return [math]::Round([double]$Matches[1] * 1000, 0) }
    if ($str -match '([\d.]+)\s*(M|Mbps|Mbit)') { return [math]::Round([double]$Matches[1], 0) }
    if ($str -match '([\d.]+)\s*(K|Kbps|Kbit)') { return [math]::Round([double]$Matches[1] / 1000, 0) }
    return $null
}

# ── Logfile-Rotation (max. 5 Dateien) ───────────────────────
function Invoke-LogRotation($dir) {
    $logs = Get-ChildItem -Path $dir -Filter "netcheck_*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    if ($logs.Count -ge 5) {
        $toDelete = $logs | Select-Object -Skip 4
        foreach ($f in $toDelete) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            Write-Info "Altes Logfile gelöscht: $($f.Name)"
        }
    }
}

# ── Desktop-Pfad ────────────────────────────────────────────
$Desktop = [System.Environment]::GetFolderPath('Desktop')
$LogFile = "$Desktop\netcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Invoke-LogRotation $Desktop
Start-Transcript -Path $LogFile -Append | Out-Null

# ── Banner ───────────────────────────────────────────────────
Write-Host @"
 ███╗   ██╗███████╗████████╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗
 ████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝
 ██╔██╗ ██║█████╗     ██║   ██║     ███████║█████╗  ██║     █████╔╝
 ██║╚██╗██║██╔══╝     ██║   ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗
 ██║ ╚████║███████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗
 ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝
"@ -ForegroundColor Cyan
Write-Host " Windows Netzwerk-Diagnose v2.3 | $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host ""

# ── Verbindungsart erkennen ──────────────────────────────────
function Detect-ConnectionType {
    $script:HasWifi     = $false
    $script:HasEthernet = $false
    $script:IsHotspot   = $false
    $script:HotspotType = ""
    $script:WifiAdapter = $null
    $script:EthAdapter  = $null

    $activeAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }

    foreach ($a in $activeAdapters) {
        $isVirtual = $a.Name -like '*vEthernet*' -or
                     $a.InterfaceDescription -like '*Virtual*' -or
                     $a.InterfaceDescription -like '*Hyper-V*'
        if ($isVirtual) { continue }

        $isWifi = $a.PhysicalMediaType -eq 'Native 802.11' -or
                  $a.InterfaceDescription -like '*Wi-Fi*' -or
                  $a.InterfaceDescription -like '*Wireless*' -or
                  $a.Name -like '*Wi-Fi*' -or
                  $a.Name -like '*WLAN*'

        $isEth  = $a.PhysicalMediaType -eq '802.3' -or
                  $a.InterfaceDescription -like '*Ethernet*' -or
                  $a.Name -like '*Ethernet*' -or
                  $a.Name -like '*LAN*'

        if ($isWifi) {
            $script:HasWifi    = $true
            $script:WifiAdapter = $a
            $wifiIP = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex `
                       -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            if ($wifiIP -like '172.20.10.*') {
                $script:IsHotspot   = $true
                $script:HotspotType = "iOS"
            } elseif ($wifiIP -like '192.168.43.*') {
                $script:IsHotspot   = $true
                $script:HotspotType = "Android"
            } elseif ($wifiIP -like '192.168.0.*' -or $wifiIP -like '192.168.1.*') {
                $ssid = (netsh wlan show interfaces 2>$null |
                         Select-String 'SSID\s+:' | Select-Object -First 1)
                if ($ssid -match 'Hotspot|Phone|Android|Pixel|Samsung|Huawei|Xiaomi') {
                    $script:IsHotspot   = $true
                    $script:HotspotType = "Android (vermutet)"
                }
            }
        } elseif ($isEth) {
            $script:HasEthernet = $true
            $script:EthAdapter  = $a
        }
    }
}

# ── Abhängigkeiten prüfen ────────────────────────────────────
function Check-Dependencies {
    Write-Header "🔍 Abhängigkeiten prüfen"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Ok "winget verfügbar"
    } else {
        Write-Warn "winget nicht gefunden"
    }
    if (Get-Command iperf3 -ErrorAction SilentlyContinue) {
        Write-Ok "iperf3 verfügbar"
    } else {
        Write-Warn "iperf3 nicht gefunden – Installationsversuch via winget..."
        try {
            winget install --id=iperf3.iperf3 -e --silent 2>&1 | Out-Null
            $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('PATH','User')
            if (Get-Command iperf3 -ErrorAction SilentlyContinue) {
                Write-Ok "iperf3 verfügbar nach Installation"
            } else {
                Write-Warn "iperf3 installiert – beim nächsten Start verfügbar"
            }
        } catch {
            Write-Fail "iperf3 konnte nicht automatisch installiert werden"
            Write-Info "Manuell: winget install iperf3.iperf3"
        }
    }
    Write-Ok "ping, tracert, nslookup: Windows-Boardmittel vorhanden"
}

# ── System-Info ──────────────────────────────────────────────
function Get-SystemInfo {
    Write-Header "💻 System-Info"
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "Hostname:   $env:COMPUTERNAME"
    Write-Info "OS:         $($os.Caption) Build $($os.BuildNumber)"
    Write-Info "Nutzer:     $env:USERNAME"
    Write-Info "Datum/Zeit: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Info "Logfile:    $LogFile"
}

# ── Netzwerk-Interfaces + IPv6 ───────────────────────────────
function Get-NetworkInterfaces {
    Write-Header "🔌 Netzwerk-Interfaces"

    if ($script:HasWifi -and $script:HasEthernet) {
        Write-Warn "WLAN und Ethernet gleichzeitig aktiv – Routing-Priorität beachten"
    } elseif ($script:HasWifi -and $script:IsHotspot) {
        Write-Warn "Verbindungsart: Mobiler Hotspot ($($script:HotspotType)) via $($script:WifiAdapter.Name)"
    } elseif ($script:HasWifi) {
        Write-Info "Verbindungsart: WLAN ($($script:WifiAdapter.Name))"
    } elseif ($script:HasEthernet) {
        Write-Info "Verbindungsart: Ethernet/Kabel ($($script:EthAdapter.Name))"
    } else {
        Write-Fail "Keine aktive Netzwerkverbindung erkannt"
    }

    Write-Host ""
    $ipv4 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
    foreach ($ip in $ipv4) {
        Write-Info ("  {0,-20} IPv4: {1}" -f $ip.InterfaceAlias, $ip.IPAddress)
    }

    Write-Host ""
    Write-Info "IPv6-Adressen:"
    $ipv6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notlike '::1' -and $_.IPAddress -notlike 'fe80*' }
    if ($ipv6) {
        foreach ($ip in $ipv6) {
            Write-Info ("  {0,-20} {1}" -f $ip.InterfaceAlias, $ip.IPAddress)
        }
        Write-Ok "Globale IPv6-Adresse vorhanden (Dual-Stack aktiv)"
    } else {
        $llv6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like 'fe80*' }
        if ($llv6) { Write-Warn "Nur Link-Local IPv6 (fe80::) – kein Dual-Stack" }
        else        { Write-Warn "Kein IPv6 konfiguriert" }
    }

    Write-Host ""
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
           Sort-Object RouteMetric | Select-Object -First 1).NextHop
    if ($gw) { Write-Info "Standard-Gateway: $gw" }
    else      { Write-Warn "Standard-Gateway nicht ermittelbar" }
}

# ── Gateway-Ping ─────────────────────────────────────────────
function Test-Gateway {
    Write-Header "🚪 Gateway-Erreichbarkeit"
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
           Sort-Object RouteMetric | Select-Object -First 1).NextHop
    if (-not $gw) {
        Write-Fail "Kein Standard-Gateway gefunden"
        return
    }
    Write-Info "Pinge Gateway: $gw"
    $ping = Test-Connection -ComputerName $gw -Count 4 -ErrorAction SilentlyContinue
    if (-not $ping) {
        Write-Fail "Gateway $gw nicht erreichbar – lokales Netzwerkproblem"
        return
    }
    $avg  = [math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average, 1)
    $loss = 4 - $ping.Count
    if ($loss -eq 0) { Write-Ok   "Gateway $gw erreichbar – kein Paketverlust" }
    else             { Write-Warn "Gateway $gw erreichbar – Paketverlust: $loss/4 Pakete" }
    Write-Info "Latenz zum Gateway: $avg ms"
    if ($avg -gt 10) { Write-Warn "Latenz > 10 ms – lokale Verbindung prüfen" }
}

# ── DNS-Server anzeigen ──────────────────────────────────────
function Show-DnsServers {
    Write-Header "🔎 DNS-Konfiguration"
    Write-Info "Konfigurierte DNS-Server:"
    $dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.ServerAddresses.Count -gt 0 }
    if ($dnsServers) {
        foreach ($entry in $dnsServers) {
            foreach ($srv in $entry.ServerAddresses) {
                $label = switch -Wildcard ($srv) {
                    '8.8.8.8'   { '← Google DNS' }
                    '8.8.4.4'   { '← Google DNS' }
                    '1.1.1.1'   { '← Cloudflare DNS' }
                    '1.0.0.1'   { '← Cloudflare DNS' }
                    '9.9.9.9'   { '← Quad9 DNS' }
                    '192.168.*' { '← Lokaler/Router-DNS' }
                    '10.*'      { '← Lokaler/Router-DNS' }
                    default     { '' }
                }
                Write-Info ("  {0,-18} {1}  {2}" -f $entry.InterfaceAlias, $srv, $label)
            }
        }
    } else {
        Write-Warn "Keine DNS-Server ermittelbar"
    }
}

# ── WLAN-Info ────────────────────────────────────────────────
function Get-WifiInfo {
    if (-not $script:HasWifi) { return }
    Write-Header "📶 WLAN-Details"
    $wlanLines = netsh wlan show interfaces 2>$null
    if (-not $wlanLines) { Write-Warn "netsh wlan nicht verfügbar"; return }
    $ssid    = Get-WlanField $wlanLines 'SSID\s+:'
    $radio   = Get-WlanField $wlanLines 'Radio type'
    $channel = Get-WlanField $wlanLines 'Channel'
    $signal  = Get-WlanField $wlanLines 'Signal'
    $rxRate  = Get-WlanField $wlanLines 'Receive rate'
    $txRate  = Get-WlanField $wlanLines 'Transmit rate'
    if ($ssid)    { Write-Info "SSID:          $ssid" }
    if ($radio)   { Write-Info "Standard:      $radio" }
    if ($channel) { Write-Info "Kanal:         $channel" }
    if ($rxRate)  { Write-Info "Empfangsrate:  $rxRate Mbps" }
    if ($txRate)  { Write-Info "Senderate:     $txRate Mbps" }
    if ($signal) {
        $sigNum = [int]($signal -replace '[^0-9]', '')
        Write-Info "Signal:        $signal"
        if     ($sigNum -ge 80) { Write-Ok   "Signalqualität gut (≥ 80 %)" }
        elseif ($sigNum -ge 50) { Write-Warn "Signalqualität mäßig (50–79 %)" }
        else                    { Write-Fail "Signalqualität schlecht (< 50 %)" }
    }
}

# ── Ethernet-Info ────────────────────────────────────────────
function Get-EthernetInfo {
    if (-not $script:HasEthernet) { return }
    Write-Header "🔗 Ethernet-Details"
    $a = $script:EthAdapter
    Write-Info "Adapter: $($a.Name) – $($a.InterfaceDescription)"
    $speed = Get-LinkSpeedMbit $a
    if ($speed) { Write-Info "Geschwindigkeit: $speed Mbit/s" }
    if ($a.FullDuplex -eq $false) { Write-Warn "Half-Duplex erkannt" }
    else { Write-Ok "Full-Duplex" }
}

# ── Latenz ───────────────────────────────────────────────────
function Test-Latency {
    Write-Header "⏱ Latenz-Test"
    $targets = @(
        @{ Host = '8.8.8.8'; Label = 'Google DNS' },
        @{ Host = '1.1.1.1'; Label = 'Cloudflare DNS' },
        @{ Host = '9.9.9.9'; Label = 'Quad9' }
    )
    foreach ($t in $targets) {
        $result = Test-Connection -ComputerName $t.Host -Count 4 -ErrorAction SilentlyContinue
        if (-not $result) { Write-Fail "$($t.Label) ($($t.Host)) – nicht erreichbar"; continue }
        $avg = [math]::Round(($result | Measure-Object -Property ResponseTime -Average).Average, 1)
        if     ($avg -lt 20) { Write-Ok   "$($t.Label): $avg ms" }
        elseif ($avg -lt 60) { Write-Warn "$($t.Label): $avg ms (erhöht)" }
        else                 { Write-Fail "$($t.Label): $avg ms (hoch)" }
    }
    Write-Info "Hinweis: ICMP wird von großen Providern deprioritisiert"
}

# ── DNS-Auflösung ────────────────────────────────────────────
function Test-DnsResolution {
    Write-Header "🌐 DNS-Auflösung"
    $domains = @('google.com', 'github.com', 'heise.de')
    foreach ($d in $domains) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = [System.Net.Dns]::GetHostAddresses($d)
            $sw.Stop(); $ms = $sw.ElapsedMilliseconds
            if     ($ms -lt 50)  { Write-Ok   "${d}: $ms ms" }
            elseif ($ms -lt 200) { Write-Warn "${d}: $ms ms (erhöht)" }
            else                 { Write-Fail "${d}: $ms ms (hoch)" }
        } catch { Write-Fail "${d}: Auflösung fehlgeschlagen" }
    }
}

# ── Traceroute ───────────────────────────────────────────────
function Invoke-Traceroute {
    Write-Header "🗺 Traceroute (→ 8.8.8.8, max. 15 Hops)"
    if ($script:IsHotspot) { Write-Warn "Hotspot aktiv – viele * * * Zeilen sind normal" }
    tracert -h 15 8.8.8.8 2>$null
}

# ── Bandbreite ───────────────────────────────────────────────
function Test-Bandwidth {
    Write-Header "📊 Bandbreiten-Test (iperf3)"
    if (-not (Get-Command iperf3 -ErrorAction SilentlyContinue)) {
        Write-Warn "iperf3 nicht verfügbar – übersprungen"
        return
    }
    if ($script:IsHotspot) { Write-Warn "Hotspot aktiv – Bandbreite durch Mobilfunk begrenzt" }
    $servers = @(
        @{ Host = 'speedtest.serverius.net';     Port = 5002 },
        @{ Host = 'speedtest.ams1.novogara.net'; Port = 5201 },
        @{ Host = 'iperf.online.net';            Port = 5209 },
        @{ Host = 'bouygues.testdebit.info';     Port = 5209 },
        @{ Host = 'iperf.he.net';                Port = 5201 }
    )
    $success = $false
    foreach ($s in $servers) {
        Write-Info "Teste Server: $($s.Host):$($s.Port)"
        $job = Start-Job -ScriptBlock {
            param($h,$p); iperf3 -c $h -p $p -t 5 --connect-timeout 4000 2>&1
        } -ArgumentList $s.Host, $s.Port
        $done = Wait-Job $job -Timeout 15
        if (-not $done) { Stop-Job $job; Remove-Job $job -Force; Write-Warn "  → Timeout"; continue }
        $out = Receive-Job $job; Remove-Job $job -Force
        if ($out -match 'error|unable|refused|failed') { Write-Warn "  → Nicht erreichbar"; continue }
        if ($out -match 'sender|receiver') {
            $out | Where-Object { $_ -match 'sender|receiver|Mbits|Gbits' } | ForEach-Object { Write-Host "  $_" }
            Write-Ok "Test abgeschlossen"
            $success = $true; break
        }
    }
    if (-not $success) { Write-Warn "Alle Server nicht erreichbar – Alternative: fast.com" }
}

# ── Zusammenfassung ──────────────────────────────────────────
function Write-Summary {
    Write-Header "✅ Diagnose abgeschlossen"
    Write-Info "Logfile: $LogFile"
}

# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════
Detect-ConnectionType
Check-Dependencies
Get-SystemInfo
Get-NetworkInterfaces
Test-Gateway
Show-DnsServers
Get-WifiInfo
Get-EthernetInfo
Test-Latency
Test-DnsResolution
Invoke-Traceroute
Test-Bandwidth
Write-Summary

Stop-Transcript | Out-Null
