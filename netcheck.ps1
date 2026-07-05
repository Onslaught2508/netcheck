# ============================================================
#  netcheck.ps1 – Netzwerk & WLAN Diagnose für Windows
#  v2.2 – Fix: LinkSpeed String-Parsing ("1 Gbps" / "100 Mbps")
#  Autor: github.com/Onslaught2508/netcheck
#  Lizenz: MIT
#  Ausführung: powershell -ExecutionPolicy Bypass -File netcheck.ps1
# ============================================================
#Requires -Version 5.1

# ── Farben & Hilfsfunktionen ───────────────────────────────────
function Write-Header($text) {
    Write-Host "`n══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════" -ForegroundColor Cyan
}
function Write-Ok($text)   { Write-Host "  [OK] $text" -ForegroundColor Green }
function Write-Warn($text) { Write-Host "  [!!] $text" -ForegroundColor Yellow }
function Write-Fail($text) { Write-Host "  [XX] $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host "  [..] $text" -ForegroundColor Gray }

function Get-WlanField([string[]]$lines, [string]$pattern) {
    $match = $lines | Select-String $pattern | Select-Object -First 1
    if ($match) { return ($match.Line -replace "^.*?:\s*", "").Trim() }
    return ""
}

# LinkSpeed robust parsen – Get-NetAdapter liefert je nach Windows-Version
# entweder einen Long (Bits/s) oder einen formatierten String ("1 Gbps", "100 Mbps")
function Get-LinkSpeedMbit($adapter) {
    $raw = $adapter.LinkSpeed
    # Wenn numerisch: direkt umrechnen
    if ($raw -is [long] -or $raw -is [int] -or $raw -is [uint64]) {
        return [math]::Round($raw / 1MB, 0)
    }
    # Wenn String: parsen
    $str = "$raw".Trim()
    if ($str -match '([\d.]+)\s*(G|Gbps|Gbit)') {
        return [math]::Round([double]$Matches[1] * 1000, 0)
    }
    if ($str -match '([\d.]+)\s*(M|Mbps|Mbit)') {
        return [math]::Round([double]$Matches[1], 0)
    }
    if ($str -match '([\d.]+)\s*(K|Kbps|Kbit)') {
        return [math]::Round([double]$Matches[1] / 1000, 0)
    }
    return $null
}

# Desktop-Pfad – robust gegen OneDrive-Umleitung
$Desktop = [System.Environment]::GetFolderPath('Desktop')
$LogFile = "$Desktop\netcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogFile -Append | Out-Null

# ── Banner ─────────────────────────────────────────────────────
Write-Host @"
  ███╗   ██╗███████╗████████╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗
  ████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝
  ██╔██╗ ██║█████╗     ██║   ██║     ███████║█████╗  ██║     █████╔╝
  ██║╚██╗██║██╔══╝     ██║   ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗
  ██║ ╚████║███████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗
  ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝
"@ -ForegroundColor Cyan
Write-Host "  Windows Netzwerk-Diagnose v2.2 | $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host ""

# ── Verbindungsart erkennen ────────────────────────────────────
function Detect-ConnectionType {
    $script:HasWifi     = $false
    $script:HasEthernet = $false
    $script:IsHotspot   = $false
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
                  $a.Name -like '*Wi-Fi*' -or $a.Name -like '*WLAN*'

        $isEth  = $a.PhysicalMediaType -eq '802.3' -or
                  $a.InterfaceDescription -like '*Ethernet*' -or
                  $a.Name -like '*Ethernet*' -or $a.Name -like '*LAN*'

        if ($isWifi) {
            $script:HasWifi     = $true
            $script:WifiAdapter = $a
            $wifiIP = (Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex `
                         -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            if ($wifiIP -like '172.20.10.*') { $script:IsHotspot = $true }
        } elseif ($isEth) {
            $script:HasEthernet = $true
            $script:EthAdapter  = $a
        }
    }
}

# ── Abhängigkeiten prüfen ──────────────────────────────────────
function Check-Dependencies {
    Write-Header "🔍 Abhängigkeiten prüfen"

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Ok "winget verfügbar"
    } else {
        Write-Warn "winget nicht gefunden – iperf3 muss ggf. manuell installiert werden"
        Write-Info "Download: https://iperf.fr/iperf-download.php"
    }

    if (Get-Command iperf3 -ErrorAction SilentlyContinue) {
        Write-Ok "iperf3 verfügbar"
    } else {
        Write-Warn "iperf3 nicht gefunden – Installationsversuch via winget..."
        try {
            winget install --id=iperf3.iperf3 -e --silent 2>&1 | Out-Null
            $candidates = @(
                "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\iperf3.iperf3*\**\iperf3.exe",
                "$env:ProgramFiles\iperf3\iperf3.exe",
                "$env:ProgramFiles (x86)\iperf3\iperf3.exe"
            )
            $found = $null
            foreach ($c in $candidates) {
                $found = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { break }
            }
            if ($found) {
                $env:PATH += ";$($found.DirectoryName)"
                Write-Ok "iperf3 installiert und PATH aktualisiert"
            } else {
                $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
                            [System.Environment]::GetEnvironmentVariable('PATH','User')
                if (Get-Command iperf3 -ErrorAction SilentlyContinue) {
                    Write-Ok "iperf3 verfügbar nach PATH-Refresh"
                } else {
                    Write-Warn "iperf3 installiert – beim nächsten Start verfügbar"
                }
            }
        } catch {
            Write-Fail "iperf3 konnte nicht automatisch installiert werden"
            Write-Info "Manuell: winget install iperf3.iperf3"
        }
    }
    Write-Ok "ping, tracert, nslookup: Windows-Boardmittel vorhanden"
}

# ── System-Info ────────────────────────────────────────────────
function Get-SystemInfo {
    Write-Header "💻 System-Info"
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "Hostname:    $env:COMPUTERNAME"
    Write-Info "OS:          $($os.Caption) Build $($os.BuildNumber)"
    Write-Info "Nutzer:      $env:USERNAME"
    Write-Info "Datum/Zeit:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Info "Logfile:     $LogFile"
}

# ── Netzwerk-Interfaces ────────────────────────────────────────
function Get-NetworkInterfaces {
    Write-Header "🔌 Netzwerk-Interfaces"

    if ($script:HasWifi -and $script:HasEthernet) {
        Write-Warn "WLAN und Ethernet gleichzeitig aktiv – Routing-Priorität beachten"
    } elseif ($script:HasWifi -and $script:IsHotspot) {
        Write-Warn "Verbindungsart: Mobiler Hotspot ($($script:WifiAdapter.Name))  ← eingeschränkte Bandbreite"
    } elseif ($script:HasWifi) {
        Write-Info "Verbindungsart: WLAN ($($script:WifiAdapter.Name))"
    } elseif ($script:HasEthernet) {
        Write-Info "Verbindungsart: Ethernet/Kabel ($($script:EthAdapter.Name))"
    } else {
        Write-Fail "Keine aktive (nicht-virtuelle) Netzwerkverbindung erkannt"
    }

    Write-Host ""
    $adapters = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.*' }
    foreach ($a in $adapters) {
        $iface = Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
        if ($iface -and $iface.Status -eq 'Up') {
            Write-Ok "$($iface.Name): $($a.IPAddress)/$($a.PrefixLength)"
        } else {
            Write-Info "$($a.InterfaceAlias): $($a.IPAddress) (inaktiv)"
        }
    }
    Write-Host ""
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
        Sort-Object RouteMetric | Select-Object -First 1).NextHop
    Write-Info "Standard-Gateway: $gw"
}

# ── WLAN-Info ──────────────────────────────────────────────────
function Get-WlanInfo {
    if (-not $script:HasWifi) {
        Write-Header "📶 WLAN"
        if ($script:HasEthernet) {
            Write-Info "Kein WLAN aktiv – Verbindung läuft über Ethernet ($($script:EthAdapter.Name))"
            Get-EthernetInfo
        } else {
            Write-Fail "Keine aktive Netzwerkverbindung"
        }
        return
    }

    if ($script:IsHotspot) {
        Write-Header "📶 WLAN – Mobiler Hotspot ($($script:WifiAdapter.Name))"
        Write-Warn "Verbindung über mobilen Hotspot erkannt (172.20.10.x)"
        Write-Info "Bandbreite durch Mobilfunknetz begrenzt – Ergebnisse entsprechend einordnen"
    } else {
        Write-Header "📶 WLAN – Aktuelles Netzwerk ($($script:WifiAdapter.Name))"
    }

    [string[]]$wlan = netsh wlan show interfaces 2>$null

    $ssid      = Get-WlanField $wlan 'SSID\s+:'
    $bssid     = Get-WlanField $wlan 'BSSID\s+:'
    $band      = Get-WlanField $wlan 'Band\s+:'
    $channel   = Get-WlanField $wlan 'Channel\s+:'
    $signal    = Get-WlanField $wlan 'Signal\s+:'
    $rxRate    = Get-WlanField $wlan 'Receive rate'
    $txRate    = Get-WlanField $wlan 'Transmit rate'
    $radioType = Get-WlanField $wlan 'Radio type'
    $auth      = Get-WlanField $wlan 'Authentication'

    Write-Info "SSID:         $ssid"
    Write-Info "BSSID:        $bssid"
    Write-Info "Authentif.:   $auth"
    Write-Info "Kanal:        $channel"
    Write-Info "Empfangsrate: $rxRate Mbps / Senderate: $txRate Mbps"

    if     ($band -match '5')  { Write-Ok   "Band: $band  ← 5 GHz: gut" }
    elseif ($band -match '2')  { Write-Warn "Band: $band  ← 2,4 GHz: Interferenzrisiko!" }
    elseif ($band -eq "")      { Write-Info "Band: nicht ermittelbar" }
    else                       { Write-Info "Band: $band" }

    if     ($radioType -match '802\.11ax') { Write-Ok   "Funkstandard: $radioType  ← WiFi 6: aktuell" }
    elseif ($radioType -match '802\.11ac') { Write-Ok   "Funkstandard: $radioType  ← WiFi 5: okay" }
    elseif ($radioType -match '802\.11n')  { Write-Warn "Funkstandard: $radioType  ← WiFi 4: veraltet" }
    elseif ($radioType -eq "")             { Write-Info "Funkstandard: nicht ermittelbar" }
    else                                   { Write-Info "Funkstandard: $radioType" }

    if ($signal -match '(\d+)') {
        $sigVal = [int]$Matches[1]
        if     ($sigVal -ge 70) { Write-Ok   "Signal: $signal  ← gut" }
        elseif ($sigVal -ge 50) { Write-Warn "Signal: $signal  ← mittel" }
        else                    { Write-Fail "Signal: $signal  ← schwach" }
    } else {
        Write-Info "Signal: nicht ermittelbar"
    }
}

# ── Ethernet-Info ─────────────────────────────────────────────
function Get-EthernetInfo {
    Write-Header "🔌 Ethernet-Details ($($script:EthAdapter.Name))"
    $a = $script:EthAdapter
    Write-Info "Adapter:       $($a.Name)"
    Write-Info "Beschreibung:  $($a.InterfaceDescription)"

    # LinkSpeed robust parsen – kann Long (Bits/s) oder String ("1 Gbps") sein
    $speedMbit = Get-LinkSpeedMbit $a

    if ($null -eq $speedMbit) {
        Write-Info "Geschwindigkeit: $($a.LinkSpeed)  (nicht parsebar)"
    } elseif ($speedMbit -ge 1000) {
        Write-Ok  "Geschwindigkeit: $([math]::Round($speedMbit / 1000, 0)) Gbit/s  ← optimal"
    } elseif ($speedMbit -ge 100) {
        Write-Ok  "Geschwindigkeit: ${speedMbit} Mbit/s"
    } else {
        Write-Warn "Geschwindigkeit: ${speedMbit} Mbit/s  ← langsam"
    }

    Write-Info "MAC:           $($a.MacAddress)"
}

# ── Latenz-Test ────────────────────────────────────────────────
function Test-Latency {
    Write-Header "⏱  Latenz-Test"
    if ($script:IsHotspot) { Write-Warn "Hotspot aktiv – Latenz durch Mobilfunknetz beeinflusst" }
    $targets = @(
        @{ Host = '8.8.8.8';  Name = 'Google DNS' },
        @{ Host = '1.1.1.1';  Name = 'Cloudflare DNS' },
        @{ Host = '9.9.9.9';  Name = 'Quad9 DNS' }
    )
    foreach ($t in $targets) {
        $result = Test-Connection -ComputerName $t.Host -Count 4 -ErrorAction SilentlyContinue
        if ($result) {
            $avg = [math]::Round(($result | Measure-Object -Property ResponseTime -Average).Average, 1)
            if     ($avg -lt 30) { Write-Ok   "$($t.Name) ($($t.Host)): ${avg} ms  ← gut" }
            elseif ($avg -lt 80) { Write-Warn "$($t.Name) ($($t.Host)): ${avg} ms  ← akzeptabel" }
            else                 { Write-Fail "$($t.Name) ($($t.Host)): ${avg} ms  ← hoch" }
        } else {
            Write-Fail "$($t.Name) ($($t.Host)): nicht erreichbar"
        }
    }
}

# ── DNS-Auflösung ──────────────────────────────────────────────
function Test-DnsResolution {
    Write-Header "🔎 DNS-Auflösung"
    $domains = @('google.com', 'github.com', 'heise.de')
    foreach ($domain in $domains) {
        $start = Get-Date
        try {
            $ip = (Resolve-DnsName $domain -Type A -ErrorAction Stop |
                Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
            $ms = [math]::Round(((Get-Date) - $start).TotalMilliseconds)
            if     ($ms -lt 50)  { Write-Ok   "$domain → $ip  (${ms} ms)" }
            elseif ($ms -lt 150) { Write-Warn "$domain → $ip  (${ms} ms)  ← etwas langsam" }
            else                 { Write-Fail "$domain → $ip  (${ms} ms)  ← langsam" }
        } catch {
            Write-Fail "$domain → nicht auflösbar"
        }
    }
}

# ── Traceroute ─────────────────────────────────────────────────
function Invoke-Traceroute {
    Write-Header "🗺  Traceroute (max. 15 Hops)"
    if ($script:IsHotspot) { Write-Info "Hinweis: Hotspot-Gateways blockieren oft ICMP → viele * normal" }
    tracert -h 15 -w 2000 8.8.8.8 | Select-Object -Skip 3 | Select-Object -First 18 |
        ForEach-Object { Write-Host "  $_" }
}

# ── Bandbreiten-Test (iperf3) ──────────────────────────────────
function Test-Bandwidth {
    Write-Header "🚀 Bandbreiten-Test (iperf3)"

    if (-not (Get-Command iperf3 -ErrorAction SilentlyContinue)) {
        Write-Warn "iperf3 nicht verfügbar – Test übersprungen"
        Write-Info "Beim nächsten Start verfügbar (winget hat es bereits installiert)."
        Write-Info "Alternativ jetzt: https://fast.com oder https://speedtest.net"
        return
    }

    if ($script:IsHotspot) { Write-Warn "Hotspot aktiv – Bandbreite durch Mobilfunk begrenzt" }
    Write-Warn "Hinweis: Testet TCP-Durchsatz zu öffentlichen iperf3-Servern"
    Write-Warn "Strategie: Fallback-Liste – erster erreichbarer Server gewinnt"

    $servers = @(
        @{ Host = 'speedtest.serverius.net';      Port = 5002; Name = 'Niederlande (Serverius)' },
        @{ Host = 'speedtest.ams1.novogara.net';  Port = 5201; Name = 'Amsterdam (Novogara)' },
        @{ Host = 'iperf.online.net';             Port = 5209; Name = 'Paris (Online.net)' },
        @{ Host = 'bouygues.testdebit.info';      Port = 5209; Name = 'Paris (Bouygues)' },
        @{ Host = 'iperf.he.net';                 Port = 5201; Name = 'Fremont/USA (Hurricane Electric)' }
    )

    $success = $false
    foreach ($s in $servers) {
        Write-Host ""
        Write-Host "  --> $($s.Name) ($($s.Host):$($s.Port))" -ForegroundColor White
        $tcpTest = Test-NetConnection -ComputerName $s.Host -Port $s.Port `
                       -WarningAction SilentlyContinue -InformationLevel Quiet
        if (-not $tcpTest) { Write-Fail "TCP-Verbindung fehlgeschlagen – übersprungen"; continue }

        $job = Start-Job -ScriptBlock {
            param($h, $p)
            & iperf3 -c $h -p $p -t 5 --connect-timeout 4000 2>&1
        } -ArgumentList $s.Host, $s.Port

        $completed = Wait-Job $job -Timeout 15
        if (-not $completed) {
            Stop-Job $job; Remove-Job $job -Force
            Write-Fail "Timeout – übersprungen"; continue
        }

        $output = Receive-Job $job; Remove-Job $job -Force

        if ($output -match 'iperf Done') {
            $bwLine = $output | Where-Object { $_ -match 'sender' } | Select-Object -Last 1
            $bw   = if ($bwLine -match '([\d.]+ [MGK]bits/sec)') { $Matches[1] } else { 'unbekannt' }
            $retr = if ($bwLine -match '\s(\d+)\s+sender') { [int]$Matches[1] } else { $null }
            Write-Ok "Bandbreite: $bw"
            if ($null -ne $retr) {
                if     ($retr -gt 50) { Write-Fail "Retransmits: $retr  ← hohe Paketverluste!" }
                elseif ($retr -gt 10) { Write-Warn "Retransmits: $retr  ← leichte Verluste" }
                else                  { Write-Ok   "Retransmits: $retr  ← sauber" }
            }
            $success = $true; break
        } else {
            $errLine = $output | Where-Object { $_ -match 'error|refused|failed|busy' } |
                Select-Object -First 1
            Write-Fail "Fehler: $($errLine -replace '^\s*','') – übersprungen"
        }
    }

    if (-not $success) {
        Write-Host ""
        Write-Warn "Alle iperf3-Server nicht erreichbar."
        Write-Info "Mögliche Ursachen: Firewall, Sonntagabend-Last, temporäre Ausfälle."
        Write-Info "Bandbreite alternativ testen: https://fast.com oder https://speedtest.net"
    }
}

# ── Zusammenfassung ────────────────────────────────────────────
function Write-Summary {
    Write-Header "📋 Zusammenfassung"
    $connType = if ($script:HasWifi -and $script:HasEthernet)    { "WLAN + Ethernet" }
                elseif ($script:HasWifi -and $script:IsHotspot)  { "Mobiler Hotspot ($($script:WifiAdapter.Name))" }
                elseif ($script:HasWifi)                         { "WLAN ($($script:WifiAdapter.Name))" }
                elseif ($script:HasEthernet)                     { "Ethernet ($($script:EthAdapter.Name))" }
                else                                             { "keine aktive Verbindung" }
    Write-Host "  Diagnose abgeschlossen: $(Get-Date -Format 'HH:mm:ss')"
    Write-Host "  Verbindungsart: $connType"
    Write-Host "  Logfile: $LogFile"
    Write-Host ""
    Write-Host "  Legende:"
    Write-Ok   "Alles gut"
    Write-Warn "Auffälligkeit – prüfen"
    Write-Fail "Problem erkannt"
    Write-Host ""
    Stop-Transcript | Out-Null
}

# ── Hauptprogramm ──────────────────────────────────────────────
Detect-ConnectionType
Check-Dependencies
Get-SystemInfo
Get-NetworkInterfaces
Get-WlanInfo
Test-Latency
Test-DnsResolution
Invoke-Traceroute
Test-Bandwidth
Write-Summary
