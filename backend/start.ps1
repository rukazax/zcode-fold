param(
  [string]$Workspace = "",
  [switch]$Tunnel,
  [switch]$NoServe
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = $root }
$Workspace = (Resolve-Path $Workspace).Path.TrimEnd('\')

$tokenFile = Join-Path $PSScriptRoot '.token'
if (-not (Test-Path $tokenFile)) {
  $token = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tokenFile, $token)
}
$token = (Get-Content $tokenFile -Raw).Trim()

$hubPort = 8377
$hubUrl = "http://127.0.0.1:$hubPort"

function Test-Hub {
  try {
    $r = Invoke-WebRequest -UseBasicParsing "$hubUrl/api/health" -TimeoutSec 2
    return $r.StatusCode -eq 200
  } catch { return $false }
}

function Get-Instances {
  try {
    return @(Invoke-RestMethod "$hubUrl/api/instances?probe=1" -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 5)
  } catch { return @() }
}

if (-not (Test-Hub)) {
  Write-Host "Запускаю hub…" -ForegroundColor DarkGray
  Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$PSScriptRoot\hub.cmd`"" -WindowStyle Hidden | Out-Null
  $deadline = (Get-Date).AddSeconds(25)
  while (-not (Test-Hub) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 400 }
  if (-not (Test-Hub)) { throw "Hub не поднялся на $hubUrl" }
}

if (-not $NoServe) {
  $instances = Get-Instances
  $exists = $instances | Where-Object { $_.workspace -eq $Workspace }
  if (-not $exists) {
    Write-Host "Запускаю headless-мост для $Workspace…" -ForegroundColor DarkGray
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$PSScriptRoot\serve.cmd`"" -WorkingDirectory $Workspace -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    do {
      Start-Sleep -Milliseconds 600
      $instances = Get-Instances
      $exists = $instances | Where-Object { $_.workspace -eq $Workspace }
    } while (-not $exists -and (Get-Date) -lt $deadline)
    if (-not $exists) { Write-Host "Мост не зарегистрировался — проверь, что ZCode установлен." -ForegroundColor Yellow }
  }
}

$publicUrl = ''
if ($Tunnel) {
  $tools = Join-Path $PSScriptRoot 'tools'
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $cf = Join-Path $tools 'cloudflared.exe'
  if (-not (Test-Path $cf)) {
    Write-Host "Скачиваю cloudflared (≈60 МБ)…" -ForegroundColor DarkGray
    Invoke-WebRequest -UseBasicParsing 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $cf
  }
  $log = Join-Path $tools 'cloudflared.log'
  $errLog = Join-Path $tools 'cloudflared.err.log'
  if (Test-Path $log) { Remove-Item $log -Force }
  Start-Process -FilePath $cf -ArgumentList 'tunnel', '--url', $hubUrl, '--no-autoupdate' -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $errLog | Out-Null
  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline -and -not $publicUrl) {
    Start-Sleep -Milliseconds 700
    foreach ($f in @($log, $errLog)) {
      if (Test-Path $f) {
        $m = Select-String -Path $f -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -AllMatches | Select-Object -First 1
        if ($m) { $publicUrl = $m.Matches[0].Value; break }
      }
    }
  }
}

$lan = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object -First 1 -ExpandProperty IPAddress)

Write-Host ""
Write-Host "  ZCode Fold — hub готов" -ForegroundColor Green
Write-Host "  ─────────────────────────────────────────"
Write-Host "  Локально : $hubUrl"
if ($lan) { Write-Host "  В сети   : http://${lan}:$hubPort" }
if ($publicUrl) {
  Write-Host "  Интернет : $publicUrl" -ForegroundColor Cyan
} elseif ($Tunnel) {
  Write-Host "  Интернет : tunnel не поднялся, смотри backend\tools\cloudflared.err.log" -ForegroundColor Yellow
} else {
  Write-Host "  Интернет : запусти с -Tunnel (Cloudflare quick tunnel)" -ForegroundColor DarkGray
}
Write-Host "  Токен    : $token"
Write-Host "  Проект   : $Workspace"
Write-Host "  ─────────────────────────────────────────"
Write-Host "  В приложении: адрес + токен → «Подключиться»."
Write-Host ""
