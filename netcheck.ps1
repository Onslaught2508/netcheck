# ============================================================
#  netcheck.ps1 – Netzwerk & WLAN Diagnose für Windows
#  v1.3.1 – Fix: exit 0 → return, kein Session-Abbruch bei iperf3-Install
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

# Logfile
$LogFile = "$env:TEMP\netcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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
Write-Host "  Windows Netzwerk-Diagnose v1.3.1 | $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host ""

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
            # PATH neu einlesen ohne Session-Neustart
            $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('PATH','User')
            if (Get-Command iperf3 -ErrorAction SilentlyContinue) {
                Write-Ok "iperf3 erfolgreich installiert – fahre fort"
            } else {
                Write-Warn "iperf3 installiert – im PATH noch nicht sichtbar"
                Write-Info "Bandbreiten-Test wird übersprungen. Skript neu starten für vollen Test."
                # Kein exit/return – Skript läuft weiter, bandwidth_check fängt das ab
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
}

# ── Netzwerk-Interfaces ────────────────────────────────────────
function Get-NetworkInterfaces {
    Write-Header "🔌 Netzwerk-Interfaces"
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

    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
        Sort-Object RouteMetric | Select-Object -First 1).NextHop
    Write-Info "Standard-Gateway: $gw"
}

# ── WLAN-Info ──────────────────────────────────────────────────
function Get-WlanInfo {
    Write-Header "📶 WLAN – Aktuelles Netzwerk"

    $wlan = netsh wlan show interfaces 2>$null
    if ($wlan -match 'There is no wireless') {
        Write-Fail "Kein WLAN-Adapter gefunden"
        return
    }

    $ssid      = ($wlan | Select-String 'SSID\s+:'      | Select-Object -First 1) -replace '.*:\s*',''
    $bssid     = ($wlan | Select-String 'BSSID\s+:'                              ) -replace '.*:\s*',''
    $band      = ($wlan | Select-String 'Band\s+:'                               ) -replace '.*:\s*',''
    $channel   = ($wlan | Select-String 'Channel\s+:'                            ) -replace '.*:\s*',''
    $signal    = ($wlan | Select-String 'Signal\s+:'                             ) -replace '.*:\s*',''
    $rxRate    = ($wlan | Select-String 'Receive rate'                           ) -replace '.*:\s*',''
    $txRate    = ($wlan | Select-String 'Transmit rate'                          ) -replace '.*:\s*',''
    $radioType = ($wlan | Select-String 'Radio type'                             ) -replace '.*:\s*',''
    $auth      = ($wlan | Select-String 'Authentication'                         ) -replace '.*:\s*',''

    Write-Info "SSID:         $($ssid.Trim())"
    Write-Info "BSSID:        $($bssid.Trim())"
    Write-Info "Authentif.:   $($auth.Trim())"
    Write-Info "Kanal:        $($channel.Trim())"
    Write-Info "Empfangsrate: $($rxRate.Trim()) / Senderate: $($txRate.Trim()) Mbps"

    $bandVal = $band.Trim()
    if     ($bandVal -match '5')  { Write-Ok   "Band: $bandVal  ← 5 GHz: gut" }
    elseif ($bandVal -match '2')  { Write-Warn "Band: $bandVal  ← 2,4 GHz: Interferenzrisiko!" }
    else                          { Write-Info "Band: $bandVal" }

    $rt = $radioType.Trim()
    if     ($rt -match '802\.11ax') { Write-Ok   "Funkstandard: $rt  ← WiFi 6: aktuell" }
    elseif ($rt -match '802\.11ac') { Write-Ok   "Funkstandard: $rt  ← WiFi 5: okay" }
    elseif ($rt -match '802\.11n')  { Write-Warn "Funkstandard: $rt  ← WiFi 4: veraltet" }
    else                            { Write-Info "Funkstandard: $rt" }

    $sigVal = [int]($signal -replace '[^0-9]','')
    if     ($sigVal -ge 70) { Write-Ok   "Signal: $($signal.Trim())  ← gut" }
    elseif ($sigVal -ge 50) { Write-Warn "Signal: $($signal.Trim())  ← mittel" }
    else                    { Write-Fail "Signal: $($signal.Trim())  ← schwach" }
}

# ── Latenz-Test ────────────────────────────────────────────────
function Test-Latency {
    Write-Header "⏱  Latenz-Test"

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
    tracert -h 15 -w 2000 8.8.8.8 | Select-Object -Skip 3 | Select-Object -First 18 |
        ForEach-Object { Write-Host "  $_" }
}

# ── Bandbreiten-Test (iperf3) ──────────────────────────────────
function Test-Bandwidth {
    Write-Header "🚀 Bandbreiten-Test (iperf3)"

    # Prüfen ob iperf3 überhaupt verfügbar ist
    if (-not (Get-Command iperf3 -ErrorAction SilentlyContinue)) {
        Write-Warn "iperf3 nicht verfügbar – Bandbreiten-Test übersprungen"
        Write-Info "Skript neu starten nach manueller Installation: winget install iperf3.iperf3"
        return
    }

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
        if (-not $tcpTest) {
            Write-Fail "TCP-Verbindung fehlgeschlagen – übersprungen"
            continue
        }

        $job = Start-Job -ScriptBlock {
            param($h, $p)
            & iperf3 -c $h -p $p -t 5 --connect-timeout 4000 2>&1
        } -ArgumentList $s.Host, $s.Port

        $completed = Wait-Job $job -Timeout 15
        if (-not $completed) {
            Stop-Job $job
            Remove-Job $job -Force
            Write-Fail "Timeout – übersprungen"
            continue
        }

        $output = Receive-Job $job
        Remove-Job $job -Force

        if ($output -match 'iperf Done') {
            $bwLine = $output | Where-Object { $_ -match 'sender' } | Select-Object -Last 1
            $bw     = if ($bwLine -match '([\d.]+ [MGK]bits/sec)') { $Matches[1] } else { 'unbekannt' }
            $retr   = if ($bwLine -match '\s(\d+)\s+sender') { [int]$Matches[1] } else { $null }

            Write-Ok "Bandbreite: $bw"
            if ($null -ne $retr) {
                if     ($retr -gt 50) { Write-Fail "Retransmits: $retr  ← hohe Paketverluste!" }
                elseif ($retr -gt 10) { Write-Warn "Retransmits: $retr  ← leichte Verluste" }
                else                  { Write-Ok   "Retransmits: $retr  ← sauber" }
            }
            $success = $true
            break
        } else {
            $errLine = $output | Where-Object { $_ -match 'error|refused|failed' } |
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
    Write-Host "  Diagnose abgeschlossen: $(Get-Date -Format 'HH:mm:ss')"
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
Check-Dependencies
Get-SystemInfo
Get-NetworkInterfaces
Get-WlanInfo
Test-Latency
Test-DnsResolution
Invoke-Traceroute
Test-Bandwidth
Write-Summary
