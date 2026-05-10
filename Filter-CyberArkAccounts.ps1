<#
.SYNOPSIS
    Filters and extracts specific accounts from the CyberArk export CSV based on user-provided parameters.

.DESCRIPTION
    Takes the CSV output from Script 1 and filters accounts based on various criteria.
    Supports multiple filter types, partial matching, and export to new CSV.

.PARAMETER InputCSV
    Path to the CSV file from Script 1 (required)

.PARAMETER OutputCSV
    Path for filtered output (optional, auto-generates if not provided)

.PARAMETER SafeFilter
    Filter by Safe name (partial match, case-insensitive)

.PARAMETER PlatformFilter
    Filter by Platform ID (partial match)

.PARAMETER CPMStatus
    Filter by CPM Status (success, failure, none)

.PARAMETER AutoManaged
    Filter by automatic management (true, false)

.PARAMETER NameFilter
    Filter by account name (partial match)

.PARAMETER UserNameFilter
    Filter by username (partial match)

.PARAMETER DomainFilter
    Filter by LogonDomain (exact match)

.PARAMETER OnboardingAfter
    Filter accounts onboarded after this date (yyyy-MM-dd)

.PARAMETER OnboardingBefore
    Filter accounts onboarded before this date (yyyy-MM-dd)

.PARAMETER FailedOnly
    Show only accounts with failed CPM status

.PARAMETER NotManaged
    Show only accounts with automatic management disabled

.PARAMETER OutputToConsole
    Display filtered results in console instead of CSV

.PARAMETER IncludeUnmanaged
    Include accounts with no CPM management configured
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputCSV,
    
    [Parameter()]
    [string]$OutputCSV,
    
    [Parameter()]
    [string]$SafeFilter,
    
    [Parameter()]
    [string]$PlatformFilter,
    
    [Parameter()]
    [ValidateSet("success", "failure", "none")]
    [string]$CPMStatus,
    
    [Parameter()]
    [ValidateSet("true", "false")]
    [string]$AutoManaged,
    
    [Parameter()]
    [string]$NameFilter,
    
    [Parameter()]
    [string]$UserNameFilter,
    
    [Parameter()]
    [string]$DomainFilter,
    
    [Parameter()]
    [datetime]$OnboardingAfter,
    
    [Parameter()]
    [datetime]$OnboardingBefore,
    
    [Parameter()]
    [switch]$FailedOnly,
    
    [Parameter()]
    [switch]$NotManaged,
    
    [Parameter()]
    [switch]$IncludeUnmanaged,
    
    [Parameter()]
    [switch]$OutputToConsole
)

#region Initialization
$ErrorActionPreference = "Stop"

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

function Write-Info {
    param([string]$Message)
    Write-Host "INFO: $Message" -ForegroundColor Cyan
}

# Check if input file exists
if (-not (Test-Path $InputCSV)) {
    Write-ErrorMsg "Input CSV file not found: $InputCSV"
    exit 1
}
#endregion

#region Load and Filter Data
Write-Console ""
Write-Console "=== CyberArk Account Filter Tool ===" -ForegroundColor Cyan
Write-Console ""
Write-Info "Loading CSV: $InputCSV"

# Load CSV
$accounts = Import-Csv -Path $InputCSV
Write-Success "Loaded $($accounts.Count) accounts"

# Apply filters
$filteredAccounts = $accounts
$filterLog = @()

# Helper function for safe string comparison
function MatchesFilter {
    param([string]$Value, [string]$Filter)
    if ([string]::IsNullOrEmpty($Filter)) { return $true }
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return $Value.ToLower().Contains($Filter.ToLower())
}

# 1. Safe filter
if ($SafeFilter) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { MatchesFilter $_.SafeName $SafeFilter }
    $filterLog += "Safe filter '$SafeFilter': $before -> $($filteredAccounts.Count) accounts"
}

# 2. Platform filter
if ($PlatformFilter) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { MatchesFilter $_.PlatformId $PlatformFilter }
    $filterLog += "Platform filter '$PlatformFilter': $before -> $($filteredAccounts.Count) accounts"
}

# 3. CPM Status filter
if ($CPMStatus) {
    $before = $filteredAccounts.Count
    if ($CPMStatus -eq "none") {
        $filteredAccounts = $filteredAccounts | Where-Object { [string]::IsNullOrEmpty($_.CPMStatus) }
    } else {
        $filteredAccounts = $filteredAccounts | Where-Object { $_.CPMStatus -eq $CPMStatus }
    }
    $filterLog += "CPM Status filter '$CPMStatus': $before -> $($filteredAccounts.Count) accounts"
}

# 4. AutoManaged filter
if ($AutoManaged) {
    $before = $filteredAccounts.Count
    $autoManagedBool = [bool]::Parse($AutoManaged)
    $filteredAccounts = $filteredAccounts | Where-Object { $_.AutoManaged -eq $autoManagedBool }
    $filterLog += "AutoManaged filter '$AutoManaged': $before -> $($filteredAccounts.Count) accounts"
}

# 5. Name filter
if ($NameFilter) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { MatchesFilter $_.Name $NameFilter }
    $filterLog += "Name filter '$NameFilter': $before -> $($filteredAccounts.Count) accounts"
}

# 6. UserName filter
if ($UserNameFilter) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { MatchesFilter $_.UserName $UserNameFilter }
    $filterLog += "UserName filter '$UserNameFilter': $before -> $($filteredAccounts.Count) accounts"
}

# 7. Domain filter
if ($DomainFilter) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { $_.LogonDomain -eq $DomainFilter }
    $filterLog += "Domain filter '$DomainFilter': $before -> $($filteredAccounts.Count) accounts"
}

# 8. Onboarding date range - After
if ($OnboardingAfter) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { 
        $date = [datetime]::Parse($_.OnboardingDate)
        $date -ge $OnboardingAfter
    }
    $filterLog += "Onboarding after '$($OnboardingAfter.ToString("yyyy-MM-dd"))': $before -> $($filteredAccounts.Count) accounts"
}

# 9. Onboarding date range - Before
if ($OnboardingBefore) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { 
        $date = [datetime]::Parse($_.OnboardingDate)
        $date -le $OnboardingBefore
    }
    $filterLog += "Onboarding before '$($OnboardingBefore.ToString("yyyy-MM-dd"))': $before -> $($filteredAccounts.Count) accounts"
}

# 10. Failed only (shortcut)
if ($FailedOnly) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { $_.CPMStatus -eq "failure" }
    $filterLog += "Failed only: $before -> $($filteredAccounts.Count) accounts"
}

# 11. Not managed (shortcut)
if ($NotManaged) {
    $before = $filteredAccounts.Count
    $filteredAccounts = $filteredAccounts | Where-Object { $_.AutoManaged -eq $false }
    $filterLog += "Not managed: $before -> $($filteredAccounts.Count) accounts"
}

# 12. Include unmanaged (if not already included via other filters)
if ($IncludeUnmanaged -and -not $NotManaged -and -not $AutoManaged) {
    Write-Info "Including unmanaged accounts in results"
}
#endregion

#region Output Results
Write-Console ""
Write-Console "=== FILTER RESULTS ===" -ForegroundColor Green
Write-Console ""
Write-Info "Original count: $($accounts.Count)"
Write-Info "Filtered count: $($filteredAccounts.Count)"

if ($filterLog.Count -gt 0) {
    Write-Console ""
    Write-Console "Applied filters:" -ForegroundColor Cyan
    foreach ($log in $filterLog) {
        Write-Console "  - $log" -ForegroundColor DarkGray
    }
}

if ($filteredAccounts.Count -eq 0) {
    Write-WarningMsg "No accounts match the specified filters"
    exit 0
}

# Display summary statistics
Write-Console ""
Write-Console "=== SUMMARY STATISTICS ===" -ForegroundColor Cyan
Write-Console ""

$platforms = $filteredAccounts | Group-Object PlatformId | Select-Object Name, Count | Sort-Object Count -Descending
Write-Console "Platform Distribution:" -ForegroundColor Yellow
foreach ($platform in $platforms | Select-Object -First 10) {
    $platformName = if ([string]::IsNullOrEmpty($platform.Name)) { "(Empty)" } else { $platform.Name }
    Write-Console "  $platformName : $($platform.Count) accounts" -ForegroundColor DarkGray
}

Write-Console ""
$safeStats = $filteredAccounts | Group-Object SafeName | Select-Object Name, Count | Sort-Object Count -Descending
Write-Console "Safe Distribution:" -ForegroundColor Yellow
foreach ($safe in $safeStats | Select-Object -First 10) {
    $safeName = if ([string]::IsNullOrEmpty($safe.Name)) { "(Empty)" } else { $safe.Name }
    Write-Console "  $safeName : $($safe.Count) accounts" -ForegroundColor DarkGray
}

Write-Console ""
$cpmStats = $filteredAccounts | Group-Object CPMStatus | Select-Object Name, Count
Write-Console "CPM Status:" -ForegroundColor Yellow
foreach ($cpm in $cpmStats) {
    $statusName = if ([string]::IsNullOrEmpty($cpm.Name)) { "Not Configured" } else { $cpm.Name }
    Write-Console "  $statusName : $($cpm.Count) accounts" -ForegroundColor DarkGray
}

Write-Console ""
$autoStats = $filteredAccounts | Group-Object AutoManaged | Select-Object Name, Count
Write-Console "Auto Management:" -ForegroundColor Yellow
foreach ($auto in $autoStats) {
    $autoStatus = if ($auto.Name -eq "True") { "Managed" } else { "Not Managed" }
    Write-Console "  $autoStatus : $($auto.Count) accounts" -ForegroundColor DarkGray
}

# Output to CSV or Console
if ($OutputToConsole) {
    Write-Console ""
    Write-Console "=== FILTERED ACCOUNTS ===" -ForegroundColor Cyan
    Write-Console ""
    
    # Display in table format
    $displayData = $filteredAccounts | Select-Object ID, Name, SafeName, PlatformId, CPMStatus, AutoManaged, OnboardingDate | 
        Sort-Object SafeName, Name
    
    $displayData | Format-Table -AutoSize -Wrap
}
else {
    # Determine output path
    if (-not $OutputCSV) {
        $inputDir = Split-Path $InputCSV -Parent
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $filterName = ""
        if ($SafeFilter) { $filterName += "_$SafeFilter" }
        if ($CPMStatus) { $filterName += "_$CPMStatus" }
        if ($FailedOnly) { $filterName += "_failed" }
        if (-not $filterName) { $filterName = "_filtered" }
        $OutputCSV = Join-Path $inputDir "filtered_accounts$filterName`_$timestamp.csv"
    }
    
    # Ensure output directory exists
    $outputDir = Split-Path $OutputCSV -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    # Export filtered accounts
    $filteredAccounts | Export-Csv -Path $OutputCSV -NoTypeInformation -Encoding UTF8
    Write-Success "Filtered accounts exported to: $OutputCSV"
    
    # Save filter summary
    $summaryFile = $OutputCSV -replace "\.csv$", "_filter_summary.json"
    $summary = @{
        FilterTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        InputFile = $InputCSV
        OriginalCount = $accounts.Count
        FilteredCount = $filteredAccounts.Count
        Filters = $filterLog
        OutputFile = $OutputCSV
    }
    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryFile
    Write-Success "Filter summary saved to: $summaryFile"
}

Write-Console ""
Write-Success "Filter operation completed!"
#endregion