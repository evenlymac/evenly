# Evenly APO: install / uninstall (run as Administrator). ASCII only: PowerShell 5 reads UTF-8 without BOM as ANSI.
#   evenly-apo.ps1 -Action install   [-Dll path\evenly_apo.dll] [-Slot EFX|MFX|SFX] [-Endpoints guid,guid] [-NoRestart]
#   evenly-apo.ps1 -Action uninstall [-NoRestart]
# Install backs up everything it touches into C:\ProgramData\Evenly\backup; uninstall restores from there.
param(
  [Parameter(Mandatory)][ValidateSet('install','uninstall','status')][string]$Action,
  [string]$Dll,
  [ValidateSet('EFX','MFX','SFX')][string]$Slot = 'EFX',
  [string[]]$Endpoints,
  [string[]]$Modes,
  [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
if (-not $Dll) { $Dll = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'evenly_apo.dll' }
$Clsid     = '{5B1A5C4E-3B0E-4F4F-9A3E-EE1E0A9D0001}'
$InstDir   = Join-Path $env:ProgramFiles 'Evenly'
$DataDir   = Join-Path $env:ProgramData 'Evenly'
$BackupDir = Join-Path $DataDir 'backup'
$StateFile = Join-Path $BackupDir 'state.json'
$Render    = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$AudioKey  = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Audio'
$SlotNum   = @{ SFX = 5; MFX = 6; EFX = 7 }
$KeyClsid  = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}'   # PKEY_FX_*EffectClsid
$KeyModes  = '{d3993a3f-99c2-4402-b5ec-a92a0367664b}'   # supported processing modes
$DefaultMode = '{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}'
$RawMode     = '{9E90EA20-B493-4FD1-A1A8-7E1361A956CF}'
if (-not $Modes) { $Modes = @($DefaultMode) }
$Modes = @($Modes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$RK = [Microsoft.Win32.Registry]::LocalMachine
$Rights = [System.Security.AccessControl.RegistryRights]

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole($Admins) }
if (-not (Test-Admin)) { throw 'run as Administrator' }

# Administrators hold SeTakeOwnership/SeRestore/SeBackup but the token has them disabled; enable them (needed on GitHub runners)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class EvenlyPriv {
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, int acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
  [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP n, int len, IntPtr p, IntPtr r);
  [StructLayout(LayoutKind.Sequential, Pack=4)] struct TP { public int Count; public long Luid; public int Attr; }
  public static bool Enable(string name) {
    IntPtr tok; if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out tok)) return false;
    TP tp = new TP(); tp.Count = 1; tp.Attr = 2;
    if (!LookupPrivilegeValue(null, name, out tp.Luid)) return false;
    return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero) && Marshal.GetLastWin32Error() == 0;
  }
}
'@
foreach ($pv in 'SeTakeOwnershipPrivilege','SeRestorePrivilege','SeBackupPrivilege') { [void][EvenlyPriv]::Enable($pv) }

function Get-Active { Get-ChildItem "HKLM:\$Render" | Where-Object { (Get-ItemProperty $_.PSPath).DeviceState -eq 1 } | ForEach-Object { $_.PSChildName } }

# take ownership + full control for Administrators on an endpoint FxProperties key
function Open-Key([string]$sub) {
  $k = $RK.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $Rights::TakeOwnership)
  $acl = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
  $acl.SetOwner($Admins); $k.SetAccessControl($acl); $k.Close()
  $k = $RK.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $Rights::ChangePermissions)
  $acl = $k.GetAccessControl()
  $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($Admins, 'FullControl', 'ContainerInherit', 'None', 'Allow')))
  $k.SetAccessControl($acl); $k.Close()
  $RK.OpenSubKey($sub, $true)
}

function Restart-Audio { if (-not $NoRestart) { Restart-Service -Name audiosrv -Force; Start-Sleep 2; (Get-Service audiosrv).Status } }

if ($Action -eq 'status') {
  "dll:        " + (Test-Path (Join-Path $InstDir 'evenly_apo.dll'))
  "com:        " + (Test-Path "HKLM:\SOFTWARE\Classes\CLSID\$Clsid")
  "flag:       " + (Get-ItemProperty "HKLM:\$AudioKey" -ErrorAction SilentlyContinue).DisableProtectedAudioDG
  "state file: " + (Test-Path $StateFile)
  if (Test-Path $StateFile) { Get-Content $StateFile }
  exit 0
}

if ($Action -eq 'install') {
  if (-not (Test-Path $Dll)) { throw "dll not found: $Dll" }
  if (Test-Path $StateFile) { throw 'already installed (state.json exists): run uninstall first' }
  if (-not $Endpoints) { $Endpoints = @(Get-Active) }
  if (-not $Endpoints) { throw 'no active render endpoints' }
  New-Item -ItemType Directory -Force $InstDir, $DataDir, $BackupDir | Out-Null
  & icacls $DataDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null   # LOCAL SERVICE (audiodg) writes the log
  # backup
  $prevFlag = (Get-ItemProperty "HKLM:\$AudioKey" -ErrorAction SilentlyContinue).DisableProtectedAudioDG
  $state = @{ slot = $Slot; flag_before = $prevFlag; endpoints = @() }
  foreach ($ep in $Endpoints) {
    $sub = "$Render\$ep\FxProperties"
    $kc = "$KeyClsid,$($SlotNum[$Slot])"; $km = "$KeyModes,$($SlotNum[$Slot])"
    $epk = $RK.OpenSubKey($sub)
    $origC = $epk.GetValue($kc); $origM = $epk.GetValue($km)
    $sddl = (Get-Acl "HKLM:\$sub").Sddl
    & reg export "HKLM\$sub" (Join-Path $BackupDir "ep-$ep.reg") /y | Out-Null
    $epk.Close()
    $state.endpoints += @{ id = $ep; clsid_before = $origC; modes_before = $origM; sddl = $sddl }
  }
  & reg export "HKLM\$AudioKey" (Join-Path $BackupDir 'audio.reg') /y | Out-Null
  $state | ConvertTo-Json -Depth 5 | Set-Content -Encoding ASCII $StateFile
  # files + COM
  Copy-Item $Dll (Join-Path $InstDir 'evenly_apo.dll') -Force
  & regsvr32 /s (Join-Path $InstDir 'evenly_apo.dll'); if ($LASTEXITCODE -ne 0) { throw "regsvr32 failed: $LASTEXITCODE" }
  New-ItemProperty -Path "HKLM:\$AudioKey" -Name DisableProtectedAudioDG -Value 1 -PropertyType DWord -Force | Out-Null
  # crash dumps of audiodg.exe (WER LocalDumps, full dump, 3 newest) for post-mortem of APPCRASH; removed on uninstall
  $dumps = Join-Path $DataDir 'dumps'; New-Item -ItemType Directory -Force $dumps | Out-Null
  & icacls $dumps /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
  $ld = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\audiodg.exe'
  New-Item -Path $ld -Force | Out-Null
  New-ItemProperty -Path $ld -Name DumpFolder -Value $dumps -PropertyType ExpandString -Force | Out-Null
  New-ItemProperty -Path $ld -Name DumpType -Value 2 -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $ld -Name DumpCount -Value 3 -PropertyType DWord -Force | Out-Null
  foreach ($ep in $Endpoints) {
    $k = Open-Key "$Render\$ep\FxProperties"
    $k.SetValue("$KeyClsid,$($SlotNum[$Slot])", $Clsid, 'String')
    $k.SetValue("$KeyModes,$($SlotNum[$Slot])", [string[]]$Modes, 'MultiString')
    $k.Close()
  }
  "installed: slot=$Slot endpoints=$($Endpoints -join ',')"
  Restart-Audio
  exit 0
}

if ($Action -eq 'uninstall') {
  if (-not (Test-Path $StateFile)) { throw 'nothing to uninstall (no state.json)' }
  $state = Get-Content $StateFile -Raw | ConvertFrom-Json
  $n = $SlotNum[$state.slot]
  foreach ($e in $state.endpoints) {
    $sub = "$Render\$($e.id)\FxProperties"
    $k = Open-Key $sub
    foreach ($pair in @(@("$KeyClsid,$n", $e.clsid_before, 'String'), @("$KeyModes,$n", $e.modes_before, 'MultiString'))) {
      if ($null -eq $pair[1]) { $k.DeleteValue($pair[0], $false) }
      elseif ($pair[2] -eq 'MultiString') { $k.SetValue($pair[0], [string[]]@($pair[1]), 'MultiString') }
      else { $k.SetValue($pair[0], [string]$pair[1], 'String') }
    }
    $k.Close()
    # original ACL back
    $kk = $RK.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $Rights::ChangePermissions -bor $Rights::TakeOwnership)
    $acl = $kk.GetAccessControl(); $acl.SetSecurityDescriptorSddlForm($e.sddl); $kk.SetAccessControl($acl); $kk.Close()
  }
  if ($null -eq $state.flag_before) { Remove-ItemProperty -Path "HKLM:\$AudioKey" -Name DisableProtectedAudioDG -ErrorAction SilentlyContinue }
  else { New-ItemProperty -Path "HKLM:\$AudioKey" -Name DisableProtectedAudioDG -Value $state.flag_before -PropertyType DWord -Force | Out-Null }
  Remove-Item -Recurse -Force 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\audiodg.exe' -ErrorAction SilentlyContinue
  Restart-Audio
  & regsvr32 /s /u (Join-Path $InstDir 'evenly_apo.dll')
  Remove-Item -Recurse -Force "HKLM:\SOFTWARE\Classes\CLSID\$Clsid", "HKLM:\SOFTWARE\Classes\AudioEngine\AudioProcessingObjects\$Clsid" -ErrorAction SilentlyContinue
  Move-Item $StateFile (Join-Path $BackupDir ("state-uninstalled-" + (Get-Date -Format yyyyMMdd-HHmmss) + ".json")) -Force
  Remove-Item (Join-Path $InstDir 'evenly_apo.dll') -Force -ErrorAction SilentlyContinue
  'uninstalled'
}
