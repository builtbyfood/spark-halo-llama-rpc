<#
  Set-HaloDirect.ps1  v1.0.1  (2026-11-20)

  Configures the Halo end of the direct 10GbE link to the Spark.
    Halo   10.10.10.1/30  (WAVLINK WL-NWU343G, RTL8159, USB)
    Spark  10.10.10.2/30  (enP7s7, NetworkManager profile "halo-direct")

  No gateway and no DNS on this link, so it never competes with the LAN.
  Run from an elevated PowerShell once the adapter is plugged in and the
  Realtek driver is installed.

    .\Set-HaloDirect.ps1 -Check     show what it would use, change nothing
    .\Set-HaloDirect.ps1            apply
    .\Set-HaloDirect.ps1 -AdapterName "Ethernet 2"    pick the adapter by name

  Changes
    1.0.1  Address is now set with netsh. New-NetIPAddress refuses a static
           address on an adapter with no cable ("Inconsistent parameters
           PolicyStore PersistentStore and Dhcp Enabled"), which stopped
           1.0.0 before it reached the firewall rule.
    1.0.0  First version.
#>
param(
  [switch]$Check,
  [string]$Alias = 'HaloDirect',
  [string]$Address = '10.10.10.1',
  [int]$PrefixLength = 30,
  [string]$Peer = '10.10.10.2',
  [string]$AdapterName = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.1'
Write-Host "Set-HaloDirect v$Version"

$all = @(Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' })
Write-Host 'Ethernet adapters present:'
$all | Format-Table Name, InterfaceDescription, Status, LinkSpeed -AutoSize | Out-String | Write-Host

if ($AdapterName) {
  $cand = @($all | Where-Object { $_.Name -eq $AdapterName })
} else {
  $cand = @($all | Where-Object { $_.Name -eq $Alias })
  if ($cand.Count -eq 0) {
    $cand = @($all | Where-Object { $_.InterfaceDescription -match 'USB' -and $_.InterfaceDescription -match '10G|8159' })
  }
  if ($cand.Count -eq 0) {
    $cand = @($all | Where-Object { $_.InterfaceDescription -match 'USB' })
  }
}

if ($cand.Count -ne 1) {
  Write-Host "Found $($cand.Count) candidate adapters for the direct link."
  Write-Host 'Plug in the USB 10GbE adapter and install its driver, or rerun with -AdapterName "<name from the table above>".'
  exit 1
}

$nic = $cand[0]
Write-Host "Selected: $($nic.Name)  [$($nic.InterfaceDescription)]  $($nic.Status)  $($nic.LinkSpeed)"

$bits = ('1' * $PrefixLength).PadRight(32, '0')
$Mask = (0..3 | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }) -join '.'

if ($Check) {
  Write-Host "Check only: would set $Address/$PrefixLength ($Mask) on this adapter and name it $Alias. No changes made."
  exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'Run this from an elevated PowerShell.'
  exit 1
}

if ($nic.Name -ne $Alias) {
  Rename-NetAdapter -Name $nic.Name -NewName $Alias
}

# netsh sets a static address whether or not the cable is connected.
& netsh interface ipv4 set address "name=$Alias" source=static "address=$Address" "mask=$Mask" store=persistent | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) {
  Write-Host "netsh could not set the address (exit $LASTEXITCODE)."
  exit 1
}
& netsh interface ipv4 set dnsservers "name=$Alias" source=static address=none register=none validate=no | Out-Null

Get-NetRoute -InterfaceAlias $Alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
  Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
Disable-NetAdapterBinding -Name $Alias -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue

$rule = 'HaloDirect - allow Spark'
if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -RemoteAddress $Peer -Profile Any | Out-Null
}

Start-Sleep -Seconds 3
Get-NetAdapter -Name $Alias | Format-Table Name, InterfaceDescription, Status, LinkSpeed -AutoSize | Out-String | Write-Host
& netsh interface ipv4 show addresses "name=$Alias" | Out-String | Write-Host

$link = (Get-NetAdapter -Name $Alias).Status
if ($link -ne 'Up') {
  Write-Host "Address is set. The link is $link, so plug the cable into the Spark's 10 GbE port."
} elseif (Test-Connection -ComputerName $Peer -Count 3 -Quiet) {
  Write-Host "OK: Spark answers at $Peer over $Alias."
} else {
  Write-Host "Link is up but no reply from $Peer. Check that the Spark's halo-direct profile is active."
}
