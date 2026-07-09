# ============================================================
# netcheck.ps1 – Netzwerk & WLAN Diagnose für Windows
# v2.3.1 – robuster Gateway-Check, DNS-Server, Android-Hotspot, IPv6, Logfile-Rotation
# Autor: github.com/Onslaught2508/netcheck
# Lizenz: MIT
# Ausführung: powershell -ExecutionPolicy Bypass -File netcheck.ps1
# ============================================================
#Requires -Version 5.1

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
    param(
        [string[]]$NetshLines,
        [string]$Pattern
    )

    $matchingLine = $NetshLines | Select-String $Pattern | Select-Object -First 1
    if (-not $matchingLine) { return "" }

    return ($matchingLine.Line -replace "^.*?:\s*", "").Trim()
}

function Get-LinkSpeedMbit {
    param($NetworkAdapter)

    $linkSpeedRaw = $NetworkAdapter.LinkSpeed

    if ($linkSpeedRaw -is [long] -or $linkSpeedRaw -is [int] -or $linkSpeedRaw -is [uint64]) {
        return [math]::Round($linkSpeedRaw / 1MB, 0)
    }

    $linkSpeedText = "$linkSpeedRaw".Trim()

    if ($linkSpeedText -match '([\d.]+)\s*(G|Gbps|Gbit)') {
        return [math]::Round([double]$Matches[1] * 1000, 0)
    }

    if ($linkSpeedText -match '([\d.]+)\s*(M|Mbps|Mbit)') {
        return [math]::Round([double]$Matches[1], 0)
    }

    if ($linkSpeedText -match '([\d.]+)\s*(K|Kbps|Kbit)') {
        return [math]::Round([double]$Matches[1] / 1000, 0)
    }

    return $null
}

function Invoke-LogRotation {
    param([string]$LogDirectory)

    $netcheckLogs = Get-ChildItem -Path $LogDirectory -Filter "netcheck_*.log" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending

    if ($netcheckLogs.Count -lt 5) { return }

    $netcheckLogs | Select-Object -Skip 4 | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Info "Altes Logfile gelöscht: $($_.Name)"
    }
}

$DesktopPath = [System.Environment]::GetFolderPath('Desktop')
$LogFile = Join-Path $DesktopPath "netcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

Write-Host " Windows Netzwerk-Diagnose v2.3.1 | $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host ""

function Get-DefaultGateway {
    $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                    Sort-Object RouteMetric |
                    Select-Object -First 1

    if ($defaultRoute) { return $defaultRoute.NextHop }
    return $null
}

function Detect-ConnectionType {
    $script:HasWifi = $false
    $script:HasEthernet = $false
    $script:IsHotspot = $false
    $script:HotspotType = ""
    $script:WifiAdapter = $null
    $script:EthernetAdapter = $null

    $activeNetworkAdapters = Get-NetAdapter -ErrorAction SilentlyContinue |
                             Where-Object { $_.Status -eq 'Up' }

    foreach ($networkAdapter in $activeNetworkAdapters) {
        $isVirtualAdapter = $networkAdapter.Name -like '*vEthernet*' -or
                            $networkAdapter.InterfaceDescription -like '*Virtual*' -or
                            $networkAdapter.InterfaceDescription -like '*Hyper-V*'

        if ($isVirtualAdapter) { continue }

        $isWifiAdapter = $networkAdapter.PhysicalMediaType -eq 'Native 802.11' -or
                         $networkAdapter.InterfaceDescription -like '*Wi-Fi*' -or
                         $networkAdapter.InterfaceDescription -like '*Wireless*' -or
                         $networkAdapter.Name -like '*Wi-Fi*' -or
                         $networkAdapter.Name -like '*WLAN*'

        $isEthernetAdapter = $networkAdapter.PhysicalMediaType -eq '802.3' -or
                             $networkAdapter.InterfaceDescription -like '*Ethernet*' -or
                             $networkAdapter.Name -like '*Ethernet*' -or
                             $networkAdapter.Name -like '*LAN*'

        if ($isWifiAdapter) {
            $script:HasWifi = $true
            $script:WifiAdapter = $networkAdapter
            Test-HotspotConnection $networkAdapter
            continue
        }

        if ($isEthernetAdapter) {
            $script:HasEthernet = $true
            $script:EthernetAdapter = $networkAdapter
        }
    }
}

function Test-HotspotConnection {
    param($WifiAdapter)

    $wifiIpv4Address = (Get-NetIPAddress -InterfaceIndex $WifiAdapter.InterfaceIndex `
                        -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Select-Object -First 1).IPAddress

    if ($wifiIpv4Address -like '172.20.10.*') {
        $script:IsHotspot = $true
        $script:HotspotType = "iOS"
        return
    }

    if ($wifiIpv4Address -like '192.168.43.*') {
        $script:IsHotspot = $true
        $script:HotspotType = "Android"
        return
    }

    if ($wifiIpv4Address -notlike '192.168.0.*' -and $wifiIpv4Address -notlike '192.168.1.*') {
        return
    }

    $ssidLine = netsh wlan show interfaces 2>$null |
                Select-String 'SSID\s+:' |
                Select-Object -First 1

    if ($ssidLine -match 'Hotspot|Phone|Android|Pixel|Samsung|Huawei|Xiaomi') {
        $script:IsHotspot = $true
        $script:HotspotType = "Android (vermutet)"
    }
}

function Test-Iperf3Availability {
    if (Get-Command iperf3 -ErrorAction SilentlyContinue) {
        Write-Ok "iperf3 verfügbar"
        return $true
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "iperf3 nicht gefunden und winget nicht verfügbar"
        Write-Info "Manuell installieren: winget install iperf3.iperf3"
        return $false
    }

    $installedWingetPackage = winget list --id iperf3.iperf3 -e 2>$null

    if ($installedWingetPackage -match 'iperf3') {
        Write-Warn "iperf3 installiert, aber in dieser PowerShell-Session nicht im PATH"
        Write-Info "PowerShell schließen und neu öffnen, dann ist iperf3 verfügbar"
        return $false
    }

    Write-Warn "iperf3 nicht gefunden – Installationsversuch via winget..."

    winget install --id iperf3.iperf3 -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null

    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = "$machinePath;$userPath"

    if (Get-Command iperf3 -ErrorAction SilentlyContinue) {
        Write-Ok "iperf3 verfügbar nach Installation"
        return $true
    }

    Write-Warn "iperf3 installiert – PowerShell neu starten, dann verfügbar"
    return $false
}

function Check-Dependencies {
    Write-Header "🔍 Abhängigkeiten prüfen"

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Ok "winget verfügbar"
    } else {
        Write-Warn "winget nicht gefunden"
    }

    $script:Iperf3Available = Test-Iperf3Availability

    Write-Ok "ping, tracert, nslookup: Windows-Boardmittel vorhanden"
}

function Get-SystemInfo {
    Write-Header "💻 System-Info"

    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    Write-Info "Hostname:   $env:COMPUTERNAME"

    if ($operatingSystem) {
        Write-Info "OS:         $($operatingSystem.Caption) Build $($operatingSystem.BuildNumber)"
    } else {
        Write-Info "OS:         Windows"
    }

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
                           Where-Object {
                               $_.IPAddress -notlike '127.*' -and
                               $_.IPAddress -notlike '169.254.*'
                           }

    foreach ($ipv4Address in $activeIpv4Addresses) {
        Write-Info ("  {0,-20} IPv4: {1}" -f $ipv4Address.InterfaceAlias, $ipv4Address.IPAddress)
    }

    Write-Host ""
    Write-Info "IPv6-Adressen:"

    $globalIpv6Addresses = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                           Where-Object {
                               $_.IPAddress -notlike '::1' -and
                               $_.IPAddress -notlike 'fe80*'
                           }

    if ($globalIpv6Addresses) {
        foreach ($ipv6Address in $globalIpv6Addresses) {
            Write-Info ("  {0,-20} {1}" -f $ipv6Address.InterfaceAlias, $ipv6Address.IPAddress)
        }

        Write-Ok "Globale IPv6-Adresse vorhanden (Dual-Stack aktiv)"
    } else {
        $linkLocalIpv6Addresses = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                                  Where-Object { $_.IPAddress -like 'fe80*' }

        if ($linkLocalIpv6Addresses) {
            Write-Warn "Nur Link-Local IPv6 (fe80::) – kein Dual-Stack"
        } else {
            Write-Warn "Kein IPv6 konfiguriert"
        }
    }

    Write-Host ""

    $script:DefaultGateway = Get-DefaultGateway

    if ($script:DefaultGateway) {
        Write-Info "Standard-Gateway: $script:DefaultGateway"
    } else {
        Write-Warn "Standard-Gateway nicht ermittelbar"
    }
}

function Test-Gateway {
    Write-Header "🚪 Gateway-Erreichbarkeit"

    $defaultGateway = $script:DefaultGateway
    if (-not $defaultGateway) { $defaultGateway = Get-DefaultGateway }

    if (-not $defaultGateway) {
        Write-Fail "Kein Standard-Gateway gefunden"
        return
    }

    Write-Info "Pinge Gateway: $defaultGateway"

    $gatewayRespondsToIcmp = Test-Connection -ComputerName $defaultGateway -Count 2 -Quiet `
                            -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    if ($gatewayRespondsToIcmp) {
        Write-GatewayIcmpDetails $defaultGateway
        return
    }

    $reachableTcpPort = Test-GatewayTcpFallback $defaultGateway

    if ($reachableTcpPort) {
        Write-Ok "Gateway $defaultGateway erreichbar via TCP Port $reachableTcpPort"
        Write-Info "Hinweis: ICMP wird vermutlich durch Router/Firewall blockiert"
        return
    }

    $internetReachable = Test-NetConnection -ComputerName "1.1.1.1" -Port 443 `
                         -InformationLevel Quiet `
                         -WarningAction SilentlyContinue `
                         -ErrorAction SilentlyContinue

    if ($internetReachable) {
        Write-Warn "Gateway $defaultGateway antwortet nicht auf ICMP/TCP – Internet aber erreichbar"
        Write-Info "Hinweis: Router/Firewall blockiert lokale Diagnosepakete – kein lokaler Ausfall"
        return
    }

    Write-Fail "Gateway $defaultGateway nicht erreichbar – lokales Netzwerkproblem wahrscheinlich"
}

function Write-GatewayIcmpDetails {
    param([string]$DefaultGateway)

    $gatewayPingSamples = Test-Connection -ComputerName $DefaultGateway -Count 4 `
                          -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

    if (-not $gatewayPingSamples) {
        Write-Ok "Gateway $DefaultGateway erreichbar via ICMP"
        return
    }

    $averageGatewayLatencyMs = [math]::Round(
        ($gatewayPingSamples | Measure-Object -Property ResponseTime -Average).Average,
        1
    )

    $lostGatewayPackets = 4 - $gatewayPingSamples.Count

    if ($lostGatewayPackets -eq 0) {
        Write-Ok "Gateway $DefaultGateway erreichbar via ICMP – kein Paketverlust"
    } else {
        Write-Warn "Gateway $DefaultGateway erreichbar via ICMP – Paketverlust: $lostGatewayPackets/4 Pakete"
    }

    Write-Info "Latenz zum Gateway: $averageGatewayLatencyMs ms"

    if ($averageGatewayLatencyMs -gt 10) {
        Write-Warn "Latenz > 10 ms – lokale Verbindung prüfen"
    }
}

function Test-GatewayTcpFallback {
    param([string]$DefaultGateway)

    foreach ($gatewayPort in @(53, 80, 443)) {
        $gatewayTcpReachable = Test-NetConnection -ComputerName $DefaultGateway -Port $gatewayPort `
                               -InformationLevel Quiet `
                               -WarningAction SilentlyContinue `
                               -ErrorAction SilentlyContinue

        if ($gatewayTcpReachable) { return $gatewayPort }
    }

    return $null
}

function Show-DnsServers {
    Write-Header "🔎 DNS-Konfiguration"
    Write-Info "Konfigurierte DNS-Server:"

    $configuredDnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                            Where-Object { $_.ServerAddresses.Count -gt 0 }

    if (-not $configuredDnsServers) {
        Write-Warn "Keine DNS-Server ermittelbar"
        return
    }

    foreach ($dnsClientEntry in $configuredDnsServers) {
        foreach ($dnsServerAddress in $dnsClientEntry.ServerAddresses) {
            $providerLabel = switch -Wildcard ($dnsServerAddress) {
                '8.8.8.8'   { '← Google DNS' }
                '8.8.4.4'   { '← Google DNS' }
                '1.1.1.1'   { '← Cloudflare DNS' }
                '1.0.0.1'   { '← Cloudflare DNS' }
                '9.9.9.9'   { '← Quad9 DNS' }
                '192.168.*' { '← Lokaler/Router-DNS' }
                '10.*'      { '← Lokaler/Router-DNS' }
                '172.16.*'  { '← Lokaler/Router-DNS' }
                '172.17.*'  { '← Lokaler/Router-DNS' }
                '172.18.*'  { '← Lokaler/Router-DNS' }
                '172.19.*'  { '← Lokaler/Router-DNS' }
                '172.2?.*'  { '← Lokaler/Router-DNS' }
                '172.30.*'  { '← Lokaler/Router-DNS' }
                '172.31.*'  { '← Lokaler/Router-DNS' }
                default     { '' }
            }

            Write-Info ("  {0,-18} {1}  {2}" -f $dnsClientEntry.InterfaceAlias, $dnsServerAddress, $providerLabel)
        }
    }
}

function Get-WifiInfo {
    if (-not $script:HasWifi) { return }

    Write-Header "📶 WLAN-Details"

    $wlanInterfaceLines = netsh wlan show interfaces 2>$null

    if (-not $wlanInterfaceLines) {
        Write-Warn "netsh wlan nicht verfügbar"
        return
    }

    $ssid = Get-WlanField $wlanInterfaceLines 'SSID\s+:'
    $radioType = Get-WlanField $wlanInterfaceLines 'Radio type'
    $wifiChannel = Get-WlanField $wlanInterfaceLines 'Channel'
    $signalQuality = Get-WlanField $wlanInterfaceLines 'Signal'
    $receiveRate = Get-WlanField $wlanInterfaceLines 'Receive rate'
    $transmitRate = Get-WlanField $wlanInterfaceLines 'Transmit rate'

    if ($ssid)          { Write-Info "SSID:          $ssid" }
    if ($radioType)     { Write-Info "Standard:      $radioType" }
    if ($wifiChannel)   { Write-Info "Kanal:         $wifiChannel" }
    if ($receiveRate)   { Write-Info "Empfangsrate:  $receiveRate Mbps" }
    if ($transmitRate)  { Write-Info "Senderate:     $transmitRate Mbps" }

    if (-not $signalQuality) { return }

    $signalPercent = [int]($signalQuality -replace '[^0-9]', '')

    Write-Info "Signal:        $signalQuality"

    if ($signalPercent -ge 80) {
        Write-Ok "Signalqualität gut (≥ 80 %)"
    } elseif ($signalPercent -ge 50) {
        Write-Warn "Signalqualität mäßig (50–79 %)"
    } else {
        Write-Fail "Signalqualität schlecht (< 50 %)"
    }
}

function Get-EthernetInfo {
    if (-not $script:HasEthernet) { return }

    Write-Header "🔗 Ethernet-Details"

    $ethernetAdapter = $script:EthernetAdapter

    Write-Info "Adapter: $($ethernetAdapter.Name) – $($ethernetAdapter.InterfaceDescription)"

    $linkSpeedMbit = Get-LinkSpeedMbit $ethernetAdapter

    if ($linkSpeedMbit) {
        Write-Info "Geschwindigkeit: $linkSpeedMbit Mbit/s"
    }

    if ($ethernetAdapter.FullDuplex -eq $false) {
        Write-Warn "Half-Duplex erkannt"
    } else {
        Write-Ok "Full-Duplex"
    }
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

        if (-not $pingSamples) {
            Write-Fail "$($latencyTarget.Label) ($($latencyTarget.Host)) – nicht erreichbar"
            continue
        }

        $averageLatencyMs = [math]::Round(
            ($pingSamples | Measure-Object -Property ResponseTime -Average).Average,
            1
        )

        if ($averageLatencyMs -lt 20) {
            Write-Ok "$($latencyTarget.Label): $averageLatencyMs ms"
        } elseif ($averageLatencyMs -lt 60) {
            Write-Warn "$($latencyTarget.Label): $averageLatencyMs ms (erhöht)"
        } else {
            Write-Fail "$($latencyTarget.Label): $averageLatencyMs ms (hoch)"
        }
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

        if ($dnsResolutionMs -lt 100) {
            Write-Ok "${domainName}: $dnsResolutionMs ms"
        } elseif ($dnsResolutionMs -lt 250) {
            Write-Warn "${domainName}: $dnsResolutionMs ms (erhöht)"
        } else {
            Write-Fail "${domainName}: $dnsResolutionMs ms (hoch)"
        }
    }
}

function Invoke-Traceroute {
    Write-Header "🗺 Traceroute (→ 8.8.8.8, max. 15 Hops)"

    if ($script:IsHotspot) {
        Write-Warn "Hotspot aktiv – viele * * * Zeilen sind normal"
    }

    tracert -h 15 8.8.8.8 2>$null
}

function Test-Bandwidth {
    Write-Header "📊 Bandbreiten-Test (iperf3)"

    if (-not (Get-Command iperf3 -ErrorAction SilentlyContinue)) {
        Write-Warn "iperf3 nicht verfügbar – übersprungen"
        return
    }

    if ($script:IsHotspot) {
        Write-Warn "Hotspot aktiv – Bandbreite durch Mobilfunk begrenzt"
    }

    $iperfServers = @(
        @{ Host = 'speedtest.serverius.net';     Port = 5002 },
        @{ Host = 'speedtest.ams1.novogara.net'; Port = 5201 },
        @{ Host = 'iperf.online.net';            Port = 5209 },
        @{ Host = 'bouygues.testdebit.info';     Port = 5209 },
        @{ Host = 'iperf.he.net';                Port = 5201 }
    )

    foreach ($iperfServer in $iperfServers) {
        Write-Info "Teste Server: $($iperfServer.Host):$($iperfServer.Port)"

        $iperfJob = Start-Job -ScriptBlock {
            param($ServerHost, $ServerPort)
            iperf3 -c $ServerHost -p $ServerPort -t 5 --connect-timeout 4000 2>&1
        } -ArgumentList $iperfServer.Host, $iperfServer.Port

        $iperfCompleted = Wait-Job $iperfJob -Timeout 15

        if (-not $iperfCompleted) {
            Stop-Job $iperfJob -ErrorAction SilentlyContinue
            Remove-Job $iperfJob -Force -ErrorAction SilentlyContinue
            Write-Warn "  → Timeout"
            continue
        }

        $iperfOutput = Receive-Job $iperfJob -ErrorAction SilentlyContinue
        Remove-Job $iperfJob -Force -ErrorAction SilentlyContinue

        if ($iperfOutput -match 'error|unable|refused|failed|busy') {
            Write-Warn "  → Nicht erreichbar"
            continue
        }

        if ($iperfOutput -match 'sender|receiver') {
            $iperfOutput |
                Where-Object { $_ -match 'sender|receiver|Mbits|Gbits' } |
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
