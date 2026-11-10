<#
    MK1 ONLINE CHECK — почему не работают сетевые функции Mortal Kombat 1.
    Ничего не меняет. Запускать при включённом VPN и при выключенном.
#>
[CmdletBinding()]
param()

try { $null = & "$env:SystemRoot\System32\chcp.com" 65001 } catch { }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$api  = 'https://k1-api.wbagora.com'
$host_ = 'k1-api.wbagora.com'

Write-Host ''
Write-Host (' MK1 ONLINE CHECK   {0}' -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor White
Write-Host ('=' * 66) -ForegroundColor DarkCyan

# 1. откуда мы выходим в интернет
$cc = ''; $ip = ''; $org = ''
try {
    $r = Invoke-RestMethod -Uri 'https://ifconfig.co/json' -TimeoutSec 12 -ErrorAction Stop
    $ip = $r.ip; $cc = $r.country_iso; $org = $r.asn_org
    Write-Host (' 1) Выход в интернет: {0}  [{1}]  {2}' -f $ip, $cc, $org) -ForegroundColor $(if ($cc -eq 'RU') { 'Red' } else { 'Green' })
} catch {
    Write-Host (' 1) Выход в интернет: не определился ({0})' -f $_.Exception.Message) -ForegroundColor Yellow
}

# 2. куда резолвится API игры
try {
    $dns = @(Resolve-DnsName $host_ -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
        Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
    Write-Host (' 2) {0} -> {1}' -f $host_, ($dns -join ', ')) -ForegroundColor Gray
} catch {
    Write-Host (' 2) {0} -> не резолвится' -f $host_) -ForegroundColor Red
}

# 3. что отвечает сам API
$code = 0
$body = ''
$hydra = ''
try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $c = New-Object Net.Http.HttpClient
    $c.Timeout = [TimeSpan]::FromSeconds(12)
    $c.DefaultRequestHeaders.Add('User-Agent', 'Hydra/1.0')
    $resp = $c.GetAsync("$api/v1/health").Result
    $code = [int]$resp.StatusCode
    $body = $resp.Content.ReadAsStringAsync().Result
    if ($body -match '"hydra_error"\s*:\s*(\d+)') { $hydra = $Matches[1] }
} catch { }

$color = 'Green'; $verdict = ''
switch ($code) {
    451 {
        $color = 'Red'
        $verdict = 'БЛОК ПО СТРАНЕ (HTTP 451, Unavailable For Legal Reasons).'
        if ($hydra) { $verdict += ' hydra_error=' + $hydra }
    }
    403 {
        $color = 'Yellow'
        $verdict = 'Дошли до сервера, но запрос отклонён (403). Обычно это норма для запроса без авторизации.'
    }
    0 {
        $color = 'Red'
        $verdict = 'Соединение не установилось (таймаут/TLS).'
    }
    default {
        $verdict = 'Сервер ответил — гео-блокировки нет.'
    }
}
Write-Host (' 3) {0}/v1/health -> HTTP {1}' -f $api, $(if ($code) { $code } else { 'ERR' })) -ForegroundColor $color
if ($hydra) {
    Write-Host ('    ответ бэкенда: hydra_error={0}' -f $hydra) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host (' ВЕРДИКТ: ' + $verdict) -ForegroundColor $color

if ($code -eq 451) {
    Write-Host ''
    Write-Host '  Сервер смотрит на страну вашего IP, а не на DNS.' -ForegroundColor Gray
    Write-Host '  Менять DNS бессмысленно: адрес сервера одинаков для всех резолверов.' -ForegroundColor Gray
    Write-Host '  Нужен VPN с выходом НЕ в РФ и режим «весь трафик через VPN».' -ForegroundColor Gray
} elseif ($code -ne 0 -and $cc -eq 'RU') {
    Write-Host ''
    Write-Host '  До сервера достучались, но IP российский. Если в игре всё равно' -ForegroundColor Gray
    Write-Host '  нет онлайна — дело уже в регионе аккаунта WB, не в сети.' -ForegroundColor Gray
}

Write-Host ('=' * 66) -ForegroundColor DarkCyan
Write-Host ''
if (-not [Console]::IsInputRedirected) { $null = Read-Host ' Enter — закрыть' }

if ($code -eq 451 -or $code -eq 0) { exit 1 }
exit 0
