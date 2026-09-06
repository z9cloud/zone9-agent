<#
.SYNOPSIS
  zone9-guest-net — boot-time network policy for Windows guests.

.DESCRIPTION
  The Windows counterpart of zone9-guest-net.sh. Proxmox cloud-init can express
  "address + gateway" per interface and nothing else — it cannot write static
  routes. Two consequences, both of which this script fixes at every boot:

  1. A VPC's subnets reach each other through the subnet's anycast gateway (.1),
     but a VM whose default route is a zone9 Ağ Geçidi VM does NOT: the gateway
     drops forwarding between private legs (FORWARD policy DROP). Without an
     explicit route the VM silently loses the rest of its own VPC. The VPC is the
     enclosing /20 of the interface's address (ADR-037).

  2. A dual-homed VM (public + private leg) ends up with two default routes, and
     replies leave through whichever the kernel picks. The symptom is distinctive:
     50-70% packet loss. Single leg is the current product shape, so this branch is
     written but NOT yet verified in production — see docs/plans/windows-sunucu.md.

  It also opens RDP and narrows it to private sources. RDP is never exposed to the
  internet: customers reach it from their tailnet through the Ağ Geçidi's subnet
  router, so the only sources that ever need to pass are RFC1918 and 100.64/10.

.PARAMETER Install
  Copy this script to C:\Program Files\zone9 and register a scheduled task that
  runs it at every startup. Used once, while building the template.

.NOTES
  Idempotent: safe to run at every boot. Runs as SYSTEM.
#>
[CmdletBinding()]
param([switch]$Install)

$ErrorActionPreference = 'Stop'
# Sürüm satırı: şablonun hangi betiği taşıdığı misafirin içinden okunabilsin diye.
# Kabul kriteri bunu okur (docs/plans/windows-sunucu.md §6).
$Zone9GuestNetVersion = '2026-09-06.1'
$InstallDir = Join-Path $env:ProgramFiles 'zone9'
$TaskName   = 'zone9-guest-net'

function Write-Log($msg) { Write-Output "zone9-guest-net: $msg" }

function Test-PrivateAddress([string]$ip) {
    if (-not $ip) { return $false }
    $o = $ip.Split('.')
    if ($o.Count -ne 4) { return $false }
    $a = [int]$o[0]; $b = [int]$o[1]
    # RFC1918 plus 100.64/10: the tailnet and the platform's own transit blocks
    # live in the shared-address space, and they are "private" for this purpose.
    if ($a -eq 10) { return $true }
    if ($a -eq 192 -and $b -eq 168) { return $true }
    if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $true }
    if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return $true }
    return $false
}

# The VPC that encloses an address, per the address plan (ADR-037): a /20, and the
# subnet's anycast gateway is the first host of the interface's own subnet.
function Get-VpcRoute([string]$ip, [int]$prefixLength) {
    if ($prefixLength -lt 20) { return $null }
    $o = $ip.Split('.')
    $third = [int]$o[2]
    [pscustomobject]@{
        Prefix  = "{0}.{1}.{2}.0/20" -f $o[0], $o[1], ($third -band 240)
        Anycast = "{0}.{1}.{2}.1"    -f $o[0], $o[1], $third
    }
}

function Set-Route([string]$prefix, [string]$nextHop, [int]$ifIndex, [int]$metric) {
    # Replace rather than add: the route may exist from an earlier boot with a
    # different next hop (the gateway can be attached or detached at any time).
    Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $ifIndex -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $ifIndex -NextHop $nextHop `
        -RouteMetric $metric -PolicyStore ActiveStore -Confirm:$false | Out-Null
}

# ---------------------------------------------------------------- routing policy
function Set-Zone9Routes {
    $defaults = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' }
    if (-not $defaults) { Write-Log 'no default route yet; nothing to do'; return }

    $private = @($defaults | Where-Object { Test-PrivateAddress $_.NextHop })
    $public  = @($defaults | Where-Object { -not (Test-PrivateAddress $_.NextHop) })

    if ($private.Count -eq 0) { Write-Log 'no private leg; routes unchanged'; return }
    $priv = $private[0]

    $addr = Get-NetIPAddress -InterfaceIndex $priv.InterfaceIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $addr) { Write-Log 'private leg has no address; routes unchanged'; return }

    # The VPC route is needed whenever the default is a gateway VM rather than the
    # subnet's own anycast .1 — in the single-leg shape that is the normal case.
    $vpc = Get-VpcRoute $addr.IPAddress ([int]$addr.PrefixLength)
    if ($vpc -and $priv.NextHop -ne $vpc.Anycast) {
        Set-Route $vpc.Prefix $vpc.Anycast $priv.InterfaceIndex 50
        Write-Log "VPC $($vpc.Prefix) via anycast $($vpc.Anycast) (gateway $($priv.NextHop) does not route between legs)"
    }

    if ($public.Count -eq 0) {
        Write-Log "single-homed; default via $($priv.NextHop)"
        return
    }

    # Dual-homed: the default must leave through the public leg, so the private
    # default is replaced by explicit private destinations.
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $priv.InterfaceIndex `
        -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($net in '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10') {
        Set-Route $net $priv.NextHop $priv.InterfaceIndex 100
    }
    Write-Log "dual-homed; default on public leg, private destinations via $($priv.NextHop)"
}

# ------------------------------------------------------------------------- RDP
function Set-Zone9Rdp {
    # RDP itself on. NLA stays on: the login prompt should not be reachable
    # unauthenticated even from inside the VPC.
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name 'fDenyTSConnections' -Value 0 -Type DWord
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name 'UserAuthentication' -Value 1 -Type DWord

    # Windows may classify the VPC leg as "Public" and a profile-based rule would
    # then not apply. That is why the rule is enabled on ALL profiles and narrowed
    # by SOURCE ADDRESS instead — never by profile, and never to Any.
    $sources = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10')
    $rules = Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
    if (-not $rules) { Write-Log 'Remote Desktop firewall group not found'; return }
    $rules | Set-NetFirewallRule -Enabled True -Profile Any -RemoteAddress $sources
    Write-Log 'RDP enabled, restricted to private sources'
}

# --------------------------------------------------------------------- install
function Install-Zone9GuestNet {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $target = Join-Path $InstallDir 'zone9-guest-net.ps1'
    Copy-Item -Path $PSCommandPath -Destination $target -Force

    # A scheduled task, not a cloudbase-init plugin: some cloudbase-init plugins run
    # once per instance, and this policy must be re-applied at EVERY boot — a gateway
    # can be attached or detached while the machine is off.
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$target`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    # The network is not up the instant the machine is: retry rather than run once
    # into an empty routing table.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Write-Log "installed to $target and registered as scheduled task '$TaskName'"
}

if ($Install) {
    Install-Zone9GuestNet
    exit 0
}

Write-Log "version $Zone9GuestNetVersion"
Set-Zone9Routes
Set-Zone9Rdp
