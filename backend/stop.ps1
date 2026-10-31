param()
$ErrorActionPreference = 'SilentlyContinue'
$procs = Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -match 'zcode-acp-server[\\/]dist[\\/]cli\.js\s+(hub|serve)' -or
  $_.CommandLine -match 'cloudflared.*tunnel\s+--url\s+http://127\.0\.0\.1:8377'
}
foreach ($p in $procs) {
  Write-Host "stop PID $($p.ProcessId): $($p.CommandLine.Substring(0, [Math]::Min(90, $p.CommandLine.Length)))"
  Stop-Process -Id $p.ProcessId -Force
}
if (-not $procs) { Write-Host "Нечего останавливать." }
