<#
.SYNOPSIS
    Performs non-invasive repository health checks for the CyberArk API scripts project.

.DESCRIPTION
    This script is safe to run on a lab runner. It does not authenticate to CyberArk,
    does not call PVWA APIs, and does not read or print secrets.

    It validates:
    - Required project files exist
    - PowerShell scripts parse successfully
    - Example config exists and has expected non-secret keys
    - Output/report folders can be created under the repository workspace
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoRoot = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Assert-FileExists {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file missing: $Path"
    }

    Write-Host "Found file: $Path"
}

function Assert-DirectoryExists {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory missing: $Path"
    }

    Write-Host "Found directory: $Path"
}

function Test-PowerShellSyntax {
    param([string]$ScriptPath)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            Write-Error "$ScriptPath : $($parseError.Message)"
        }
        throw "PowerShell syntax validation failed for: $ScriptPath"
    }

    Write-Host "Syntax OK: $ScriptPath"
}

function Test-ExampleConfig {
    param([string]$ConfigPath)

    $content = Get-Content -LiteralPath $ConfigPath -Raw

    $requiredPatterns = @(
        '\[CyberArk\]',
        'PVWA_URL\s*=',
        'AUTH_TYPE\s*=',
        'USERNAME\s*=',
        '\[Settings\]'
    )

    foreach ($pattern in $requiredPatterns) {
        if ($content -notmatch $pattern) {
            throw "Example config is missing expected pattern: $pattern"
        }
    }

    if ($content -match '(?i)(password\s*=\s*[^\r\n<;#]+|token\s*=\s*[^\r\n<;#]+|secret\s*=\s*[^\r\n<;#]+)') {
        throw 'Example config appears to contain a non-placeholder password, token, or secret.'
    }

    Write-Host "Example config validation OK: $ConfigPath"
}

Write-Section 'Repository Health Check'
Write-Host "Repo root: $RepoRoot"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "RepoRoot does not exist: $RepoRoot"
}

Push-Location $RepoRoot
try {
    Write-Section 'Required Files'
    Assert-FileExists -Path '.\Get-CyberArkAccounts.ps1'
    Assert-FileExists -Path '.\Filter-CyberArkAccounts.ps1'
    Assert-FileExists -Path '.\ReadMe.md'
    Assert-FileExists -Path '.\config\cyberark.example.ini'
    Assert-DirectoryExists -Path '.\config'

    Write-Section 'PowerShell Syntax'
    $scripts = Get-ChildItem -Path . -Filter '*.ps1' -Recurse | Sort-Object FullName
    if ($scripts.Count -eq 0) {
        throw 'No PowerShell scripts were found.'
    }

    foreach ($script in $scripts) {
        Test-PowerShellSyntax -ScriptPath $script.FullName
    }

    Write-Section 'Example Config'
    Test-ExampleConfig -ConfigPath '.\config\cyberark.example.ini'

    Write-Section 'Output Folder Check'
    $testOutputRoot = Join-Path $RepoRoot 'test-output'
    $testReportRoot = Join-Path $testOutputRoot 'reports'
    New-Item -ItemType Directory -Path $testReportRoot -Force | Out-Null
    Write-Host "Created/validated output folder: $testReportRoot"

    $healthSummary = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        ScriptCount = $scripts.Count
        Status = 'Passed'
    }

    $summaryPath = Join-Path $testOutputRoot 'repo-health-summary.json'
    $healthSummary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Host "Health summary written to: $summaryPath"

    Write-Section 'Result'
    Write-Host 'Repository health check passed.' -ForegroundColor Green
}
finally {
    Pop-Location
}
