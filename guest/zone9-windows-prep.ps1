<#
.SYNOPSIS
  zone9-windows-prep — turns a freshly installed Windows Server into a zone9 template.

.DESCRIPTION
  Runs INSIDE the guest, once, right before sysprep. It exists because the alternative
  is typing several screens of PowerShell into a noVNC console by hand — which is slow
  and, worse, silently wrong when a keystroke is dropped.

  Nothing here is zone9-specific magic: it installs cloudbase-init (the piece that reads
  the panel's network/password/hostname from the cloud-init drive), drops the boot-time
  network policy script, and sets a few system defaults. Everything is idempotent, so a
  second run after a failure is safe.

  It deliberately does NOT run sysprep: that is the point of no return and belongs to a
  separate, explicit step (docs/runbooks/template-ubuntu-z9.md).

  Run it from the Proxmox node, so nothing has to be typed inside the VM:

    qm guest exec <vmid> --timeout 900 -- powershell -NoProfile -ExecutionPolicy Bypass \
      -Command "irm https://raw.githubusercontent.com/z9cloud/zone9-agent/main/guest/zone9-windows-prep.ps1 | iex"

  Prerequisite: virtio guest tools must already be installed (they bring the network
  driver and the guest agent). That one step is done in the console — it is a double
  click on the virtio CD, not typing.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar is very slow over guest-exec

function Step($m) { Write-Host "zone9: $m" }
function Fail($m) { Write-Host "zone9 DUR: $m" -ForegroundColor Red; exit 1 }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Fail 'yönetici olarak çalıştırılmalı'
}

$cbDir = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init'

# --- 1. virtio guest tools ------------------------------------------------------
# Konsolda elle kurulmuş olmalı: ağ sürücüsü (NetKVM) ve guest agent oradan gelir ve
# bu betiğin buraya gelebilmesi zaten ikisine bağlı. Yine de doğrulanır: eksikse
# şablon panelden yönetilemez (temiz kapatma, IP raporu).
# virtio-win-gt-x64.msi SÜRÜCÜLERİ kurar; guest agent aynı ISO'da AYRI bir MSI'dır
# (guest-agent\qemu-ga-x86_64.msi). Sürücüler kurulup agent unutulunca VM ağ alır ama
# node'dan yönetilemez — ve bu betik zaten guest exec ile geldiği için buraya varmışsa
# agent çalışıyor demektir. Yine de servisi doğrula: kapalıysa başlatmayı dene.
$ga = Get-Service QEMU-GA -ErrorAction SilentlyContinue
if (-not $ga) {
  Fail 'QEMU-GA servisi yok — virtio ISO''sundaki guest-agent\qemu-ga-x86_64.msi kurulmalı'
}
if ($ga.Status -ne 'Running') { Start-Service QEMU-GA; $ga.Refresh() }
Step "guest agent: $($ga.Status)"

# --- 2. cloudbase-init ----------------------------------------------------------
# Panelin verdiği ad/adres/parolayı misafire uygulayan parça. Proxmox cloud-init'i
# Windows'ta configdrive2 biçiminde üretir ve bunu okuyan tek yaygın araç budur.
# cloudbase-init kendi Python'unu getirir: çalıştırılabilir `bin\` altında DEĞİL,
# `Python\Scripts\cloudbase-init.exe`tedir (`bin\` yalnız servis sarmalayıcısını taşır).
# Sürümler arasında yeri değiştiği için sabit yol yerine ikisi de aranır.
function Find-CbExe {
  @("$cbDir\Python\Scripts\cloudbase-init.exe", "$cbDir\bin\cloudbase-init.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
}
$cbExe = Find-CbExe
if ($cbExe -or (Get-Service cloudbase-init -ErrorAction SilentlyContinue)) {
  Step 'cloudbase-init zaten kurulu'
} else {
  Step 'cloudbase-init indiriliyor'
  $msi = "$env:TEMP\cloudbase-init.msi"
  Invoke-WebRequest 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile $msi
  Step 'cloudbase-init kuruluyor'
  # LOCAL_SYSTEM: parolayı yerleşik Administrator'a yazabilmesi için. Varsayılan
  # kurulum kendi kullanıcısını açar ve o kullanıcı başkasının parolasını değiştiremez.
  $p = Start-Process msiexec -Wait -PassThru -ArgumentList `
    '/i', "`"$msi`"", '/qn', '/norestart', 'RUN_SERVICE_AS_LOCAL_SYSTEM=1'
  if ($p.ExitCode -ne 0) { Fail "cloudbase-init kurulumu $($p.ExitCode) ile bitti" }
  Remove-Item $msi -Force -ErrorAction SilentlyContinue
  $cbExe = Find-CbExe
}
if (-not $cbExe) { Fail "cloudbase-init.exe bulunamadı ($cbDir altında arandı)" }
if (-not (Test-Path "$cbDir\conf\Unattend.xml")) { Fail "Unattend.xml yok: $cbDir\conf" }
Step "cloudbase-init: $cbExe"

# --- 3. yapılandırma ------------------------------------------------------------
# İki dosya, iki aşama: `cloudbase-init.conf` normal açılışta, `-unattend.conf`
# sysprep'in specialize aşamasında koşar. Unattend tarafı bilerek dar tutulur —
# parolayı iki kez uygulamanın anlamı yok, orada yalnız diski büyütmek gerekir.
$main = @"
[DEFAULT]
username=Administrator
groups=Administrators
inject_user_password=true
first_logon_behaviour=no
config_drive_types=iso
config_drive_locations=cdrom
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin
volumes_to_extend=1
allow_reboot=false
stop_service_on_exit=false
local_scripts_path=$cbDir\LocalScripts\
logdir=$cbDir\log\
logfile=cloudbase-init.log
"@
$unattend = @"
[DEFAULT]
username=Administrator
config_drive_types=iso
config_drive_locations=cdrom
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin
volumes_to_extend=1
allow_reboot=false
stop_service_on_exit=true
logdir=$cbDir\log\
logfile=cloudbase-init-unattend.log
"@
New-Item -ItemType Directory -Force "$cbDir\LocalScripts", "$cbDir\log" | Out-Null
Set-Content -Encoding ASCII "$cbDir\conf\cloudbase-init.conf" $main
Set-Content -Encoding ASCII "$cbDir\conf\cloudbase-init-unattend.conf" $unattend
Step 'cloudbase-init yapılandırıldı'

# --- 4. açılış ağ politikası ----------------------------------------------------
# Linux'taki zone9-guest-net'in karşılığı: VPC bloğunu anycast'e yönlendirir ve RDP'yi
# yalnız özel ağlara açar. Her açılışta koşar (cloudbase-init LocalScripts).
$netPs1 = "$cbDir\LocalScripts\zone9-guest-net.ps1"
Invoke-WebRequest 'https://raw.githubusercontent.com/z9cloud/zone9-agent/main/guest/zone9-guest-net.ps1' -OutFile $netPs1
if ((Get-Item $netPs1).Length -lt 500) { Fail 'zone9-guest-net.ps1 eksik indi' }
Step "ağ politikası betiği: $([math]::Round((Get-Item $netPs1).Length/1KB,1)) KB"

# --- 5. sistem varsayılanları ---------------------------------------------------
Set-TimeZone -Id 'UTC'
powercfg /hibernate off | Out-Null              # hiberfil.sys diski boşuna yer kaplar
powercfg /setactive SCHEME_MIN | Out-Null       # yüksek başarım
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon `
  -Value 1 -PropertyType DWORD -Force | Out-Null
Step 'sistem ayarları uygulandı (UTC, hazırda bekletme kapalı, Server Manager açılışta yok)'

# --- 6. kapı --------------------------------------------------------------------
# Şablon kilitli değil ama sysprep'ten sonra buraya dönmek yeniden kurulum demek.
foreach ($f in @("$cbDir\conf\cloudbase-init.conf", "$cbDir\conf\cloudbase-init-unattend.conf",
                 "$cbDir\conf\Unattend.xml", $netPs1, $cbExe)) {
  if (-not (Test-Path $f)) { Fail "eksik: $f" }
}
$svc = Get-Service cloudbase-init -ErrorAction SilentlyContinue
if (-not $svc) { Fail 'cloudbase-init servisi kurulmamış' }
if ($svc.StartType -eq 'Disabled') { Fail 'cloudbase-init servisi devre dışı' }
Step "cloudbase-init servisi: $($svc.Status) / $($svc.StartType)"

Write-Host ''
Write-Host 'KAPI GECILDI — sırada sysprep (node''dan):' -ForegroundColor Green
Write-Host '  qm guest exec <vmid> --timeout 900 -- powershell -NoProfile -Command "& ''C:\Windows\System32\Sysprep\Sysprep.exe'' /generalize /oobe /shutdown /unattend:''C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml''"'
