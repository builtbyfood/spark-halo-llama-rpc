# guarded-start.ps1 v1.2.0 - start a llama.cpp process on the Halo behind a RAM guard.
# Refuses to start unless Available RAM >= MinStartGiB and the load mode is none (added if absent).
# A detached watchdog is started FIRST and warms its performance counter; only then is the target
# started and its PID handed over. The watchdog polls Available RAM every 0.5 s for the life of the
# process and kills it below FloorGiB. Watchdog log: <LogBase>.guard.log
param(
  [Parameter(Mandatory)][string]$Exe,
  [Parameter(Mandatory)][string[]]$ArgList,
  [Parameter(Mandatory)][string]$LogBase,
  [double]$FloorGiB = 4,
  [double]$MinStartGiB = 8,
  [switch]$NoModelFile   # for ggml-rpc-server: it loads no model file, so no --load-mode; the RAM guard still applies
)
if (-not $NoModelFile) {
  if ($ArgList -notcontains '--load-mode' -and $ArgList -notcontains '-lm') { $ArgList = @($ArgList) + @('--load-mode', 'none') }
  $lmIdx = [array]::IndexOf($ArgList, '--load-mode'); if ($lmIdx -lt 0) { $lmIdx = [array]::IndexOf($ArgList, '-lm') }
  if ($ArgList[$lmIdx + 1] -ne 'none') { Write-Output "REFUSED: load mode is '$($ArgList[$lmIdx + 1])', must be none"; exit 2 }
}

$guardLog = "$LogBase.guard.log"; $readyFile = "$LogBase.guard.ready"; $pidFile = "$LogBase.guard.pid"
Remove-Item $readyFile, $pidFile -ErrorAction SilentlyContinue
$watch = @"
`$pc = New-Object System.Diagnostics.PerformanceCounter('Memory', 'Available MBytes')
[void]`$pc.NextValue()
'ready' | Out-File -Encoding ascii '$readyFile'
for (`$i = 0; `$i -lt 200 -and -not (Test-Path '$pidFile'); `$i++) { Start-Sleep -Milliseconds 100 }
if (-not (Test-Path '$pidFile')) { exit }
`$tpid = [int](Get-Content '$pidFile')
`$proc = Get-Process -Id `$tpid -ErrorAction SilentlyContinue
`$min = 999
while (`$proc -and -not `$proc.HasExited) {
  `$a = `$pc.NextValue() / 1024
  if (`$a -lt `$min) { `$min = `$a; "{0} new min available {1:N2} GiB" -f (Get-Date -Format o), `$a | Out-File -Append -Encoding ascii '$guardLog' }
  if (`$a -lt $FloorGiB) {
    Stop-Process -Id `$tpid -Force
    "{0} KILLED pid `$tpid : available {1:N2} GiB < $FloorGiB GiB floor" -f (Get-Date -Format o), `$a | Out-File -Append -Encoding ascii '$guardLog'
    break
  }
  Start-Sleep -Milliseconds 500
}
"{0} watchdog exit, min available {1:N2} GiB" -f (Get-Date -Format o), `$min | Out-File -Append -Encoding ascii '$guardLog'
"@
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watch))
$w = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-EncodedCommand', $enc -WindowStyle Hidden -PassThru
for ($i = 0; $i -lt 300 -and -not (Test-Path $readyFile); $i++) { Start-Sleep -Milliseconds 100 }
if (-not (Test-Path $readyFile)) { Stop-Process -Id $w.Id -Force -ErrorAction SilentlyContinue; Write-Output "REFUSED: watchdog did not become ready"; exit 4 }

$avail = (Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue / 1024
if ($avail -lt $MinStartGiB) { Stop-Process -Id $w.Id -Force -ErrorAction SilentlyContinue; Write-Output ("REFUSED: available RAM {0:N1} GiB < {1} GiB required to start" -f $avail, $MinStartGiB); exit 3 }

$quoted = $ArgList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
$p = Start-Process -FilePath $Exe -ArgumentList $quoted -RedirectStandardOutput "$LogBase.out.log" -RedirectStandardError "$LogBase.log" -WindowStyle Hidden -PassThru
$p.Id | Out-File -Encoding ascii $pidFile
"{0} start pid {1} watchdog {2}, available at start {3:N1} GiB, args: {4}" -f (Get-Date -Format o), $p.Id, $w.Id, $avail, ($ArgList -join ' ') | Out-File -Append -Encoding ascii $guardLog
Write-Output ("STARTED pid={0} watchdog={1} available={2:N1}GiB" -f $p.Id, $w.Id, $avail)
