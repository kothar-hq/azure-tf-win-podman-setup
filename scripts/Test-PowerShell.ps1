#Requires -Version 5.1
<#
.SYNOPSIS
    Lints the repository's PowerShell files and Terraform-embedded run commands.
#>
[CmdletBinding()]
param(
    [string]$Path = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    throw 'PSScriptAnalyzer is not installed. Rebuild the devcontainer so the PowerShell feature installs it.'
}

$settingsPath = Join-Path $Path 'PSScriptAnalyzerSettings.psd1'

if (-not (Test-Path -Path $settingsPath)) {
    throw "PSScriptAnalyzer settings not found at $settingsPath."
}

$issues = [System.Collections.Generic.List[object]]::new()

function Add-AnalyzerResult {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string]$Source
    )

    foreach ($result in $Results) {
        $issues.Add([pscustomobject]@{
            Source   = $Source
            Line     = $result.Line
            Severity = $result.Severity
            Rule     = $result.RuleName
            Message  = $result.Message
        })
    }
}

# Terraform's <<-EOT strips the common leading indentation. Reproduce that so
# here-strings and line continuations are analyzed exactly as the VM receives
# them.
function ConvertFrom-HeredocIndent {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $lines = $Text -split "\r?\n"
    $indents = foreach ($line in $lines) {
        if ($line.Trim().Length -eq 0) {
            continue
        }

        if ($line -match '^([ \t]*)') {
            $Matches[1].Length
        }
    }

    if (-not $indents) {
        return $Text
    }

    $minimum = ($indents | Measure-Object -Minimum).Minimum

    if ($minimum -le 0) {
        return $Text
    }

    $dedented = foreach ($line in $lines) {
        if ($line.Length -ge $minimum) {
            $line.Substring($minimum)
        }
        else {
            $line.TrimStart()
        }
    }

    return ($dedented -join "`n")
}

$ps1Files = Get-ChildItem -Path $Path -Filter *.ps1 -File -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/]\.(git|terraform)[\\/]' }

foreach ($file in $ps1Files) {
    $results = Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath
    Add-AnalyzerResult -Results $results -Source $file.Name
}

# Azure VM run command scripts live in `script = <<-EOT` blocks, and the
# profile helper is a local interpolated into one. Local-exec `command`
# heredocs are bash, so they are intentionally skipped.
$heredocPattern = '(?ms)^[ \t]*(?<key>[A-Za-z0-9_]+)[ \t]*=[ \t]*<<(?<strip>-?)EOT[ \t]*\r?\n(?<body>.*?)^[ \t]*EOT[ \t]*$'
$terraformScriptKeys = @('script')

$tfFiles = Get-ChildItem -Path $Path -Filter *.tf -File

foreach ($tfFile in $tfFiles) {
    $content = Get-Content -Raw -LiteralPath $tfFile.FullName
    $heredocMatches = [regex]::Matches($content, $heredocPattern)
    $index = 0

    foreach ($heredocMatch in $heredocMatches) {
        $index++
        $key = $heredocMatch.Groups['key'].Value

        if ($key -notin $terraformScriptKeys) {
            continue
        }

        $body = $heredocMatch.Groups['body'].Value

        if ($heredocMatch.Groups['strip'].Value -eq '-') {
            $body = ConvertFrom-HeredocIndent -Text $body
        }

        $results = Invoke-ScriptAnalyzer -ScriptDefinition $body -Settings $settingsPath
        Add-AnalyzerResult -Results $results -Source ('{0} (heredoc {1})' -f $tfFile.Name, $index)
    }
}

if ($issues.Count -eq 0) {
    Write-Host 'PowerShell lint passed.'
    exit 0
}

$issues |
    Sort-Object Source, Line, Rule |
    Format-Table -AutoSize Source, Line, Severity, Rule, Message

Write-Error ('PowerShell lint found {0} issue(s).' -f $issues.Count)
exit 1
