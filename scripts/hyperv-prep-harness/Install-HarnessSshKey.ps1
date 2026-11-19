# Runs as SYSTEM. Authorizes the harness's ephemeral public key for
# administrators so podman test binaries can be copied with scp.
param(
    [Parameter(Mandatory)]
    [string]$PublicKey
)

$ErrorActionPreference = 'Stop'

$keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'

$keys = @()
if (Test-Path -Path $keyFile) {
    $keys = @(Get-Content -Path $keyFile)
}
if ($keys -notcontains $PublicKey) {
    Add-Content -Path $keyFile -Value $PublicKey -Encoding ascii
}

# sshd ignores this file unless only Administrators and SYSTEM can access it.
& icacls.exe $keyFile /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "icacls failed on $keyFile."
}

New-Item -ItemType Directory -Force -Path (Join-Path $env:SystemDrive 'podman-test') | Out-Null
Write-Output 'harness key installed'
