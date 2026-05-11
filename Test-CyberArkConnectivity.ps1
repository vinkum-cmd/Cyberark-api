<#
.SYNOPSIS
    Performs safe, non-authenticated connectivity checks to a CyberArk PVWA URL.

.DESCRIPTION
    This script validates basic network and HTTPS reachability to a PVWA endpoint.
    It does not authenticate, does not send credentials, and does not call account/safe APIs.

    Intended for use by the self-hosted GitHub Actions runner in the lab.

.PARAMETER PVWAUrl
    Base PVWA URL, for example: https://pvwa.example.local

.PARAMETER OutputPath
    Path where the JSON connectivity summary should be written.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PVWAUrl,

    [Parameter()]
    [string]$OutputPath = '.\test-output\cyberark-connectivity-summary.json'
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function New-SafeResultObject {
    param(
        [string]$Check,
        [string]$Status,
        [string]$Details = ''
    )

    [pscustomobject]@{
        Check = $Check
        Status = $Status
        Details = $Details
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}

$results = [System.Collections.Generic.List[object]]::new()
$normalizedUrl = $PVWAUrl.Trim().TrimEnd('/')

Write-Section 'CyberArk PVWA Connectivity Check'
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"
Write-Host "PVWA URL: $normalizedUrl"

try {
    Write-Section 'Validate URL Format'

    if ($normalizedUrl -notmatch '^https?://') {
        throw 'PVWAUrl must start with http:// or https://'
    }

    $uri = [System.Uri]$normalizedUrl
    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
        throw 'PVWAUrl host could not be parsed.'
    }

    Write-Host "URL format OK. Host: $($uri.Host), Scheme: $($uri.Scheme), Port: $($uri.Port)"
    $results.Add((New-SafeResultObject -Check 'UrlFormat' -Status 'Passed' -Details "Host=$($uri.Host); Scheme=$($uri.Scheme); Port=$($uri.Port)"))

    Write-Section 'DNS Resolution'
    try {
        $dnsRecords = [System.Net.Dns]::GetHostAddresses($uri.Host)
        $ipList = ($dnsRecords | ForEach-Object { $_.IPAddressToString }) -join ', '
        Write-Host "DNS resolution OK: $ipList"
        $results.Add((New-SafeResultObject -Check 'DnsResolution' -Status 'Passed' -Details $ipList))
    }
    catch {
        Write-Warning "DNS resolution failed: $($_.Exception.Message)"
        $results.Add((New-SafeResultObject -Check 'DnsResolution' -Status 'Failed' -Details $_.Exception.Message))
    }

    Write-Section 'TCP Port Check'
    $port = if ($uri.IsDefaultPort) { if ($uri.Scheme -eq 'https') { 443 } else { 80 } } else { $uri.Port }

    try {
        $tcpClient = [System.Net.Sockets.TcpClient]::new()
        $asyncResult = $tcpClient.BeginConnect($uri.Host, $port, $null, $null)
        $connected = $asyncResult.AsyncWaitHandle.WaitOne(5000, $false)

        if (-not $connected) {
            throw "Timed out connecting to $($uri.Host):$port"
        }

        $tcpClient.EndConnect($asyncResult)
        $tcpClient.Close()
        Write-Host "TCP connectivity OK: $($uri.Host):$port"
        $results.Add((New-SafeResultObject -Check 'TcpPort' -Status 'Passed' -Details "$($uri.Host):$port"))
    }
    catch {
        Write-Warning "TCP connectivity failed: $($_.Exception.Message)"
        $results.Add((New-SafeResultObject -Check 'TcpPort' -Status 'Failed' -Details $_.Exception.Message))
    }

    Write-Section 'HTTP Reachability'
    $passwordVaultUrl = "$normalizedUrl/PasswordVault"

    try {
        $response = Invoke-WebRequest -Uri $passwordVaultUrl -Method Get -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        Write-Host "HTTP request completed. StatusCode: $($response.StatusCode)"
        $results.Add((New-SafeResultObject -Check 'HttpPasswordVault' -Status 'Passed' -Details "StatusCode=$($response.StatusCode)"))
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
        }

        if ($statusCode) {
            Write-Warning "HTTP request returned status code: $statusCode"
            $results.Add((New-SafeResultObject -Check 'HttpPasswordVault' -Status 'Warning' -Details "StatusCode=$statusCode; $($_.Exception.Message)"))
        }
        else {
            Write-Warning "HTTP request failed: $($_.Exception.Message)"
            $results.Add((New-SafeResultObject -Check 'HttpPasswordVault' -Status 'Failed' -Details $_.Exception.Message))
        }
    }
}
finally {
    Write-Section 'Write Summary'

    $outputDirectory = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    $summary = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        PVWAUrl = $normalizedUrl
        Results = $results
    }

    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Host "Connectivity summary written to: $OutputPath"
}

$failedChecks = @($results | Where-Object { $_.Status -eq 'Failed' })
if ($failedChecks.Count -gt 0) {
    throw "One or more connectivity checks failed. See summary output for details."
}

Write-Section 'Result'
Write-Host 'CyberArk PVWA connectivity check completed.' -ForegroundColor Green
