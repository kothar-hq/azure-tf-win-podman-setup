# Runs as SYSTEM after a test. Reports the log and the resulting machine state
# independently of what the run-as command returned to Azure.
param(
    [Parameter(Mandatory)]
    [string]$TestUser,

    [Parameter(Mandatory)]
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$hyperVGroupSid = 'S-1-5-32-578'
$vsockPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices'

if (Test-Path -Path $LogPath) {
    Get-Content -Path $LogPath
}
else {
    Write-Output "log-missing=$LogPath"
}

$sid = (Get-LocalUser -Name $TestUser).SID.Value
$inHyperV = [bool](Get-LocalGroupMember -SID $hyperVGroupSid |
        Where-Object { $_.SID.Value -eq $sid })

$vsockCount = 0
if (Test-Path -Path $vsockPath) {
    $vsockCount = @(Get-ChildItem -Path $vsockPath |
            Where-Object { $null -ne $_.GetValue('Purpose') }).Count
}

Write-Output "RESULT hyperv-admin=$inHyperV vsock-entries=$vsockCount"
