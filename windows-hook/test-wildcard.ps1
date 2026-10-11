# Does real Discord hit the wildcard-bind gap? (a socket bound to 0.0.0.0,
# which the hook moves onto the tunnel IP, later used for a local destination)
#
#   .\test-wildcard.ps1 -Launch    close Discord first; installs the fresh DLL,
#                                  starts Discord in the tunnel with a net-log
#   .\test-wildcard.ps1 -Watch     while it runs: tunnel-bound TCP to local hosts
#   .\test-wildcard.ps1 -Analyze   after closing Discord: reads the net-log
#
# Launch bypasses the plugin on purpose (the DLL only needs the two env vars),
# so the mode is whatever -Mode writes to the state file.
param(
    [switch]$Launch, [switch]$Watch, [switch]$Analyze,
    [ValidateSet("arm", "keep", "disarm")][string]$Mode = "arm",
    [string]$TunnelIp = (Get-NetIPAddress -InterfaceAlias golivefix -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
)
$ErrorActionPreference = "Stop"
$work = Join-Path $env:TEMP "golivefix-wildcard-test"
$netlog = Join-Path $work "netlog.json"
$state = Join-Path $work "state"

function Is-Local([string]$ip) {
    # Net-log addresses carry a port ("1.2.3.4:443", "[::1]:443"); netstat's don't.
    $ip = $ip -replace '^\[(.*)\]:\d+$', '$1' -replace '^(\d+\.\d+\.\d+\.\d+):\d+$', '$1' -replace '^::ffff:', ''
    $a = [System.Net.IPAddress]::Parse($ip)
    if ($a.AddressFamily -eq "InterNetworkV6") { return $a.IsIPv6LinkLocal -or [System.Net.IPAddress]::IsLoopback($a) -or $ip -match '^f[cd]' }
    $b = $a.GetAddressBytes()
    return $b[0] -eq 127 -or $b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
           ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254) -or $b[0] -ge 224
}

if ($Launch) {
    if (-not $TunnelIp) { throw "no IPv4 on the 'golivefix' adapter; bring the tunnel up or pass -TunnelIp" }
    if (Get-Process Discord -ErrorAction SilentlyContinue) { throw "close Discord first (tray included)" }
    $app = Get-ChildItem "$env:LOCALAPPDATA\Discord" -Directory -Filter "app-*" | Sort-Object Name | Select-Object -Last 1
    Copy-Item (Join-Path $PSScriptRoot "version.dll") (Join-Path $app.FullName "version.dll") -Force
    New-Item -ItemType Directory -Force $work | Out-Null
    Remove-Item $netlog -ErrorAction SilentlyContinue
    Set-Content $state $Mode -NoNewline
    $env:GOLIVEFIX_TUNNEL_IP = $TunnelIp
    $env:GOLIVEFIX_STATE = $state
    Start-Process (Join-Path $app.FullName "Discord.exe") "--log-net-log=`"$netlog`" --net-log-capture-mode=Everything"
    "Discord started ($($app.Name), mode $Mode, tunnel $TunnelIp). Use it for a few minutes: switch servers,"
    "open channels with images/links you haven't opened before, join voice, watch a Go Live."
    "Then quit it from the tray (a clean exit finishes the net-log) and run -Analyze."
}

if ($Watch) {
    "Watching for TCP from $TunnelIp to local hosts (Ctrl+C to stop)..."
    while ($true) {
        $pids = (Get-Process Discord -ErrorAction SilentlyContinue).Id
        Get-NetTCPConnection -LocalAddress $TunnelIp -ErrorAction SilentlyContinue |
            Where-Object { $pids -contains $_.OwningProcess -and (Is-Local $_.RemoteAddress) } |
            ForEach-Object { "{0:HH:mm:ss} pid {1} {2}:{3} -> {4}:{5} {6}" -f (Get-Date), $_.OwningProcess, $_.LocalAddress, $_.LocalPort, $_.RemoteAddress, $_.RemotePort, $_.State }
        Start-Sleep -Milliseconds 500
    }
}

if ($Analyze) {
    $text = Get-Content $netlog -Raw
    # An unclean exit leaves the events array open; close it so it parses.
    if ($text.TrimEnd() -notmatch '\]\s*\}$') { $text = $text.TrimEnd().TrimEnd(',') + ']}' }
    $log = $text | ConvertFrom-Json
    $types = @{}; $log.constants.logEventTypes.PSObject.Properties | ForEach-Object { $types[[int]$_.Value] = $_.Name }
    $errs = @{}; $log.constants.netError.PSObject.Properties | ForEach-Object { $errs[[int]$_.Value] = $_.Name }
    $ev = $log.events

    $count = { param($name) @($ev | Where-Object { $types[[int]$_.type] -eq $name }).Count }
    "== Who resolves DNS"
    "  in-process (Chromium's own DNS client, exposed to the gap): {0} transactions" -f (& $count "DNS_TRANSACTION")
    "  system (getaddrinfo in Dnscache, outside Discord, safe):    {0} tasks" -f (& $count "HOST_RESOLVER_SYSTEM_TASK")

    "== Sockets to local destinations"
    $ev | Where-Object { $types[[int]$_.type] -in "TCP_CONNECT_ATTEMPT", "UDP_CONNECT" -and $_.params.address } |
        Where-Object { Is-Local $_.params.address } |
        Group-Object { "{0} {1}" -f $types[[int]$_.type], $_.params.address } |
        ForEach-Object { "  {0}x {1}" -f $_.Count, $_.Name }

    "== Errors that point at the gap"
    $suspect = "ERR_ADDRESS_INVALID", "ERR_ADDRESS_UNREACHABLE", "ERR_NAME_NOT_RESOLVED", "ERR_DNS_TIMED_OUT", "ERR_CONNECTION_TIMED_OUT", "ERR_NETWORK_ACCESS_DENIED"
    $ev | Where-Object { $_.params.net_error -and $errs[[int]$_.params.net_error] -in $suspect } |
        Group-Object { "{0} in {1}" -f $errs[[int]$_.params.net_error], $types[[int]$_.type] } |
        Sort-Object Count -Descending | ForEach-Object { "  {0}x {1}" -f $_.Count, $_.Name }
}

if (-not ($Launch -or $Watch -or $Analyze)) { Get-Help $PSCommandPath; "Pass -Launch, -Watch or -Analyze." }
