# Runs as SYSTEM. Resets the VM to the state described in
# https://github.com/podman-container-tools/podman/issues/30266 for one test:
# a brand-new local administrator that has never logged on (no profile), is
# not in Hyper-V Administrators, and no Podman vsock registry entries exist.
param(
    [Parameter(Mandatory)]
    [string]$TestUser,

    [Parameter(Mandatory)]
    [string]$TestPassword
)

$ErrorActionPreference = 'Stop'

$hyperVGroupSid = 'S-1-5-32-578'
$adminGroupSid = 'S-1-5-32-544'
$vsockPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices'

# Recreate the user so every test starts without a profile.
$existing = Get-LocalUser -Name $TestUser -ErrorAction SilentlyContinue
if ($existing) {
    $profileInfo = Get-CimInstance -ClassName Win32_UserProfile |
        Where-Object { $_.SID -eq $existing.SID.Value }
    if ($profileInfo) {
        $profileInfo | Remove-CimInstance
    }
    Remove-LocalUser -Name $TestUser
}

$securePassword = ConvertTo-SecureString -String $TestPassword -AsPlainText -Force
New-LocalUser `
    -Name $TestUser `
    -Password $securePassword `
    -PasswordNeverExpires `
    -UserMayNotChangePassword |
    Out-Null
Add-LocalGroupMember -SID $adminGroupSid -Member $TestUser

$sid = (Get-LocalUser -Name $TestUser).SID.Value
$inHyperV = Get-LocalGroupMember -SID $hyperVGroupSid |
    Where-Object { $_.SID.Value -eq $sid }
if ($inHyperV) {
    Remove-LocalGroupMember -SID $hyperVGroupSid -Member $TestUser
}

# Remove vsock entries created by earlier tests (podman tags them with Purpose).
$removed = 0
if (Test-Path -Path $vsockPath) {
    foreach ($key in Get-ChildItem -Path $vsockPath) {
        if ($null -ne $key.GetValue('Purpose')) {
            Remove-Item -Path $key.PSPath -Recurse -Force
            $removed++
        }
    }
}

# Managed Run Command run_as_user relies on Secondary Logon.
Set-Service -Name seclogon -StartupType Manual
Start-Service -Name seclogon

$logDirectory = Join-Path $env:SystemDrive 'podman-test\logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null

Write-Output "user=$TestUser sid=$sid admin=true hyperv-admin=false profile=none vsock-removed=$removed"
