<#
.SYNOPSIS
    NET CHECK — снимок состояния сети без изменений в системе.

.DESCRIPTION
    Ничего не настраивает и не меняет. Просто измеряет:
      1) DNS по UDP/53 до всех DNS-серверов адаптеров и до публичных;
      2) TCP/443 напрямую по IP (без DNS) до ключевых узлов;
      3) DNS-over-HTTPS (порт 443) — работает ли резолвинг в обход UDP/53.

    Запускать при ВЫКЛЮЧЕННОМ VPN, затем при включённом — и сравнить.
    Отчёт пишется в netcheck-report.txt рядом со скриптом.
#>
[CmdletBinding()]
param()

try { $null = & "$env:SystemRoot\System32\chcp.com" 65001 } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$report = New-Object System.Collections.Generic.List[string]
function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    $report.Add($Text)
}

# ---------------------------------------------------------------- DNS по UDP/53
function Test-UdpDns {
    param([string]$Name = 'example.com', [string]$Server, [int]$TimeoutMs = 3000)

    $q = New-Object System.Collections.Generic.List[byte]
    $q.AddRange([byte[]](0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
    foreach ($p in $Name.Split('.')) {
        $q.Add([byte]$p.Length)
        $q.AddRange([Text.Encoding]::ASCII.GetBytes($p))
    }
    $q.Add(0)
    $q.AddRange([byte[]](0, 1, 0, 1))
    $bytes = $q.ToArray()

    $u = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $u = New-Object Net.Sockets.UdpClient
        $u.Client.ReceiveTimeout = $TimeoutMs
        $null = $u.Send($bytes, $bytes.Length, $Server, 53)
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $resp = $u.Receive([ref]$ep)
        $sw.Stop()
        $anc = [int]$resp[7] + ([int]$resp[6] -shl 8)
        $rcode = $resp[3] -band 0x0F
        return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds; Answers = $anc; Rcode = $rcode; Error = '' }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.ElapsedMilliseconds; Answers = 0; Rcode = -1; Error = 'timeout' }
    } finally {
        if ($u) { $u.Close() }
    }
}

# ---------------------------------------------------------------- TCP по IP
function Test-Tcp {
    param([string]$Target, [int]$Port = 443, [int]$TimeoutMs = 2500)
    $c = New-Object Net.Sockets.TcpClient
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($c.ConnectAsync($Target, $Port).Wait($TimeoutMs) -and $c.Connected) {
            $sw.Stop(); return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds }
        }
        $sw.Stop(); return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.ElapsedMilliseconds }
    } catch {
        $sw.Stop(); return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.ElapsedMilliseconds }
    } finally { $c.Dispose() }
}

function Test-Doh {
    param([string]$Url, [string]$Name = 'steamcommunity.com')
    try {
        $r = Invoke-RestMethod -Uri ("{0}?name={1}&type=A" -f $Url, $Name) `
            -Headers @{ accept = 'application/dns-json' } -TimeoutSec 8 -ErrorAction Stop
        $ips = @($r.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
        if ($ips.Count -gt 0) { return [pscustomobject]@{ Ok = $true; Ips = $ips; Error = '' } }
        return [pscustomobject]@{ Ok = $false; Ips = @(); Error = 'пустой ответ' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Ips = @(); Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------- вывод
Say ''
Say ('NET CHECK   {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'White'
Say ('Пользователь: {0}   Админ: {1}' -f $env:USERNAME, ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'DarkGray'
Say ('=' * 74) 'DarkCyan'

Say '' ; Say ' АДАПТЕРЫ (только активные)' 'Cyan'
$upAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
$adapterDns = New-Object System.Collections.Generic.List[string]
foreach ($a in $upAdapters) {
    $ip  = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    $gw  = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
    $dns = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
    $met = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
    Say ('  {0,-26} ip={1,-16} gw={2,-16} metric={3}' -f $a.Name, $ip, $gw, $met) 'Gray'
    Say ('  {0,-26} dns={1}' -f '', ($dns -join ', ')) 'DarkGray'
    foreach ($d in $dns) { if ($d -and -not $adapterDns.Contains($d)) { $adapterDns.Add($d) } }
}

Say '' ; Say ' МАРШРУТ ПО УМОЛЧАНИЮ' 'Cyan'
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    ForEach-Object { Say ('  {0,-26} via {1,-16} metric={2}' -f $_.InterfaceAlias, $_.NextHop, $_.InterfaceMetric) 'Gray' }

# --- 1. UDP/53
Say '' ; Say ' 1) DNS по UDP/53' 'Cyan'
$targets = @()
foreach ($d in $adapterDns) { $targets += $d }
foreach ($d in @('1.1.1.1', '8.8.8.8', '9.9.9.9', '77.88.8.8')) {
    if ($targets -notcontains $d) { $targets += $d }
}
$udpOk = 0
foreach ($s in $targets) {
    $r = Test-UdpDns -Server $s
    if ($r.Ok) {
        $udpOk++
        Say ('  {0,-16} ok    {1,5} мс   ответов: {2}' -f $s, $r.Ms, $r.Answers) 'Green'
    } else {
        Say ('  {0,-16} TIMEOUT        (сервер не ответил)' -f $s) 'Red'
    }
}

# --- 2. TCP/443 по IP
Say '' ; Say ' 2) TCP/443 напрямую по IP (DNS не участвует)' 'Cyan'
$tcpTargets = @(
    @{ Ip = '1.1.1.1';        Note = 'Cloudflare' }
    @{ Ip = '8.8.8.8';        Note = 'Google' }
    @{ Ip = '23.12.156.233';  Note = 'steamcommunity.com' }
    @{ Ip = '3.164.240.53';   Note = 'wbgames.com' }
)
$tcpOk = 0
foreach ($t in $tcpTargets) {
    $r = Test-Tcp -Target $t.Ip
    if ($r.Ok) {
        $tcpOk++
        Say ('  {0,-16}:443 ok    {1,5} мс   {2}' -f $t.Ip, $r.Ms, $t.Note) 'Green'
    } else {
        Say ('  {0,-16}:443 FAIL         {1}' -f $t.Ip, $t.Note) 'Red'
    }
}
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
if ($gw -and $gw -ne '0.0.0.0') {
    $r = Test-Tcp -Target $gw -Port 80
    Say ('  {0,-16}:80  {1}         шлюз' -f $gw, $(if ($r.Ok) { 'ok   ' } else { 'нет  ' })) 'DarkGray'
}

# --- 3. DoH
Say '' ; Say ' 3) DNS-over-HTTPS (порт 443) — резолвинг в обход UDP/53' 'Cyan'
$dohCf = Test-Doh -Url 'https://cloudflare-dns.com/dns-query'
Say ('  cloudflare-dns.com   {0}' -f $(if ($dohCf.Ok) { 'ok   -> ' + ($dohCf.Ips -join ', ') } else { 'FAIL -> ' + $dohCf.Error })) $(if ($dohCf.Ok) { 'Green' } else { 'Red' })
$dohGo = Test-Doh -Url 'https://dns.google/resolve'
Say ('  dns.google           {0}' -f $(if ($dohGo.Ok) { 'ok   -> ' + ($dohGo.Ips -join ', ') } else { 'FAIL -> ' + $dohGo.Error })) $(if ($dohGo.Ok) { 'Green' } else { 'Red' })

# --- 4. системный резолвинг
Say '' ; Say ' 4) Системный резолвинг (как видит Windows)' 'Cyan'
foreach ($h in @('steamcommunity.com', 'wbgames.com')) {
    try {
        $r = Resolve-DnsName $h -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        $ips = @($r | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
        Say ('  {0,-22} {1}' -f $h, ($ips -join ', ')) 'Green'
    } catch {
        Say ('  {0,-22} FAIL: {1}' -f $h, $_.Exception.Message) 'Red'
    }
}

# ---------------------------------------------------------------- итог
Say '' ; Say ('=' * 74) 'DarkCyan'
Say '' ; Say ' ВЕРДИКТ' 'Cyan'

if ($udpOk -eq 0 -and $tcpOk -eq 0) {
    Say '  Наружу не проходит ни DNS, ни TCP. Канал закрыт целиком.' 'Red'
    Say '  Причина не в DNS: это killswitch VPN, файрвол или нерабочий тетеринг.' 'Gray'
} elseif ($udpOk -eq 0 -and $tcpOk -gt 0) {
    Say '  TCP/443 работает, а UDP/53 — нет. Значит DNS режется, но HTTPS — нет.' 'Yellow'
    Say '  Вывод: DNS можно поднять через DoH (см. блок 3). Игры это не спасёт,' 'Gray'
    Say '  если блокировка серверов идёт по IP, но интернет без VPN заработает.' 'Gray'
} elseif ($udpOk -gt 0 -and $tcpOk -eq 0) {
    Say '  DNS отвечает, но TCP/443 наружу не идёт. Похоже на фильтрацию по IP.' 'Yellow'
    Say '  Вывод: смена DNS тут не поможет — нужен туннель.' 'Gray'
} else {
    Say '  Сеть в порядке: и DNS, и TCP работают.' 'Green'
    Say '  Если игра всё равно не пускает в онлайн — блокировка на стороне WB' 'Gray'
    Say '  (регион аккаунта/серверов), и решается только туннелем.' 'Gray'
}

Say '' ; Say (' Итог: UDP/53 ok {0} из {1}, TCP/443 ok {2} из {3}' -f $udpOk, $targets.Count, $tcpOk, $tcpTargets.Count) 'White'
Say ('=' * 74) 'DarkCyan'

$outFile = Join-Path (Split-Path -Parent $PSCommandPath) 'netcheck-report.txt'
try {
    $report | Set-Content -LiteralPath $outFile -Encoding UTF8
    Say ''
    Say (' Отчёт сохранён: {0}' -f $outFile) 'DarkGray'
} catch { }

if (-not [Console]::IsInputRedirected) {
    Say ''
    $null = Read-Host ' Enter — закрыть'
}
