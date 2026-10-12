<#
.SYNOPSIS
    Instala o GoLiveFix no Windows do zero.

.DESCRIPTION
    1. Instala o que faltar: WireGuard, Git, Node.js LTS (via winget) e pnpm.
    2. Prepara o seu .conf do WireGuard (sem DNS, Table = off, PostUp com a
       rota de métrica 9000), instala como o túnel "golivefix" e confere se ele
       funciona. Esta é a única parte que pede administrador (uma janela do UAC).
    3. Baixa e compila o Vencord com o plugin e injeta no Discord.

    Pode rodar de novo quando quiser: o .conf é pedido de novo e o túnel
    reinstalado com ele, o que já está instalado é pulado, e o plugin é copiado
    e compilado de novo (serve para atualizar).

.PARAMETER Conf
    O .conf do WireGuard (ProtonVPN etc.). Sem ele, abre uma janela para
    escolher o arquivo. O túnel "golivefix" é sempre instalado de novo com ele.

.PARAMETER VencordDir
    Onde fica o código do Vencord. Padrão: a pasta Vencord ao lado deste
    script (ignorada pelo git). O Discord carrega o Vencord dela: não apague.

.PARAMETER Branch
    Qual Discord injetar: stable, ptb ou canary.

.PARAMETER EnterOnStartup
    Liga a opção do plugin "Entrar no túnel ao abrir o Discord": abrir pelo
    atalho já entra no túnel, sem clicar no escudo.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -Conf "$HOME\Downloads\BR-1.conf"
#>
param(
    [string]$Conf,
    [string]$VencordDir = (Join-Path $PSScriptRoot "Vencord"),
    [ValidateSet("stable", "ptb", "canary")][string]$Branch = "stable",
    [switch]$SkipTunnel,
    [switch]$SkipVencord,
    [switch]$EnterOnStartup,

    # Internal: the elevated half, started by this script through UAC.
    [string]$ElevatedInstall,
    [switch]$ElevatedRoute,
    [string]$LogFile
)

$ErrorActionPreference = "Stop"

# Must match TUNNEL_ADAPTER in tunnel-windows.ts.
$TunnelName = "golivefix"
$RouteCommand = "netsh interface ipv4 add route 0.0.0.0/0 $TunnelName metric=9000 store=active"
$WgDir = Join-Path $env:ProgramFiles "WireGuard"
$WgExe = Join-Path $WgDir "wireguard.exe"
$WgService = "WireGuardTunnel`$$TunnelName"
# Install folder, process and exe name of the Discord to inject.
$DiscordName = @{ stable = "Discord"; ptb = "DiscordPTB"; canary = "DiscordCanary" }[$Branch]
$DiscordStarted = $false

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok([string]$m) { Write-Host "    $m" -ForegroundColor Green }
function Info([string]$m) { Write-Host "    $m" }
function Warn([string]$m) { Write-Host "    $m" -ForegroundColor Yellow }

function Ask([string]$question) {
    $a = Read-Host "    $question (S/n)"
    return $a -eq "" -or $a -match '^[sSyY]'
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
}

function Invoke-Native([string]$what, [scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$what falhou (código $LASTEXITCODE)" }
}

# --- WireGuard config ------------------------------------------------------

<#
 Rewrites a WireGuard config for GoLiveFix:
 - drops DNS (else Windows sends the whole PC's DNS to the VPN's resolver),
   Table and any scripts;
 - adds Table = off (the PC itself never routes through the tunnel) and a
   PostUp that gives the tunnel a catch-all route at a metric nothing picks,
   so only sockets bound to the tunnel address use it;
 - splits /0 AllowedIPs into /1 halves: WireGuard turns on its kill-switch
   (blocks everything outside the tunnel) for a single peer with a /0.
#>
function Convert-WgConf([string]$text) {
    $out = New-Object System.Collections.Generic.List[string]
    $section = ""
    $hasInterface = $false; $hasV4 = $false; $peers = 0; $catchAll = $false
    foreach ($line in ($text -split "\r?\n")) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim().ToLower()
            $out.Add($line)
            if ($section -eq "interface") {
                $hasInterface = $true
                $out.Add("Table = off")
                $out.Add("PostUp = $RouteCommand")
            }
            if ($section -eq "peer") { $peers++ }
            continue
        }
        if ($section -eq "interface") {
            if ($t -match '^(DNS|Table|PreUp|PostUp|PreDown|PostDown)\s*=') { continue }
            if ($t -match '^Address\s*=\s*(.*)$' -and $Matches[1] -match '\d+\.\d+\.\d+\.\d+') { $hasV4 = $true }
        }
        if ($section -eq "peer" -and $t -match '^AllowedIPs\s*=\s*(.*)$') {
            $ips = foreach ($ip in ($Matches[1] -split '\s*,\s*' | Where-Object { $_ })) {
                switch ($ip) {
                    "0.0.0.0/0" { "0.0.0.0/1"; "128.0.0.0/1" }
                    "::/0" { "::/1"; "8000::/1" }
                    default { $ip }
                }
            }
            if ($ips -contains "0.0.0.0/1") { $catchAll = $true }
            $out.Add("AllowedIPs = " + ($ips -join ", "))
            continue
        }
        $out.Add($line)
    }
    if (-not $hasInterface) { throw "isso não parece um config WireGuard (falta [Interface])" }
    if (-not $hasV4) { throw "o config não tem Address IPv4" }
    if ($peers -ne 1) { throw "o config precisa ter exatamente um [Peer] (tem $peers)" }
    if (-not $catchAll) { throw "o AllowedIPs do [Peer] precisa cobrir tudo (0.0.0.0/0)" }
    return ($out -join "`r`n")
}

# --- elevated half -----------------------------------------------------------

function Log([string]$m) {
    Write-Host $m
    if ($LogFile) { Add-Content -Path $LogFile -Value $m -Encoding UTF8 }
}

function Wait-Until([int]$seconds, [scriptblock]$cond) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $cond) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return [bool](& $cond)
}

function Start-Wg([string[]]$wgArgs) {
    # Start-Process joins arguments with spaces without quoting them, and the
    # config lives under "Program Files".
    $quoted = $wgArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    $p = Start-Process -FilePath $WgExe -ArgumentList ($quoted -join " ") -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw "wireguard $($wgArgs -join ' ') falhou (código $($p.ExitCode))" }
}

function Get-TunnelRoute {
    Get-NetRoute -InterfaceAlias $TunnelName -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
}

function Get-TunnelAddress {
    Get-NetIPAddress -InterfaceAlias $TunnelName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
}

# Starting or running. A tunnel that fails stops and the manager removes it.
function Test-TunnelServiceAlive {
    $s = Get-Service $WgService -ErrorAction SilentlyContinue
    return [bool]($s -and $s.Status -ne "Stopped")
}

<#
 Waits for the tunnel adapter to get its address. The first tunnel on a PC
 also installs WireGuard's driver, which can take well over 20 s, so this
 waits long and only gives up early if the service stops.
#>
function Wait-TunnelUp([int]$seconds) {
    [void](Wait-Until $seconds { (Get-TunnelAddress) -or -not (Test-TunnelServiceAlive) })
    return Get-TunnelAddress
}

function Install-TunnelElevated([string]$confPath) {
    if (-not (Test-Path $WgExe)) { throw "WireGuard não encontrado em $WgDir" }

    # The PostUp only runs with this set. Scripts run as SYSTEM, but only
    # administrators can add tunnel configs, so this opens nothing to users.
    Invoke-Native "habilitar scripts no WireGuard" { reg.exe add HKLM\Software\WireGuard /v DangerousScriptExecution /t REG_DWORD /d 1 /f | Out-Null }
    Log "scripts do WireGuard habilitados"

    # The manager encrypts configs dropped into its store; the UI starts it,
    # but on a fresh install it may not be running yet.
    $mgr = Get-Service WireGuardManager -ErrorAction SilentlyContinue
    if (-not $mgr) {
        Start-Wg @("/installmanagerservice")
    } elseif ($mgr.Status -ne "Running") {
        Start-Service WireGuardManager
    }
    if (-not (Wait-Until 20 { (Get-Service WireGuardManager -ErrorAction SilentlyContinue).Status -eq "Running" })) {
        throw "o serviço do WireGuard não iniciou"
    }

    if (Get-Service $WgService -ErrorAction SilentlyContinue) {
        Start-Wg @("/uninstalltunnelservice", $TunnelName)
        if (-not (Wait-Until 20 { -not (Get-Service $WgService -ErrorAction SilentlyContinue) })) {
            throw "não foi possível parar o túnel $TunnelName antigo"
        }
        Log "túnel $TunnelName antigo removido"
    }

    $store = Join-Path $WgDir "Data\Configurations"
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    $dpapi = Join-Path $store "$TunnelName.conf.dpapi"
    Remove-Item (Join-Path $store "$TunnelName.conf"), $dpapi -ErrorAction SilentlyContinue
    Copy-Item $confPath (Join-Path $store "$TunnelName.conf")
    if (-not (Wait-Until 20 { Test-Path $dpapi })) { throw "o WireGuard não importou o config" }
    Log "config importado no WireGuard como $TunnelName"

    # Same as "Ativar" in the UI: an auto-start service, back after a reboot.
    Start-Wg @("/installtunnelservice", $dpapi)
    if (-not (Wait-TunnelUp 120)) {
        throw "o túnel $TunnelName não subiu; veja o log no app do WireGuard"
    }
    Log "túnel $TunnelName ativo"

    if (Wait-Until 10 { Get-TunnelRoute }) {
        Log "rota do túnel criada pelo PostUp"
    } else {
        Add-RouteElevated
        Log "AVISO: o PostUp não criou a rota; ela foi criada agora, mas ela some quando o túnel for desativado"
    }
}

function Add-RouteElevated {
    if (Get-TunnelRoute) { Log "rota do túnel já existe"; return }
    Invoke-Native "criar a rota do túnel" { cmd.exe /c $RouteCommand | Out-Null }
    Log "rota do túnel criada"
}

# Runs this script again as administrator for one task, then prints what it logged.
function Invoke-Elevated([string[]]$taskArgs) {
    $log = Join-Path $env:TEMP "golivefix-setup-$PID.log"
    Remove-Item $log -ErrorAction SilentlyContinue
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-LogFile", "`"$log`"") + $taskArgs
    Info "pedindo permissão de administrador (janela do UAC)..."
    try {
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
    } catch {
        throw "permissão de administrador negada"
    }
    $lines = @(Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue)
    Remove-Item $log -ErrorAction SilentlyContinue
    foreach ($l in $lines) {
        if ($l -eq "__OK__") { continue }
        if ($l -like "ERRO:*" -or $l -like "AVISO:*") { Warn $l } else { Info $l }
    }
    if (-not ($lines -contains "__OK__")) { throw "a parte de administrador falhou (veja acima)" }
}

# --- user half -------------------------------------------------------------

function Install-Prereqs {
    Step "Programas"
    $winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    $wanted = @(
        @{ Name = "WireGuard"; Id = "WireGuard.WireGuard"; Present = { Test-Path $WgExe } },
        @{ Name = "Git"; Id = "Git.Git"; Present = { Get-Command git -ErrorAction SilentlyContinue } },
        @{ Name = "Node.js"; Id = "OpenJS.NodeJS.LTS"; Present = { Get-Command node -ErrorAction SilentlyContinue } }
    )
    foreach ($w in $wanted) {
        if ($SkipTunnel -and $w.Name -eq "WireGuard") { continue }
        if ($SkipVencord -and $w.Name -ne "WireGuard") { continue }
        if (& $w.Present) { Ok "$($w.Name): já instalado"; continue }
        if (-not $winget) { throw "$($w.Name) não está instalado e o winget não existe aqui; instale o $($w.Name) e rode de novo" }
        Info "instalando $($w.Name)..."
        Invoke-Native "instalar $($w.Name)" { winget install --id $w.Id -e --silent --accept-package-agreements --accept-source-agreements }
        Refresh-Path
        if (-not (& $w.Present)) { throw "$($w.Name) instalado, mas não encontrado; abra um terminal novo e rode de novo" }
        Ok "$($w.Name): instalado"
    }
    if (-not $SkipVencord) {
        if (Get-Command pnpm -ErrorAction SilentlyContinue) {
            Ok "pnpm: já instalado"
        } else {
            Info "instalando pnpm..."
            Invoke-Native "instalar pnpm" { npm install -g pnpm }
            Refresh-Path
            if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { throw "pnpm instalado, mas não encontrado; abra um terminal novo e rode de novo" }
            Ok "pnpm: instalado"
        }
    }
}

function Select-ConfFile {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Escolha o config WireGuard (.conf) para o GoLiveFix"
    $dlg.Filter = "Config WireGuard (*.conf)|*.conf|Todos os arquivos (*.*)|*.*"
    $dlg.InitialDirectory = Join-Path $HOME "Downloads"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw "nenhum config escolhido" }
    return $dlg.FileName
}

function Setup-Tunnel {
    Step "Túnel WireGuard ($TunnelName)"
    if (-not $Conf) {
        Info "escolha o .conf baixado do seu provedor de VPN (ex.: ProtonVPN, opção Windows)"
        $script:Conf = Select-ConfFile
    }
    if (-not (Test-Path $Conf)) { throw "config não encontrado: $Conf" }

    $prepared = Convert-WgConf (Get-Content $Conf -Raw)
    $tmpDir = Join-Path $env:TEMP "golivefix-setup"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmp = Join-Path $tmpDir "$TunnelName.conf"
    try {
        # Holds the private key: lives only until the elevated half imports it.
        [IO.File]::WriteAllText($tmp, $prepared + "`r`n")
        Ok "config preparado a partir de $(Split-Path $Conf -Leaf)"
        Invoke-Elevated @("-ElevatedInstall", "`"$tmp`"")
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

function Test-Tunnel {
    Step "Conferindo o túnel"
    $addr = Get-TunnelAddress
    if (-not $addr -and (Test-TunnelServiceAlive)) {
        Info "esperando o túnel subir..."
        $addr = Wait-TunnelUp 60
    }
    if (-not $addr) { throw "o túnel $TunnelName não está ativo; ative no app do WireGuard e rode de novo" }
    Ok "túnel ativo, endereço $($addr.IPAddress)"

    $route = Get-TunnelRoute
    if (-not $route) {
        Warn "falta a rota 0.0.0.0/0 no túnel (o PostUp não rodou)"
        if (-not (Ask "Criar a rota agora? Ela some quando o túnel for desativado")) { throw "sem a rota, o Discord não sai pelo túnel" }
        Invoke-Elevated @("-ElevatedRoute")
        $route = Get-TunnelRoute
    }
    if ($route.RouteMetric -lt 1000) { Warn "a rota do túnel tem métrica $($route.RouteMetric); o PC inteiro pode estar saindo pela VPN" }
    else { Ok "rota do túnel com métrica $($route.RouteMetric)" }

    # -s keeps curl off stderr, which Windows PowerShell would turn into errors.
    $direct = curl.exe -s -4 --max-time 10 https://ifconfig.me
    # A tunnel that just came up may still be on its first handshake.
    $vpn = $null
    for ($i = 0; $i -lt 3 -and -not $vpn; $i++) {
        $vpn = curl.exe -s --max-time 10 --interface $addr.IPAddress https://ifconfig.me
    }
    $global:LASTEXITCODE = 0
    if (-not $vpn) { throw "nada passa pelo túnel; o servidor da VPN não responde ou o config está errado (veja o log no app do WireGuard)" }
    if ($direct -and $direct -eq $vpn) { Warn "o PC e o túnel saem pelo mesmo IP ($vpn): o PC inteiro está indo pela VPN?" }
    else { Ok "PC sai direto ($direct), o túnel sai pela VPN ($vpn)" }
}

<#
 Where the Discord install's Vencord loads from, or $null if not injected.
 A dev install (pnpm inject) swaps resources\app.asar for a tiny asar whose
 index.js is just require("<Vencord>\dist\patcher.js"); the real Discord asar
 is moved to _app.asar. Looks at the newest app-x.y.z, the one that runs.
#>
function Get-InjectedPatcher {
    $app = Get-ChildItem (Join-Path $env:LOCALAPPDATA $DiscordName) -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Name -replace '^app-', '') } | Select-Object -Last 1
    if (-not $app) { return $null }
    $asar = Get-Item (Join-Path $app.FullName "resources\app.asar") -ErrorAction SilentlyContinue
    if (-not $asar -or $asar.PSIsContainer -or $asar.Length -gt 64KB) { return $null }
    $text = [IO.File]::ReadAllText($asar.FullName)
    if ($text -match 'require\("((?:[^"\\]|\\.)+)"\)') { return $Matches[1] -replace '\\\\', '\' }
    return $null
}

function Setup-Vencord {
    Step "Vencord com o GoLiveFix"
    foreach ($f in "index.tsx", "native.ts", "windows-hook\version.dll") {
        if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { throw "rode este script de dentro da pasta do GoLiveFix (falta $f)" }
    }

    if (-not (Test-Path $VencordDir)) {
        Info "baixando o Vencord em $VencordDir..."
        Invoke-Native "baixar o Vencord" { git clone https://github.com/Vendicated/Vencord $VencordDir }
    } elseif (-not (Test-Path (Join-Path $VencordDir "package.json"))) {
        throw "$VencordDir existe mas não é o Vencord; use -VencordDir <outra pasta>"
    } else {
        Ok "Vencord já está em $VencordDir"
    }

    Push-Location $VencordDir
    try {
        Info "instalando dependências..."
        Invoke-Native "pnpm install" { pnpm install --frozen-lockfile }

        $dest = Join-Path $VencordDir "src\userplugins\GoLiveFix"
        # The Vencord checkout usually sits inside the plugin folder: skip it.
        robocopy $PSScriptRoot $dest /MIR /XD .git target node_modules $VencordDir /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "não foi possível copiar o plugin (robocopy $LASTEXITCODE)" }
        $global:LASTEXITCODE = 0
        Ok "plugin copiado"

        Info "compilando..."
        Invoke-Native "pnpm build" { pnpm build }
        Ok "compilado"

        $patcher = Join-Path (Resolve-Path $VencordDir).Path "dist\patcher.js"
        $current = Get-InjectedPatcher
        $needInject = $current -ne $patcher
        if ($current -and $needInject) { Info "o Discord carrega o Vencord de outra pasta ($(Split-Path (Split-Path $current))); ele vai passar a carregar desta" }

        # A Discord open from before this build runs the old plugin, and its
        # main-process half (native.ts) only loads at startup: Ctrl+R isn't
        # enough. Vencord also reads its settings only at startup and rewrites
        # them on any change, so enabling the plugin must happen while closed.
        $discord = Get-Process $DiscordName -ErrorAction SilentlyContinue
        if ($discord) {
            if (-not (Ask "O Discord precisa reiniciar para carregar o plugin (ele abre de novo sozinho). Reiniciar agora?")) {
                if ($needInject) { throw "feche o Discord (inclusive na bandeja) e rode de novo" }
                Warn "o plugin novo só vale depois de reiniciar o Discord; rode de novo com ele fechado para ativar o plugin"
                return
            }
            $discord | Stop-Process -Force
            if (-not (Wait-Until 15 { -not (Get-Process $DiscordName -ErrorAction SilentlyContinue) })) { throw "o Discord não fechou" }
        }

        if ($needInject) {
            Info "injetando no Discord ($Branch)..."
            Invoke-Native "injetar o Vencord" { node scripts\runInstaller.mjs -- --install -branch $Branch }
            if ((Get-InjectedPatcher) -ne $patcher) { throw "o instalador do Vencord não injetou no Discord ($Branch); veja a saída acima" }
            Ok "injetado"
        } else {
            Ok "Vencord já injetado no Discord ($Branch)"
        }
    } finally {
        Pop-Location
    }

    $values = @{ enabled = $true }
    if ($EnterOnStartup) { $values.enterOnStartup = $true }
    $changed = Set-PluginSettings $values
    if ($changed) { Ok "GoLiveFix ativado nas configurações do Vencord ($($changed -join ', '))" }
    else { Ok "GoLiveFix já estava ativado" }

    Start-Process (Join-Path $env:LOCALAPPDATA "$DiscordName\Update.exe") -ArgumentList "--processStart $DiscordName.exe"
    $script:DiscordStarted = $true
    Ok "abrindo o Discord"
}

<#
 Sets GoLiveFix's entries in Vencord's settings.json (Discord must be closed)
 and returns the keys that changed. Done in node: Windows PowerShell's JSON
 round trip mangles arrays and deep objects.
#>
function Set-PluginSettings([hashtable]$values) {
    $file = Join-Path $env:APPDATA "Vencord\settings\settings.json"
    $js = Join-Path $env:TEMP "golivefix-settings-$PID.js"
    Set-Content -Path $js -Encoding ASCII -Value @'
const fs = require("fs"), path = require("path");
const [file, ...pairs] = process.argv.slice(2);
let s = {};
try { s = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { if (e.code !== "ENOENT") throw e; }
const p = ((s.plugins ??= {}).GoLiveFix ??= {});
const changed = [];
for (const pair of pairs) {
    const [k, v] = pair.split("=");
    const value = JSON.parse(v);
    if (p[k] !== value) { p[k] = value; changed.push(k); }
}
if (changed.length) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(s, null, 4));
}
console.log(changed.join(","));
'@
    try {
        # Plain key=value args: Windows PowerShell mangles quotes passed to native programs.
        $pairs = @($values.GetEnumerator() | ForEach-Object { "$($_.Key)=$("$($_.Value)".ToLower())" })
        $out = node $js $file @pairs
        if ($LASTEXITCODE -ne 0) { throw "não foi possível ativar o GoLiveFix nas configurações do Vencord ($file)" }
    } finally {
        Remove-Item $js -ErrorAction SilentlyContinue
    }
    return @("$out".Trim() -split "," | Where-Object { $_ })
}

function Main {
    if ($ElevatedInstall -or $ElevatedRoute) {
        try {
            if ($ElevatedInstall) { Install-TunnelElevated $ElevatedInstall } else { Add-RouteElevated }
            Log "__OK__"
            exit 0
        } catch {
            Log "ERRO: $($_.Exception.Message)"
            exit 1
        }
    }

    try {
        Install-Prereqs
        if (-not $SkipTunnel) { Setup-Tunnel; Test-Tunnel }
        if (-not $SkipVencord) { Setup-Vencord }
    } catch {
        Write-Host "`nERRO: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Step "Pronto"
    if ($DiscordStarted) { Info "O Discord está abrindo com o GoLiveFix ativo." }
    if ($EnterOnStartup) {
        Info "Ele entra no túnel sozinho ao abrir."
    } else {
        Info "Clique no escudo ao lado do microfone para o Discord entrar no túnel (na primeira vez, ele reinicia)."
        Info "O Discord sempre abre fora do túnel: clique no escudo uma vez a cada abertura."
        Info "(Ou rode de novo com -EnterOnStartup para ele entrar no túnel sozinho ao abrir.)"
    }
    if (-not $SkipVencord) { Info "Não apague nem mova ${VencordDir}: o Discord carrega o Vencord de lá." }
}

# Dot-sourcing (for tests) only loads the functions.
if ($MyInvocation.InvocationName -ne ".") { Main }
