<#
.SYNOPSIS
    Bulk updates CyberArk account PlatformId and/or UserName values by AccountId.

.DESCRIPTION
    Reads a CSV file containing CyberArk account IDs and target field values, then updates
    the requested account properties through the PVWA REST API.

    This script is designed for controlled bulk updates. It defaults to dry-run mode.
    No changes are sent to CyberArk unless -Execute is provided.

    Supported update fields:
    - PlatformId  -> PATCH path /platformId
    - UserName    -> PATCH path /userName

    Required CSV columns:
    - AccountId

    Optional CSV columns:
    - NewPlatformId
    - NewUserName
    - Comment

.EXAMPLE
    .\Update-CyberArkAccountPlatformUser.ps1 -ConfigPath .\config\cyberark.ini -InputCsv .\input\account-updates.csv

    Dry-run. Shows what would be updated without calling PATCH.

.EXAMPLE
    .\Update-CyberArkAccountPlatformUser.ps1 -ConfigPath .\config\cyberark.ini -InputCsv .\input\account-updates.csv -Execute

    Executes updates against CyberArk.

.NOTES
    Uses CyberArk/PVWA API endpoints:
    - POST  /PasswordVault/API/Auth/{CyberArk|LDAP}/Logon
    - PATCH /PasswordVault/API/Accounts/{accountId}
    - POST  /PasswordVault/API/Auth/Logoff

    Do not commit real cyberark.ini files or CSV files containing sensitive data.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [Parameter()]
    [string]$OutputCsv,

    [Parameter()]
    [switch]$Execute,

    [Parameter()]
    [switch]$EnableDebug
)

$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "INFO: $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "SUCCESS: $Message" -ForegroundColor Green
}

function Write-WarningMsg {
    param([string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Write-DebugLog {
    param([string]$Message)
    if ($EnableDebug) {
        Write-Host "DEBUG: $Message" -ForegroundColor DarkGray
    }
}

function Get-ConfigFromIni {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    $config = @{}
    $section = ''

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith(';') -or $line.StartsWith('#')) {
            return
        }

        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1]
            if (-not $config.ContainsKey($section)) {
                $config[$section] = @{}
            }
            return
        }

        if ($line -match '^([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim().Trim('"')
            if (-not $config.ContainsKey($section)) {
                $config[$section] = @{}
            }
            $config[$section][$key] = $value
        }
    }

    return $config
}

function ConvertTo-PlainTextPassword {
    param([securestring]$SecurePassword)

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-AuthToken {
    param(
        [string]$PVWAUrl,
        [string]$AuthType,
        [string]$Username,
        [securestring]$Password
    )

    $authUrl = "$PVWAUrl/PasswordVault/API/Auth/$($AuthType.ToLower())/Logon"
    $plainPassword = ConvertTo-PlainTextPassword -SecurePassword $Password

    $body = @{
        username = $Username
        password = $plainPassword
        concurrentSession = 'true'
    } | ConvertTo-Json -Depth 5

    Write-DebugLog "Calling auth endpoint: $authUrl"
    return Invoke-RestMethod -Uri $authUrl -Method Post -Body $body -ContentType 'application/json'
}

function Invoke-CyberArkLogoff {
    param(
        [string]$PVWAUrl,
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return
    }

    try {
        $logoffUrl = "$PVWAUrl/PasswordVault/API/Auth/Logoff"
        Invoke-RestMethod -Uri $logoffUrl -Method Post -Headers @{ Authorization = $Token } -ContentType 'application/json' -ErrorAction SilentlyContinue | Out-Null
        Write-DebugLog 'CyberArk logoff completed.'
    }
    catch {
        Write-WarningMsg "Logoff failed: $($_.Exception.Message)"
    }
}

function New-UpdateOperationList {
    param([object]$Row)

    $operations = [System.Collections.Generic.List[object]]::new()

    if ($Row.PSObject.Properties.Name -contains 'NewPlatformId' -and -not [string]::IsNullOrWhiteSpace($Row.NewPlatformId)) {
        $operations.Add([pscustomobject]@{
            op = 'replace'
            path = '/platformId'
            value = $Row.NewPlatformId.Trim()
        })
    }

    if ($Row.PSObject.Properties.Name -contains 'NewUserName' -and -not [string]::IsNullOrWhiteSpace($Row.NewUserName)) {
        $operations.Add([pscustomobject]@{
            op = 'replace'
            path = '/userName'
            value = $Row.NewUserName.Trim()
        })
    }

    return @($operations)
}

function Invoke-AccountPatch {
    param(
        [string]$PVWAUrl,
        [string]$Token,
        [string]$AccountId,
        [array]$Operations
    )

    $encodedAccountId = [System.Uri]::EscapeDataString($AccountId)
    $url = "$PVWAUrl/PasswordVault/API/Accounts/$encodedAccountId"
    $body = $Operations | ConvertTo-Json -Depth 10

    Write-DebugLog "PATCH $url"
    Write-DebugLog "Operations: $body"

    return Invoke-RestMethod -Uri $url -Method Patch -Headers @{ Authorization = $Token } -Body $body -ContentType 'application/json'
}

function New-ResultObject {
    param(
        [object]$Row,
        [string]$Status,
        [string]$Message,
        [array]$Operations
    )

    [pscustomobject]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        AccountId = $Row.AccountId
        NewPlatformId = if ($Row.PSObject.Properties.Name -contains 'NewPlatformId') { $Row.NewPlatformId } else { '' }
        NewUserName = if ($Row.PSObject.Properties.Name -contains 'NewUserName') { $Row.NewUserName } else { '' }
        OperationCount = if ($Operations) { $Operations.Count } else { 0 }
        Status = $Status
        Message = $Message
        Comment = if ($Row.PSObject.Properties.Name -contains 'Comment') { $Row.Comment } else { '' }
    }
}

try {
    Write-Info 'Starting CyberArk account PlatformId/UserName update utility.'

    if (-not (Test-Path -LiteralPath $InputCsv -PathType Leaf)) {
        throw "Input CSV not found: $InputCsv"
    }

    if (-not $OutputCsv) {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $outputDirectory = Join-Path (Get-Location).Path 'output'
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        $OutputCsv = Join-Path $outputDirectory "account-platform-user-update-results_$timestamp.csv"
    }

    $config = Get-ConfigFromIni -Path $ConfigPath
    $cyberArkConfig = $config['CyberArk']

    if (-not $cyberArkConfig) {
        throw 'Missing [CyberArk] section in config file.'
    }

    $pvwaUrl = $cyberArkConfig['PVWA_URL'].TrimEnd('/')
    $authType = $cyberArkConfig['AUTH_TYPE']
    $username = $cyberArkConfig['USERNAME']
    $plainConfigPassword = $cyberArkConfig['PASSWORD']

    if ([string]::IsNullOrWhiteSpace($pvwaUrl)) { throw 'PVWA_URL is required in config.' }
    if ([string]::IsNullOrWhiteSpace($authType)) { throw 'AUTH_TYPE is required in config.' }
    if ($authType -notin @('CyberArk', 'LDAP')) { throw 'AUTH_TYPE must be CyberArk or LDAP.' }
    if ([string]::IsNullOrWhiteSpace($username)) { throw 'USERNAME is required in config.' }

    if ([string]::IsNullOrWhiteSpace($plainConfigPassword)) {
        if (-not $Execute) {
            $securePassword = ConvertTo-SecureString 'dry-run-placeholder' -AsPlainText -Force
        }
        else {
            throw 'PASSWORD is required in config for non-interactive Execute mode.'
        }
    }
    else {
        $securePassword = ConvertTo-SecureString $plainConfigPassword -AsPlainText -Force
    }

    $rows = @(Import-Csv -LiteralPath $InputCsv)
    if ($rows.Count -eq 0) {
        throw 'Input CSV has no rows.'
    }

    $requiredColumns = @('AccountId')
    foreach ($requiredColumn in $requiredColumns) {
        if ($rows[0].PSObject.Properties.Name -notcontains $requiredColumn) {
            throw "Input CSV is missing required column: $requiredColumn"
        }
    }

    if ($rows[0].PSObject.Properties.Name -notcontains 'NewPlatformId' -and $rows[0].PSObject.Properties.Name -notcontains 'NewUserName') {
        throw 'Input CSV must contain at least one update column: NewPlatformId or NewUserName.'
    }

    if ($Execute) {
        Write-WarningMsg 'EXECUTE mode is enabled. PATCH requests will be sent to CyberArk.'
        $token = Get-AuthToken -PVWAUrl $pvwaUrl -AuthType $authType -Username $username -Password $securePassword
        Write-Success 'Authenticated to CyberArk.'
    }
    else {
        Write-WarningMsg 'Dry-run mode. No CyberArk updates will be made. Add -Execute to apply changes.'
        $token = $null
    }

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $accountId = $row.AccountId
        $operations = New-UpdateOperationList -Row $row

        if ([string]::IsNullOrWhiteSpace($accountId)) {
            $results.Add((New-ResultObject -Row $row -Status 'Skipped' -Message 'AccountId is empty.' -Operations $operations))
            continue
        }

        if ($operations.Count -eq 0) {
            $results.Add((New-ResultObject -Row $row -Status 'Skipped' -Message 'No update values provided.' -Operations $operations))
            continue
        }

        $operationSummary = ($operations | ForEach-Object { "$($_.path)=$($_.value)" }) -join '; '

        if (-not $Execute) {
            Write-Host "DRY-RUN: AccountId=$accountId => $operationSummary"
            $results.Add((New-ResultObject -Row $row -Status 'DryRun' -Message $operationSummary -Operations $operations))
            continue
        }

        try {
            if ($PSCmdlet.ShouldProcess($accountId, "Update CyberArk account fields: $operationSummary")) {
                Invoke-AccountPatch -PVWAUrl $pvwaUrl -Token $token -AccountId $accountId -Operations $operations | Out-Null
                Write-Success "Updated AccountId=$accountId => $operationSummary"
                $results.Add((New-ResultObject -Row $row -Status 'Updated' -Message $operationSummary -Operations $operations))
            }
        }
        catch {
            Write-ErrorMsg "Failed AccountId=$accountId : $($_.Exception.Message)"
            $results.Add((New-ResultObject -Row $row -Status 'Failed' -Message $_.Exception.Message -Operations $operations))
        }
    }

    $outputDirectory = Split-Path -Path $OutputCsv -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    $results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Success "Results written to: $OutputCsv"

    $failedCount = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    if ($failedCount -gt 0) {
        throw "$failedCount account update(s) failed. Review output CSV."
    }

    Write-Success 'CyberArk account PlatformId/UserName update utility completed.'
}
finally {
    if ($Execute -and $token) {
        Invoke-CyberArkLogoff -PVWAUrl $pvwaUrl -Token $token
    }
}
