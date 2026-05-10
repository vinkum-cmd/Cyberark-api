<#
.SYNOPSIS
    Exports all CyberArk accounts to CSV (excluding passwords) with full details for analysis.
    Focus: Platform, Safe, Account Onboarding, CPM Status.

.DESCRIPTION
    Connects to CyberArk PVWA REST API (v14.2), fetches all accounts across all safes,
    exports to CSV files in C:\temp\reports\{username}_{timestamp}\
    Excludes: passwords, secrets, credential content.
    Supports: CyberArk & LDAP authentication only.
    Input methods: INI config file OR interactive manual input.

    Features:
    - Token expiry handling (15 minutes, auto-refresh on 401)
    - Pagination with offset/limit (500 per request) using nextLink
    - Resume capability via checkpoint file
    - CSV split at 100,000 rows per file
    - Partial safe name filtering
    - Debug logging
    - Retry logic
    - No credential values ever exported
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath,
    
    [Parameter()]
    [string]$PVWA_URL,
    
    [Parameter()]
    [ValidateSet("CyberArk", "LDAP")]
    [string]$AuthType,
    
    [Parameter()]
    [string]$Username,
    
    [Parameter()]
    [securestring]$Password,
    
    [Parameter()]
    [string]$SafeFilter,
    
    [Parameter()]
    [switch]$EnableDebug
)

#region Initialization
$ErrorActionPreference = "Stop"
$script:EnableDebugMode = $EnableDebug

function Write-DebugLog {
    param([string]$Message, [string]$Level = "INFO")
    if ($script:EnableDebugMode) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $logMessage = "[$timestamp] [$Level] $Message"
        Write-Host $logMessage -ForegroundColor DarkGray
        if ($script:DebugLogFile) {
            Add-Content -Path $script:DebugLogFile -Value $logMessage
        }
    }
}

function Write-Console {
    param([string]$Message, [string]$ForegroundColor = "White")
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Write-Success {
    param([string]$Message)
    Write-Host "SUCCESS: $Message" -ForegroundColor Green
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Write-WarningMsg {
    param([string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function New-DirectoryIfNotExists {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-DebugLog "Created directory: $Path"
    }
}
#endregion

#region Input Collection
function Get-ConfigFromINI {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }
    
    $config = @{}
    $section = ""
    
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith(";") -or $line.StartsWith("#")) {
            return
        }
        
        if ($line -match "^\[(.+)\]$") {
            $section = $matches[1]
            $config[$section] = @{}
        }
        elseif ($line -match "^([^=]+)=(.*)$") {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $config[$section][$key] = $value
        }
    }
    
    return $config
}

function Get-ManualInput {
    Write-Console ""
    Write-Console "=== CyberArk Account Export Tool ===" -ForegroundColor Cyan
    Write-Console ""
    
    do {
        $pvwa = Read-Host "PVWA URL (example: https://cyberark.example.com)"
        if ($pvwa -match "^https?://.+") { break }
        Write-ErrorMsg "Invalid URL format. Please include http:// or https://"
    } while ($true)
    
    do {
        $auth = Read-Host "Authentication Type (CyberArk/LDAP)"
        if ($auth -in @("CyberArk", "LDAP")) { break }
        Write-ErrorMsg "Invalid. Please enter CyberArk or LDAP"
    } while ($true)
    
    $user = Read-Host "Username"
    $password = Read-Host "Password" -AsSecureString
    
    $safeFilter = Read-Host "Safe filter (press Enter for all safes)"
    
    $enableDebug = Read-Host "Enable debug logging? (Y/N)"
    $script:EnableDebugMode = ($enableDebug -eq "Y")
    
    return @{
        PVWA_URL = $pvwa
        AuthType = $auth
        Username = $user
        Password = $password
        SafeFilter = $safeFilter
        EnableDebug = $script:EnableDebugMode
    }
}

function Get-InputParameters {
    if ($ConfigPath) {
        Write-Console "Loading configuration from: $ConfigPath" -ForegroundColor Green
        $config = Get-ConfigFromINI -Path $ConfigPath
        $cyberArk = $config["CyberArk"]
        $settings = $config["Settings"]
        
        if ($settings -and $settings["DEBUG"] -eq "true") {
            $script:EnableDebugMode = $true
        }
        
        $password = $null
        
        if ($cyberArk["PASSWORD"]) {
            $password = ConvertTo-SecureString $cyberArk["PASSWORD"] -AsPlainText -Force
        } else {
            Write-WarningMsg "No password found in INI file. Please enter password."
            $password = Read-Host "Password" -AsSecureString
        }
        
        return @{
            PVWA_URL = $cyberArk["PVWA_URL"]
            AuthType = $cyberArk["AUTH_TYPE"]
            Username = $cyberArk["USERNAME"]
            Password = $password
            SafeFilter = if ($settings -and $settings["SAFE_FILTER"]) { $settings["SAFE_FILTER"] } else { $null }
            EnableDebug = $script:EnableDebugMode
        }
    } else {
        return Get-ManualInput
    }
}

$params = Get-InputParameters
$script:EnableDebugMode = $params.EnableDebug

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$folderName = "$($params.Username)_$timestamp"
$baseOutputPath = "C:\temp\reports\$folderName"
$debugOutputPath = "C:\temp\reports\debug_$folderName"

New-DirectoryIfNotExists -Path $baseOutputPath
if ($script:EnableDebugMode) {
    New-DirectoryIfNotExists -Path $debugOutputPath
    $script:DebugLogFile = Join-Path $debugOutputPath "debug.log"
    Write-DebugLog "CyberArk Account Export Started"
    Write-DebugLog "Output directory: $baseOutputPath"
}

Write-Success "Output will be saved to: $baseOutputPath"
#endregion

#region Authentication
function Get-AuthToken {
    param(
        [string]$PVWA_URL,
        [string]$AuthType,
        [string]$Username,
        [securestring]$Password
    )
    
    $authURL = "$PVWA_URL/PasswordVault/API/Auth/$($AuthType.ToLower())/Logon"
    Write-DebugLog "Auth URL: $authURL"
    
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    $body = @{
        username = $Username
        password = $plainPassword
        concurrentSession = "true"
    }
    
    $jsonBody = $body | ConvertTo-Json
    
    $attempt = 0
    while ($attempt -lt 4) {
        try {
            $response = Invoke-RestMethod -Uri $authURL -Method Post -Body $jsonBody -ContentType "application/json"
            Write-DebugLog "Authentication successful"
            return $response
        }
        catch {
            $attempt++
            Write-DebugLog "Auth attempt $attempt failed" -Level "WARN"
            
            if ($attempt -eq 3) {
                Write-WarningMsg "Authentication failed after 3 attempts. Please enter new credentials."
                $newPassword = Read-Host "Enter new password" -AsSecureString
                if ($newPassword) {
                    $Password = $newPassword
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
                    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                    $body["password"] = $plainPassword
                    $jsonBody = $body | ConvertTo-Json
                    $attempt = 0
                    continue
                }
            }
            elseif ($attempt -ge 4) {
                throw "Authentication failed after 4 attempts. Exiting."
            }
            
            Start-Sleep -Seconds 2
        }
    }
}
#endregion

#region Token Management
$script:CurrentToken = $null
$script:TokenObtainedTime = $null

function Update-Token {
    Write-DebugLog "Updating authentication token"
    $script:CurrentToken = Get-AuthToken -PVWA_URL $params.PVWA_URL -AuthType $params.AuthType -Username $params.Username -Password $params.Password
    $script:TokenObtainedTime = Get-Date
}

function Get-ValidToken {
    $tokenAge = 15
    if ($script:TokenObtainedTime) {
        $tokenAge = ((Get-Date) - $script:TokenObtainedTime).TotalMinutes
    }
    
    if ((-not $script:CurrentToken) -or ($tokenAge -ge 14)) {
        Write-DebugLog "Token expired or missing, refreshing..."
        Update-Token
    }
    return $script:CurrentToken
}

function Invoke-WithTokenRefresh {
    param([scriptblock]$ScriptBlock)
    try {
        return & $ScriptBlock
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401) {
            Write-DebugLog "Token 401 detected, refreshing token and retrying"
            Update-Token
            return & $ScriptBlock
        }
        throw
    }
}
#endregion

#region API Calls
function Export-AccountsToCSV {
    param(
        [array]$Accounts,
        [string]$Path,
        [int]$BatchNumber
    )
    
    Write-DebugLog "Exporting $($Accounts.Count) accounts to $Path"
    
    function Convert-EpochToDateString {
        param($EpochValue)

        if ($null -eq $EpochValue -or "$EpochValue" -eq "") {
            return ""
        }

        try {
            return (Get-Date -Date "1970-01-01 00:00:00").AddSeconds([double]$EpochValue).ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch {
            return ""
        }
    }
    
    # Define CSV headers
    $headers = @(
        "ID", "Name", "UserName", "Address", "SafeName", "PlatformId",
        "AutoManaged", "CPMStatus", "LastModifiedTime", "LastModifiedDate", "ManualManagementReason",
        "CreatedTime", "OnboardingDate", "CategoryModificationTime", "CategoryModificationDate",
        "LogonDomain", "FMPrivileged"
    )
    
    # Build CSV content
    $csvLines = [System.Collections.Generic.List[string]]::new()
    $csvLines.Add(($headers -join ","))
    
    foreach ($account in $Accounts) {
        # Extract platform account properties
        $logonDomain = ""
        $fmPrivileged = ""
        if ($account.platformAccountProperties) {
            $logonDomain = $account.platformAccountProperties.LogonDomain
            $fmPrivileged = $account.platformAccountProperties.FMPrivileged
        }
        
        # Extract secret management properties
        $autoManaged = ""
        $cpmStatus = ""
        $lastModified = ""
        $manualReason = ""
        if ($account.secretManagement) {
            $autoManaged = $account.secretManagement.automaticManagementEnabled
            $cpmStatus = $account.secretManagement.status
            $lastModified = $account.secretManagement.lastModifiedTime
            $manualReason = $account.secretManagement.manualManagementReason
        }
        
        # Convert CyberArk epoch values into readable dates.
        $lastModifiedDate = Convert-EpochToDateString -EpochValue $lastModified
        $onboardingDate = Convert-EpochToDateString -EpochValue $account.createdTime
        $categoryModificationDate = Convert-EpochToDateString -EpochValue $account.categoryModificationTime
        
        # Build row values
        $rowValues = @(
            $account.id,
            $account.name,
            $account.userName,
            $account.address,
            $account.safeName,
            $account.platformId,
            $autoManaged,
            $cpmStatus,
            $lastModified,
            $lastModifiedDate,
            $manualReason,
            $account.createdTime,
            $onboardingDate,
            $account.categoryModificationTime,
            $categoryModificationDate,
            $logonDomain,
            $fmPrivileged
        )
        
        # Escape each value for CSV (handle commas, quotes, and nulls)
        $escapedValues = @()
        foreach ($val in $rowValues) {
            if ($val -eq $null -or $val -eq "") {
                $escapedValues += ""
            }
            else {
                $stringVal = $val.ToString()
                if ($stringVal -match ',' -or $stringVal -match '"' -or $stringVal -match "`n") {
                    $stringVal = $stringVal -replace '"', '""'
                    $escapedValues += "`"$stringVal`""
                }
                else {
                    $escapedValues += $stringVal
                }
            }
        }
        
        $csvLines.Add(($escapedValues -join ","))
    }
    
    # Write to file with UTF-8 BOM (Excel compatible)
    [System.IO.File]::WriteAllLines($Path, $csvLines, [System.Text.UTF8Encoding]::new($true))
    Write-DebugLog "Export completed: $Path"
    
    # Save metadata for this batch
    $metadataFile = $Path -replace "\.csv$", "_metadata.json"
    $metadata = @{
        BatchNumber = $BatchNumber
        AccountCount = $Accounts.Count
        ExportTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        SafeFilter = $params.SafeFilter
        Username = $params.Username
    }
    $metadata | ConvertTo-Json | Set-Content -Path $metadataFile
}

function Get-AllAccounts {
    param([string]$Token)
    
    $allAccounts = @()
    $batchNumber = 1
    $totalFetched = 0
    $nextLink = "Accounts?limit=500&offset=0"
    
    $checkpointFile = Join-Path $baseOutputPath "checkpoint.json"
    
    # Check for resume
    if (Test-Path $checkpointFile) {
        $checkpoint = Get-Content $checkpointFile | ConvertFrom-Json
        $nextLink = $checkpoint.NextLink
        $batchNumber = $checkpoint.BatchNumber
        $totalFetched = $checkpoint.TotalFetched
        Write-WarningMsg "Resuming from: $nextLink"
    }
    
    Write-Console ""
    Write-Console "Fetching accounts from CyberArk..." -ForegroundColor Cyan
    
    while ($nextLink) {
        $url = "$($params.PVWA_URL)/PasswordVault/API/$nextLink"
        $headers = @{ "Authorization" = $Token }
        
        Write-Progress -Activity "Fetching Accounts" -Status "Total fetched: $totalFetched | Batch: $batchNumber"
        
        $response = Invoke-WithTokenRefresh -ScriptBlock {
            Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ContentType "application/json"
        }
        
        if ((-not $response) -or (-not $response.value) -or ($response.value.Count -eq 0)) {
            Write-DebugLog "No more accounts found"
            break
        }
        
        $pageCount = $response.value.Count
        $totalFetched += $pageCount
        Write-DebugLog "Fetched $pageCount accounts (Total: $totalFetched)"
        
        # Apply safe filter if specified
        $filteredAccounts = $response.value
        if ($params.SafeFilter) {
            $filteredAccounts = @()
            foreach ($acct in $response.value) {
                if ($acct.safeName -like "*$($params.SafeFilter)*") {
                    $filteredAccounts += $acct
                }
            }
            Write-DebugLog "Filter '$($params.SafeFilter)' kept $($filteredAccounts.Count) of $pageCount accounts"
        }
        
        $allAccounts += $filteredAccounts
        
        # Split CSV every 100,000 rows
        if ($allAccounts.Count -ge 100000) {
            $batchFile = Join-Path $baseOutputPath "accounts_batch$batchNumber.csv"
            Export-AccountsToCSV -Accounts $allAccounts -Path $batchFile -BatchNumber $batchNumber
            Write-Success "Exported batch $batchNumber with $($allAccounts.Count) accounts"
            $allAccounts = @()
            $batchNumber++
            
            # Save checkpoint
            $checkpoint = @{
                NextLink = $response.nextLink
                BatchNumber = $batchNumber
                TotalFetched = $totalFetched
                Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            $checkpoint | ConvertTo-Json | Set-Content -Path $checkpointFile
            Write-DebugLog "Checkpoint saved"
        }
        
        # Get next link for pagination
        $nextLink = $response.nextLink
        
        # Small delay to avoid rate limiting
        Start-Sleep -Milliseconds 100
    }
    
    # Export remaining accounts
    if ($allAccounts.Count -gt 0) {
        $batchFile = Join-Path $baseOutputPath "accounts_batch$batchNumber.csv"
        Export-AccountsToCSV -Accounts $allAccounts -Path $batchFile -BatchNumber $batchNumber
        Write-Success "Exported final batch $batchNumber with $($allAccounts.Count) accounts"
    }
    
    # Clean up checkpoint on successful completion
    if (Test-Path $checkpointFile) {
        Remove-Item $checkpointFile
        Write-DebugLog "Checkpoint file removed"
    }
    
    # Save summary
    $summaryFile = Join-Path $baseOutputPath "export_summary.json"
    $summary = @{
        ExportTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Username = $params.Username
        PVWA_URL = $params.PVWA_URL
        AuthType = $params.AuthType
        SafeFilter = if ($params.SafeFilter) { $params.SafeFilter } else { "All Safes" }
        TotalAccountsFetched = $totalFetched
        BatchesCreated = $batchNumber
    }
    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryFile
    
    Write-Progress -Activity "Fetching Accounts" -Completed
    return $totalFetched
}
#endregion

#region Main Execution
function Main {
    try {
        Write-Console ""
        Write-Console "Connecting to CyberArk PVWA..." -ForegroundColor Cyan
        $token = Get-ValidToken
        
        Write-Success "Connected successfully to $($params.PVWA_URL)"
        Write-DebugLog "Session token obtained"
        
        if ($params.SafeFilter) {
            Write-WarningMsg "Safe filter active: '$($params.SafeFilter)' (partial match)"
        }
        
        Write-Console ""
        Write-Console "Starting account export. This may take a while..." -ForegroundColor Cyan
        Write-Console "NOTE: Password values are NEVER exported for security" -ForegroundColor Yellow
        
        $startTime = Get-Date
        $totalAccounts = Get-AllAccounts -Token $token
        $endTime = Get-Date
        $duration = [math]::Round(($endTime - $startTime).TotalSeconds, 2)
        
        Write-Console ""
        Write-Console "=== EXPORT COMPLETED ===" -ForegroundColor Green
        Write-Console ""
        Write-Success "Total accounts exported: $totalAccounts"
        Write-Success "Total time: $duration seconds"
        Write-Success "Output location: $baseOutputPath"
        
        if ($script:EnableDebugMode) {
            Write-Success "Debug logs saved to: $debugOutputPath"
        }
        
        Write-Console ""
        Write-Console "Next steps:" -ForegroundColor Cyan
        Write-Console "  1. Open the CSV file in Excel"
        Write-Console "  2. Review platform distribution, safe counts, and CPM status"
        Write-Console "  3. Use Script 2 to filter specific data"
        Write-Console ""
    }
    catch {
        Write-ErrorMsg $_.Exception.Message
        Write-DebugLog "Fatal error: $($_.Exception.Message)" -Level "ERROR"
        Write-DebugLog "Stack trace: $($_.ScriptStackTrace)" -Level "DEBUG"
        exit 1
    }
    finally {
        if ($script:CurrentToken) {
            try {
                $logoffUrl = "$($params.PVWA_URL)/PasswordVault/API/Auth/Logoff"
                $headers = @{ "Authorization" = $script:CurrentToken }
                Invoke-RestMethod -Uri $logoffUrl -Method Post -Headers $headers -ContentType "application/json" -ErrorAction SilentlyContinue
                Write-DebugLog "Logged off successfully"
            }
            catch {
                Write-DebugLog "Logoff failed: $_" -Level "WARN"
            }
        }
    }
}

Main
#endregion
