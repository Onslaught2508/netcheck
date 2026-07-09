# ============================================================
# netcheck.ps1 – Netzwerk & WLAN Diagnose für Windows
# v2.3.2 – Encoding-Fix, TcpClient-Gateway, iperf3-Pfadsuche
# Autor: github.com/Onslaught2508/netcheck
# Lizenz: MIT
# Ausführung: powershell -ExecutionPolicy Bypass -File netcheck.ps1
# ============================================================
#Requires -Version 5.1

# Muss vor allem anderen stehen – PS 5.1 nutzt sonst ibm850/us-ascii,
# was bei irm|iex mit Emojis im Skript zu stillem Abbruch führt
[System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding                  = [System.Text.Encoding]::UTF8

$script:Iperf3Executable = $null

function Write-Header($Text) {
    Write-Host "`n══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════" -ForegroundColor Cyan
}

function Write-Ok($Text)   { Write-Host " [OK] $Text" -ForegroundColor Green }
function Write-Warn($Text) { Write-Host " [!!] $Text" -ForegroundColor Yellow }
function Write-Fail($Text) { Write-Host " [XX] $Text" -ForegroundColor Red }
function Write-Info($Text) { Write-Host " [..] $Text" -ForegroundColor Gray }

function Get-WlanField {
    param([string[]]$NetshLines, [string]$FieldPattern)
    $matchedLine = $NetshLines | Select-String $FieldPattern | Select-Object -First 1
    if (-not $matchedLine) { return "" }
    return ($matchedLine.Line -replace "^.*?:\s*", "").Trim()
}

function Get-LinkSpeedMbit {
    param($NetworkAdapter)
    $linkSpeedRaw = $NetworkAdapter.LinkSpeed
    if ($linkSpeedRaw -is [long] -or $linkSpeedRaw -is [int] -or $linkSpeedRaw -is [uint64]) {
        return [math]::Round($linkSpeedRaw / 1MB, 0)
    }
    $linkSpeedText = "$linkSpeedRaw".Trim()
    if ($linkSpeedText -match '([\d.]+)\s*(G|Gbps|Gbit)') { return [math]::Round([double]$Matches[1] * 1000, 0) }
    if ($linkSpeedText -match '([\d.]+)\s*(M|Mbps|Mbit)') { return [math]::Round([double]$Matches[1], 0) }
    if ($linkSpeedText -match '([\d.]+)\s*(K|Kbps|Kbit)') { return [math]::Round([double]$Matches[1] / 1000, 0) }
    return $null
}

function Invoke-LogRotation {
    param([string]$LogDirectory)
    $existingLogs = Get-ChildItem -Path $LogDirectory -Filter "netcheck_*.log" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending
    if ($existingLogs.Count -lt 5) { return }
    $existingLogs | Select-Object -Skip 4 | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Info "Altes Logfile gelöscht: $($_.Name)"
    }
}

function Get-DefaultGateway {
    $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Sort-Object RouteMetric | Select-Object -First 1
    if ($defaultRoute) { return $defaultRoute.NextHop }
    return $null
}

# TcpClient statt Test-NetConnection: kein Verbose-Output, definierter Timeout
function Test-TcpPort {
    param([string]$RemoteHost, [int]$Port, [int]$TimeoutMs = 1500)
    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $tcpClient.ConnectAsync($RemoteHost, $Port)
        if (-not $connectTask.Wait($TimeoutMs)) { return $false }
        return $tcpClient.Connected
    } catch {
        return $false
    } finally {
        $tcpClient.Close()
        $tcpClient.Dispose()
    }
}

function Find-Iperf3Executable {
    $iperf3InPath = Get-Command iperf3 -ErrorAction SilentlyContinue
    if ($iperf3InPath) { return $iperf3InPath.Source }

    $iperf3SearchRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        "$env:LOCALAPPDATA\Microsoft\WinGet",
        "$env:LOCALAPPDATA\Programs",
        $env:USERPROFILE
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($searchRoot in $iperf3SearchRoots) {
        $iperf3File = Get-ChildItem -Path $searchRoot -Filter "iperf3.exe" -Recurse -ErrorAction SilentlyContinue |
                      Select-Object -First 1
        if ($iperf3File) { return $iperf3File.FullName }
    }

    return $null
}

function Detect-ConnectionType {
    $script:HasWifi         = $false
    $script:HasEthernet     = $false
    $script:IsHotspot       = $false
    $script:HotspotType     = ""
    $script:WifiAdapter     = $null
    $script:EthernetAdapter = $null

    $activeAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }

    foreach ($networkAdapter in $activeAdapters) {
        $isVirtual = $networkAdapter.Name -like '*vEthernet*' -or
                     $networkAdapter.InterfaceDescription -like '*Virtual*' -or
                     $networkAdapter.InterfaceDescription -like '*Hyper-V*'
        if ($isVirtual) { continue }

        $isWifi = $networkAdapter.PhysicalMediaType -eq 'Native 802.11' -or
                  $networkAdapter.InterfaceDescription -like '*Wi-Fi*' -or
                  $networkAdapter.InterfaceDescription -like '*Wireless*' -or
                  $networkAdapter.Name -like '*Wi-Fi*' -or
                  $networkAdapter.Name -like '*WLAN*'

        $isEthernet = $networkAdapter.PhysicalMediaType -eq '802.3' -or
                      $networkAdapter.InterfaceDescription -like '*Ethernet*' -or
                      $networkAdapter.Name -like '*Ethernet*' -or
                      $networkAdapter.Name -like '*LAN*'

        if ($isWifi) {
            $script:HasWifi     = $true
            $script:WifiAdapter = $networkAdapter
            Detect-HotspotType $networkAdapter
            continue
        }

        if ($isEthernet) {
            $script:HasEthernet     = $true
            $script:EthernetAdapter = $networkAdapter
        }
    }
}

function Detect-HotspotType {
    param($WifiNetworkAdapter)

    $wifiIpAddress = (Get-NetIPAddress -InterfaceIndex $WifiNetworkAdapter.InterfaceIndex `
                      -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                      Select-Object -First 1).IPAddress

    if ($wifiIpAddress -like '172.20.10.*') {
        $script:IsHotspot = $true; $script:HotspotType = "iOS"; return
    }
    if ($wifiIpAddress -like '192.168.43.*') {
        $script:IsHotspot = $true; $script:HotspotType = "Android"; return
    }
    if ($wifiIpAddress -notlike '192.168.0.*' -and $wifiIpAddress -notlike '192.168.1.*') { return }

    $ssidOutputLine = netsh wlan show interfaces 2>$null | Select-String 'SSID\s+:' | Select-Object -First 1
    if ($ssidOutputLine -match 'Hotspot|Phone|Android|Pixel|Samsung|Huawei|Xiaomi') {
        $script:IsHotspot = $true; $script:HotspotType = "Android (vermutet)"
    }
}

function Check-Dependencies {
    Write-Header "🔍 Abhängigkeiten prüfen"

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Ok "winget verfügbar"
    } else {
        Write-Warn "winget nicht gefunden"
    }

    $script:Iperf3Executable = Find-Iperf3Executable

    if ($script:Iperf3Executable) {
        Write-Ok "iperf3 verfügbar: $($script:Iperf3Executable)"
        Write-Ok "ping, tracert, nslookup: Windows-Boardmittel vorhanden"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "iperf3 nicht verfügbar und winget fehlt – Bandbreiten-Test wird übersprungen"
        Write-Ok "ping, tracert, nslookup: Windows-Boardmittel vorhanden"
        return
    }

    Write-Warn "iperf3 nicht gefunden – Installationsversuch via winget..."
    winget install --id iperf3.iperf3 -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null

    $script:Iperf3Executable = Find-Iperf3Executable

    if ($script:Iperf3Executable) {
        Write-Ok "iperf3 verfügbar nach Installation: $($script:Iperf3Executable)"
    } else {
        Write-Warn "iperf3 nach Installation nicht auffindbar – PowerShell neu starten oder Pfad prüfen"
        Write-Info "Manuell prüfen: Get-ChildItem `$env:ProgramFiles -Filter iperf3.exe -Recurse"
    }

    Write-Ok "ping, tracert, nslookup: Windows-Boardmittel vorhanden"
}

function Get-SystemInfo {
    Write-Header "💻 System-Info"
    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Info "Hostname:   $env:COMPUTERNAME"
    if ($operatingSystem) { Write-Info "OS:         $($operatingSystem.Caption) Build $($operatingSystem.BuildNumber)" }
    Write-Info "Nutzer:     $env:USERNAME"
    Write-Info "Datum/Zeit: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Info "Logfile:    $LogFile"
}

function Get-NetworkInterfaces {
    Write-Header "🔌 Netzwerk-Interfaces"

    if ($script:HasWifi -and $script:HasEthernet) {
        Write-Warn "WLAN und Ethernet gleichzeitig aktiv – Routing-Priorität beachten"
    } elseif ($script:HasWifi -and $script:IsHotspot) {
        Write-Warn "Verbindungsart: Mobiler Hotspot ($($script:HotspotType)) via $($script:WifiAdapter.Name)"
    } elseif ($script:HasWifi) {
        Write-Info "Verbindungsart: WLAN ($($script:WifiAdapter.Name))"
    } elseif ($script:HasEthernet) {
        Write-Info "Verbindungsart: Ethernet/Kabel ($($script:EthernetAdapter.Name))"
    } else {
        Write-Fail "Keine aktive Netzwerkverbindung erkannt"
    }

    Write-Host ""

    $activeIpv4Addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                           Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }
    foreach ($ipv4Address in $activeIpv4Addresses) {
        Write-Info ("  {0,-20} IPv4: {1}" -f $ipv4Address.InterfaceAlias, $ipv4Address.IPAddress)
    }

    Write-Host ""
    Write-Info "IPv6-Adressen:"

    $globalIpv6Addresses = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                           Where-Object { $_.IPAddress -notlike '::1' -and $_.IPAddress -notlike 'fe80*' }

    if ($globalIpv6Addresses) {
        foreach ($ipv6Address in $globalIpv6Addresses) {
            Write-Info ("  {0,-20} {1}" -f $ipv6Address.InterfaceAlias, $ipv6Address.IPAddress)
        }
        Write-Ok "Globale IPv6-Adresse vorhanden (Dual-Stack aktiv)"
    } else {
        $linkLocalIpv6 = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                         Where-Object { $_.IPAddress -like 'fe80*' }
        if ($linkLocalIpv6) { Write-Warn "Nur Link-Local IPv6 (fe80::) – kein Dual-Stack" }
        else                { Write-Warn "Kein IPv6 konfiguriert" }
    }

    Write-Host ""
    $script:DefaultGateway = Get-DefaultGateway
    if ($script:DefaultGateway) { Write-Info "Standard-Gateway: $script:DefaultGateway" }
    else                        { Write-Warn "Standard-Gateway nicht ermittelbar" }
}

function Test-Gateway {
    Write-Header "🚪 Gateway-Erreichbarkeit"

    $gatewayAddress = if ($script:DefaultGateway) { $script:DefaultGateway } else { Get-DefaultGateway }
    if (-not $gatewayAddress) { Write-Fail "Kein Standard-Gateway gefunden"; return }

    Write-Info "Pinge Gateway: $gatewayAddress"

    $icmpReachable = Test-Connection -ComputerName $gatewayAddress -Count 2 -Quiet `
                     -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    if ($icmpReachable) {
        $pingSamples = Test-Connection -ComputerName $gatewayAddress -Count 4 `
                       -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        if ($pingSamples) {
            $avgGatewayLatencyMs = [math]::Round(
                ($pingSamples | Measure-Object -Property ResponseTime -Average).Average, 1)
            $lostPackets = 4 - $pingSamples.Count

            if ($lostPackets -eq 0) { Write-Ok   "Gateway $gatewayAddress erreichbar via ICMP – kein Paketverlust" }
            else                    { Write-Warn "Gateway $gatewayAddress erreichbar via ICMP – Paketverlust: $lostPackets/4 Pakete" }

            Write-Info "Latenz zum Gateway: $avgGatewayLatencyMs ms"
            if ($avgGatewayLatencyMs -gt 10) { Write-Warn "Latenz > 10 ms – lokale Verbindung prüfen" }
        } else {
            Write-Ok "Gateway $gatewayAddress erreichbar via ICMP"
        }
        return
    }

    foreach ($tcpFallbackPort in @(53, 80, 443)) {
        if (Test-TcpPort -RemoteHost $gatewayAddress -Port $tcpFallbackPort -TimeoutMs 1200) {
            Write-Ok "Gateway $gatewayAddress erreichbar via TCP Port $tcpFallbackPort"
            Write-Info "Hinweis: ICMP wird vermutlich durch Router/Firewall blockiert"
            return
        }
    }

    if (Test-TcpPort -RemoteHost "1.1.1.1" -Port 443 -TimeoutMs 1500) {
        Write-Warn "Gateway $gatewayAddress antwortet nicht auf ICMP/TCP – Internet aber erreichbar"
        Write-Info "Hinweis: Router/Firewall blockiert lokale Diagnosepakete – kein lokaler Ausfall"
        return
    }

    Write-Fail "Gateway $gatewayAddress nicht erreichbar – lokales Netzwerkproblem wahrscheinlich"
}

function Show-DnsServers {
    Write-Header "🔎 DNS-Konfiguration"
    Write-Info "Konfigurierte DNS-Server:"

    $configuredDnsEntries = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object { $_.ServerAddresses.Count -gt 0 }

    if (-not $configuredDnsEntries) { Write-Warn "Keine DNS-Server ermittelbar"; return }

    foreach ($dnsEntry in $configuredDnsEntries) {
        foreach ($dnsServerAddress in $dnsEntry.ServerAddresses) {
            $providerLabel = switch -Wildcard ($dnsServerAddress) {
                '8.8.8.8'      { '<- Google DNS' }
                '8.8.4.4'      { '<- Google DNS' }
                '1.1.1.1'      { '<- Cloudflare DNS' }
                '1.0.0.1'      { '<- Cloudflare DNS' }
                '9.9.9.9'      { '<- Quad9 DNS' }
                '192.168.*'    { '<- Lokaler/Router-DNS' }
                '10.*'         { '<- Lokaler/Router-DNS' }
                '172.1[6-9].*' { '<- Lokaler/Router-DNS' }
                '172.2?.*'     { '<- Lokaler/Router-DNS' }
                '172.31.*'     { '<- Lokaler/Router-DNS' }
                default        { '' }
            }
            Write-Info ("  {0,-18} {1}  {2}" -f $dnsEntry.InterfaceAlias, $dnsServerAddress, $providerLabel)
        }
    }
}

function Get-WifiInfo {
    if (-not $script:HasWifi) { return }
    Write-Header "📶 WLAN-Details"

    $wlanInterfaceOutput = netsh wlan show interfaces 2>$null
    if (-not $wlanInterfaceOutput) { Write-Warn "netsh wlan nicht verfügbar"; return }

    $ssid          = Get-WlanField $wlanInterfaceOutput 'SSID\s+:'
    $radioType     = Get-WlanField $wlanInterfaceOutput 'Radio type'
    $wifiChannel   = Get-WlanField $wlanInterfaceOutput 'Channel'
    $signalQuality = Get-WlanField $wlanInterfaceOutput 'Signal'
    $receiveRate   = Get-WlanField $wlanInterfaceOutput 'Receive rate'
    $transmitRate  = Get-WlanField $wlanInterfaceOutput 'Transmit rate'

    if ($ssid)         { Write-Info "SSID:          $ssid" }
    if ($radioType)    { Write-Info "Standard:      $radioType" }
    if ($wifiChannel)  { Write-Info "Kanal:         $wifiChannel" }
    if ($receiveRate)  { Write-Info "Empfangsrate:  $receiveRate Mbps" }
    if ($transmitRate) { Write-Info "Senderate:     $transmitRate Mbps" }
    if (-not $signalQuality) { return }

    $signalPercent = [int]($signalQuality -replace '[^0-9]', '')
    Write-Info "Signal:        $signalQuality"

    if ($signalPercent -ge 80)     { Write-Ok   "Signalqualität gut (≥ 80 %)" }
    elseif ($signalPercent -ge 50) { Write-Warn "Signalqualität mäßig (50–79 %)" }
    else                           { Write-Fail "Signalqualität schlecht (< 50 %)" }
}

function Get-EthernetInfo {
    if (-not $script:HasEthernet) { return }
    Write-Header "🔗 Ethernet-Details"

    $ethernetAdapter = $script:EthernetAdapter
    Write-Info "Adapter: $($ethernetAdapter.Name) – $($ethernetAdapter.InterfaceDescription)"

    $linkSpeedMbit = Get-LinkSpeedMbit $ethernetAdapter
    if ($linkSpeedMbit) { Write-Info "Geschwindigkeit: $linkSpeedMbit Mbit/s" }

    if ($ethernetAdapter.FullDuplex -eq $false) { Write-Warn "Half-Duplex erkannt" }
    else                                        { Write-Ok   "Full-Duplex" }
}

function Test-Latency {
    Write-Header "⏱ Latenz-Test"

    $latencyTargets = @(
        @{ Host = '8.8.8.8'; Label = 'Google DNS' },
        @{ Host = '1.1.1.1'; Label = 'Cloudflare DNS' },
        @{ Host = '9.9.9.9'; Label = 'Quad9' }
    )

    foreach ($latencyTarget in $latencyTargets) {
        $pingSamples = Test-Connection -ComputerName $latencyTarget.Host -Count 4 `
                       -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        if (-not $pingSamples) { Write-Fail "$($latencyTarget.Label) ($($latencyTarget.Host)) – nicht erreichbar"; continue }

        $avgLatencyMs = [math]::Round(($pingSamples | Measure-Object -Property ResponseTime -Average).Average, 1)

        if ($avgLatencyMs -lt 20)     { Write-Ok   "$($latencyTarget.Label): $avgLatencyMs ms" }
        elseif ($avgLatencyMs -lt 60) { Write-Warn "$($latencyTarget.Label): $avgLatencyMs ms (erhöht)" }
        else                          { Write-Fail "$($latencyTarget.Label): $avgLatencyMs ms (hoch)" }
    }

    Write-Info "Hinweis: ICMP wird von großen Providern deprioritisiert"
}

function Test-DnsResolution {
    Write-Header "🌐 DNS-Auflösung"

    foreach ($domainName in @('google.com', 'github.com', 'heise.de')) {
        $dnsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = [System.Net.Dns]::GetHostAddresses($domainName)
            $dnsStopwatch.Stop()
        } catch {
            $dnsStopwatch.Stop()
            Write-Fail "${domainName}: Auflösung fehlgeschlagen"
            continue
        }

        $dnsResolutionMs = $dnsStopwatch.ElapsedMilliseconds
        if ($dnsResolutionMs -lt 100)     { Write-Ok   "${domainName}: $dnsResolutionMs ms" }
        elseif ($dnsResolutionMs -lt 250) { Write-Warn "${domainName}: $dnsResolutionMs ms (erhöht)" }
        else                              { Write-Fail "${domainName}: $dnsResolutionMs ms (hoch)" }
    }
}

function Invoke-Traceroute {
    Write-Header "🗺 Traceroute (→ 8.8.8.8, max. 15 Hops)"
    if ($script:IsHotspot) { Write-Warn "Hotspot aktiv – viele * * * Zeilen sind normal" }
    tracert -h 15 8.8.8.8 2>$null
}

function Test-Bandwidth {
    Write-Header "📊 Bandbreiten-Test (iperf3)"

    if (-not $script:Iperf3Executable) { $script:Iperf3Executable = Find-Iperf3Executable }
    if (-not $script:Iperf3Executable) { Write-Warn "iperf3 nicht verfügbar – übersprungen"; return }

    if ($script:IsHotspot) { Write-Warn "Hotspot aktiv – Bandbreite durch Mobilfunk begrenzt" }

    $iperfServers = @(
        @{ Host = 'speedtest.serverius.net';     Port = 5002 },
        @{ Host = 'speedtest.ams1.novogara.net'; Port = 5201 },
        @{ Host = 'iperf.online.net';            Port = 5209 },
        @{ Host = 'bouygues.testdebit.info';     Port = 5209 },
        @{ Host = 'iperf.he.net';                Port = 5201 }
    )

    $iperf3Bin = $script:Iperf3Executable

    foreach ($iperfServer in $iperfServers) {
        Write-Info "Teste Server: $($iperfServer.Host):$($iperfServer.Port)"

        $iperfJob = Start-Job -ScriptBlock {
            param($Iperf3Bin, $ServerHost, $ServerPort)
            & $Iperf3Bin -c $ServerHost -p $ServerPort -t 5 --connect-timeout 4000 2>&1
        } -ArgumentList $iperf3Bin, $iperfServer.Host, $iperfServer.Port

        $iperfFinished = Wait-Job $iperfJob -Timeout 15

        if (-not $iperfFinished) {
            Stop-Job  $iperfJob -ErrorAction SilentlyContinue
            Remove-Job $iperfJob -Force -ErrorAction SilentlyContinue
            Write-Warn "  -> Timeout"
            continue
        }

        $iperfOutput = Receive-Job $iperfJob -ErrorAction SilentlyContinue
        Remove-Job $iperfJob -Force -ErrorAction SilentlyContinue

        if ($iperfOutput -match 'error|unable|refused|failed|busy') {
            Write-Warn "  -> Nicht erreichbar"
            continue
        }

        if ($iperfOutput -match 'sender|receiver') {
            $iperfOutput | Where-Object { $_ -match 'sender|receiver|Mbits|Gbits' } |
                           ForEach-Object { Write-Host "  $_" }
            Write-Ok "Test abgeschlossen"
            return
        }
    }

    Write-Warn "Alle Server nicht erreichbar – Alternative: fast.com oder speedtest.net"
}

function Write-Summary {
    Write-Header "✅ Diagnose abgeschlossen"
    Write-Info "Logfile: $LogFile"
}

# ── Start ────────────────────────────────────────────────────
$DesktopPath = [System.Environment]::GetFolderPath('Desktop')
$LogFile     = Join-Path $DesktopPath "netcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Invoke-LogRotation $DesktopPath
Start-Transcript -Path $LogFile -Append | Out-Null

Write-Host @"
 ███╗   ██╗███████╗████████╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗
 ████╗  ██║██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝
 ██╔██╗ ██║█████╗     ██║   ██║     ███████║█████╗  ██║     █████╔╝
 ██║╚██╗██║██╔══╝     ██║   ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗
 ██║ ╚████║███████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗
 ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝
"@ -ForegroundColor Cyan
Write-Host " Windows Netzwerk-Diagnose v2.3.2 | $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host ""

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
