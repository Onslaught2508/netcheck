# ============================================================
#  netcheck.ps1 – Netzwerk & WLAN Diagnose für Windows
#  Autor: github.com/Onslaught2508/netcheck
#  Lizenz: MIT
#  Ausführung: powershell -ExecutionPolicy Bypass -File netcheck.ps1
# ============================================================

#Requires -Version 5.1

# ── Farben & Hilfsfunktionen ─────────────────────────────────
function Write-Header($text) {
    Write-Host "`n══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════" -ForegroundColor Cyan
}
function Write-Ok($text)   { Write-Host "  [OK] $text"   -ForegroundColor Green  }
function Write-Warn($text) { Write-Host "  [!!] $text"   -ForegroundColor Yellow }
function Write-Fail($text) { Write-Host "  [XX] $text"   -ForegroundColor Red    }
function Write-Info($text) { Write-Host "  [..] $text"   -ForegroundColor Gray   }

# Logfile
$LogFile = "$env:TEMP\netcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogFile -Append | Out-Null

# ── Banner ───────────────────────────────────────────────────
Write-Host @"
╔═══════════════════════════════════════╗
║   NETCHECK – Windows Netzwerkdiagnose ║
╚═══════════════════════════════════════╝
"@ -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# ── Abhängigkeiten prüfen ────────────────────────────────────
function Check-Dependencies {
    Write-Header "Abhängigkeiten prüfen"

    # winget prüfen
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Ok "winget verfügbar"
    } else {
        Write-Warn "winget nicht gefunden – iperf3 muss manuell installiert werden"
        Write-Info "Download: https://iperf.fr/iperf-download.php"
    }

    # iperf3 prüfen
    if (Get-Command iperf3 -ErrorAction SilentlyContinue) {
        Write-Ok "iperf3 verfügbar"
    } else {
        Write-Warn "iperf3 nicht gefunden – wird via winget installiert..."
        try {
            winget install --id=iperf3.iperf3 -e --silent
            Write-Ok "iperf3 installiert – bitte Skript neu starten"
            Stop-Transcript | Out-Null
            exit 0
        } catch {
            Write-Fail "iperf3 konnte nicht automatisch installiert werden"
            Write-Info "Manuell installieren: winget install iperf3.iperf3"
        }
    }

    # nslookup / ping / tracert sind Windows-Boardmittel
    Write-Ok "ping, tracert, nslookup: Windows-Boardmittel vorhanden"
}

# ── System-Info ───────────────────────────────────────────────
function Get-SystemInfo {
    Write-Header "System-Info"
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Info "Hostname:    $env:COMPUTERNAME"
    Write-Info "OS:          $($os.Caption) Build $($os.BuildNumber)"
    Write-Info "Nutzer:      $env:USERNAME"
    Write-Info "Datum/Zeit:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

# ── Netzwerk-Interfaces ───────────────────────────────────────
function Get-NetworkInterfaces {
    Write-Header "Netzwerk-Interfaces"

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

    # Gateway
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
           Sort-Object RouteMetric | Select-Object -First 1).NextHop
    Write-Info "Standard-Gateway: $gw"
}

# ── WLAN-Info ─────────────────────────────────────────────────
function Get-WlanInfo {
    Write-Header "WLAN – Aktuelles Netzwerk"

    # netsh wlan show interfaces
    $wlan = netsh wlan show interfaces 2>$null

    if ($wlan -match 'There is no wireless') {
        Write-Fail "Kein WLAN-Adapter gefunden"
        return
    }

    $ssid        = ($wlan | Select-String 'SSID\s+:' | Select-Object -First 1) -replace '.*:\s*',''
    $bssid       = ($wlan | Select-String 'BSSID\s+:') -replace '.*:\s*',''
    $band        = ($wlan | Select-String 'Band\s+:') -replace '.*:\s*',''
    $channel     = ($wlan | Select-String 'Channel\s+:') -replace '.*:\s*',''
    $signal      = ($wlan | Select-String 'Signal\s+:') -replace '.*:\s*',''
    $rxRate      = ($wlan | Select-String 'Receive rate') -replace '.*:\s*',''
    $txRate      = ($wlan | Select-String 'Transmit rate') -replace '.*:\s*',''
    $radioType   = ($wlan | Select-String 'Radio type') -replace '.*:\s*',''
    $auth        = ($wlan | Select-String 'Authentication') -replace '.*:\s*',''

    Write-Info "SSID:         $($ssid.Trim())"
    Write-Info "BSSID:        $($bssid.Trim())"
    Write-Info "Authentif.:   $($auth.Trim())"

    # Band bewerten
    $bandVal = $band.Trim()
    if ($bandVal -match '5') {
        Write-Ok  "Band:         $bandVal  ← 5 GHz: gut"
    } elseif ($bandVal -match '2') {
        Write-Warn "Band:         $bandVal  ← 2,4 GHz: Interferenzrisiko"
    } else {
        Write-Info "Band:         $bandVal"
    }

    Write-Info "Kanal:        $($channel.Trim())"

    # Radio Type bewerten
    $rt = $radioType.Trim()
    if ($rt -match '802.11ax') { Write-Ok  "Funkstandard: $rt  ← WiFi 6" }
    elseif ($rt -match '802.11ac') { Write-Ok  "Funkstandard: $rt  ← WiFi 5" }
    elseif ($rt -match '802.11n')  { Write-Warn "Funkstandard: $rt  ← WiFi 4 (veraltet)" }
    else                           { Write-Info "Funkstandard: $rt" }

    # Signal bewerten
    $sigNum = [int]($signal -replace '[^0-9]','')
    if ($sigNum -ge 70)     { Write-Ok  "Signal:       $($signal.Trim())  ← gut" }
    elseif ($sigNum -ge 40) { Write-Warn "Signal:       $($signal.Trim())  ← mittel" }
    else                    { Write-Fail "Signal:       $($signal.Trim())  ← schwach" }

    Write-Info "TX-Rate:      $($txRate.Trim()) Mbps"
    Write-Info "RX-Rate:      $($rxRate.Trim()) Mbps"

    # Verfügbare Netze in der Umgebung
    Write-Header "WLAN-Umgebung (Nachbar-Netze)"
    $networks = netsh wlan show networks mode=bssid 2>$null
    $count = ($networks | Select-String 'SSID\s+\d+\s+:' | Measure-Object).Count
    Write-Info "Sichtbare Netzwerke in der Umgebung: $count"

    # Kanal-Belegung
    $channels = $networks | Select-String 'Channel\s+:' |
        ForEach-Object { ($_ -replace '.*:\s*','').Trim() } |
        Group-Object | Sort-Object Count -Descending

    foreach ($ch in $channels) {
        if ($ch.Count -ge 4) { Write-Fail "Kanal $($ch.Name): $($ch.Count) Netze  ← überfüllt" }
        elseif ($ch.Count -ge 2) { Write-Warn "Kanal $($ch.Name): $($ch.Count) Netze" }
        else { Write-Ok  "Kanal $($ch.Name): $($ch.Count) Netz" }
    }
}

# ── Ping / Latenz ─────────────────────────────────────────────
function Test-Latency {
    Write-Header "Latenz-Test"

    $targets = @(
        @{Host='8.8.8.8';    Name='Google DNS'},
        @{Host='1.1.1.1';    Name='Cloudflare DNS'},
        @{Host='9.9.9.9';    Name='Quad9 DNS'}
    )

    foreach ($t in $targets) {
        $result = Test-Connection -ComputerName $t.Host -Count 4 -ErrorAction SilentlyContinue
        if ($result) {
            $avg = [math]::Round(($result | Measure-Object -Property ResponseTime -Average).Average, 1)
            if ($avg -lt 30)     { Write-Ok   "$($t.Name) ($($t.Host)): $avg ms  ← gut" }
            elseif ($avg -lt 80) { Write-Warn "$($t.Name) ($($t.Host)): $avg ms  ← akzeptabel" }
            else                 { Write-Fail "$($t.Name) ($($t.Host)): $avg ms  ← hoch" }
        } else {
            Write-Fail "$($t.Name) ($($t.Host)): nicht erreichbar"
        }
    }
}

# ── DNS-Check ─────────────────────────────────────────────────
function Test-DNS {
    Write-Header "DNS-Auflösung"

    $domains = @('google.com', 'github.com', 'heise.de')
    foreach ($d in $domains) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $ip = ([System.Net.Dns]::GetHostAddresses($d) | Select-Object -First 1).IPAddressToString
            $sw.Stop()
            Write-Ok "$d → $ip  ($($sw.ElapsedMilliseconds) ms)"
        } catch {
            $sw.Stop()
            Write-Fail "$d → nicht auflösbar"
        }
    }
}

# ── Traceroute ────────────────────────────────────────────────
function Test-Traceroute {
    Write-Header "Traceroute (max. 15 Hops)"
    tracert -h 15 -w 2000 8.8.8.8 2>$null | Select-Object -First 25 |
        ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}

# ── Bandbreite (iperf3) ───────────────────────────────────────
function Test-Bandwidth {
    Write-Header "Bandbreiten-Test (iperf3)"

    if (-not (Get-Command iperf3 -ErrorAction SilentlyContinue)) {
        Write-Warn "iperf3 nicht verfügbar – Bandbreitentest übersprungen"
        return
    }

    $servers = @(
        @{Host='iperf.par2.as49434.net'; Port=9201; Name='Paris'},
        @{Host='speedtest.serverius.net'; Port=5002; Name='Niederlande'}
    )

    foreach ($s in $servers) {
        Write-Host "`n  → $($s.Name) ($($s.Host):$($s.Port))" -ForegroundColor White
        $output = iperf3 -c $s.Host -p $s.Port -t 5 --connect-timeout 3000 2>&1

        if ($output -match 'iperf Done') {
            $senderLine = $output | Where-Object { $_ -match 'sender' } | Select-Object -Last 1
            if ($senderLine -match '([\d.]+ [MGK]bits/sec)') {
                Write-Ok  "Bandbreite: $($Matches[1])"
            }
            if ($senderLine -match '\s(\d+)\s+sender') {
                $retr = [int]$Matches[1]
                if ($retr -gt 50)     { Write-Fail "Retransmits: $retr  ← hohe Paketverluste!" }
                elseif ($retr -gt 10) { Write-Warn "Retransmits: $retr  ← leichte Verluste" }
                else                  { Write-Ok   "Retransmits: $retr  ← sauber" }
            }
        } else {
            Write-Fail "Server nicht erreichbar oder Timeout"
        }
    }
}

# ── Zusammenfassung ───────────────────────────────────────────
function Write-Summary {
    Write-Header "Zusammenfassung"
    Write-Host "  Diagnose abgeschlossen: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor White
    Write-Host "  Logfile: $LogFile" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Legende:" -ForegroundColor White
    Write-Ok   "Alles gut"
    Write-Warn "Auffälligkeit – prüfen"
    Write-Fail "Problem erkannt"
    Write-Host ""
}

# ── Hauptprogramm ─────────────────────────────────────────────
Check-Dependencies
Get-SystemInfo
Get-NetworkInterfaces
Get-WlanInfo
Test-Latency
Test-DNS
Test-Traceroute
Test-Bandwidth
Write-Summary

Stop-Transcript | Out-Null
