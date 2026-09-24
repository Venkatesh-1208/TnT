<#
.SYNOPSIS
    Azure Resource Version & Compliance Report - Read Only

.DESCRIPTION
    Scans ONE Azure subscription and generates a resource inventory plus
    version/compliance information for selected Azure services.

    Supported checks:
      - AKS clusters + node pools
      - App Service / Web Apps runtime
      - PostgreSQL Flexible Server
      - Azure SQL Databases compatibility level
      - Azure Cache for Redis
      - Azure Advisor recommendations (best-effort)

    IMPORTANT:
      This script is READ-ONLY. It does not create, update, delete, restart,
      scale, or otherwise modify Azure resources.

.REQUIREMENTS
    Az.Accounts
    Az.ResourceGraph
    Az.Aks
    Az.Websites
    Az.PostgreSql
    Az.Sql
    Az.RedisCache

    Optional:
      ImportExcel - only if you want XLSX output.

.EXAMPLE
    .\Get-AzureResourceCompliance.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Get-AzureResourceCompliance.ps1 `
        -SubscriptionId "00000000-0000-0000-0000-000000000000" `
        -OutputPath "C:\Reports\AzureCompliance"

.NOTES
    Version policy values are intentionally supplied as parameters so that
    you can change organizational policy without changing the collectors.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\Azure-Compliance-Report",

    # Organization policy examples. Change these to your approved standards.
    [Parameter(Mandatory = $false)]
    [string]$AksMinimumVersion = "1.31",

    [Parameter(Mandatory = $false)]
    [string]$AksRecommendedVersion = "1.34",

    [Parameter(Mandatory = $false)]
    [string]$PostgreSqlMinimumVersion = "14",

    [Parameter(Mandatory = $false)]
    [string]$PostgreSqlRecommendedVersion = "16",

    [Parameter(Mandatory = $false)]
    [string]$NodeMinimumMajorVersion = "20",

    [Parameter(Mandatory = $false)]
    [string]$NodeRecommendedMajorVersion = "22",

    [Parameter(Mandatory = $false)]
    [string]$RedisMinimumMajorVersion = "6",

    [Parameter(Mandatory = $false)]
    [switch]$SkipAdvisor
)

$ErrorActionPreference = "Stop"
$scriptStart = Get-Date

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    switch ($Level) {
        "INFO"  { Write-Host "[$timestamp] [INFO ] $Message" }
        "WARN"  { Write-Host "[$timestamp] [WARN ] $Message" -ForegroundColor Yellow }
        "ERROR" { Write-Host "[$timestamp] [ERROR] $Message" -ForegroundColor Red }
    }
}

function Ensure-Module {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required PowerShell module '$Name' is not installed. Install it with: Install-Module $Name -Scope CurrentUser"
    }

    Import-Module $Name -ErrorAction Stop
}

function Get-VersionParts {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return @()
    }

    # Handles values such as:
    # 1.34
    # 1.34.1
    # 20
    # 20.11
    $match = [regex]::Match($Version, '(\d+)(?:\.(\d+))?(?:\.(\d+))?')

    if (-not $match.Success) {
        return @()
    }

    $major = [int]$match.Groups[1].Value
    $minor = if ($match.Groups[2].Success) { [int]$match.Groups[2].Value } else { 0 }
    $patch = if ($match.Groups[3].Success) { [int]$match.Groups[3].Value } else { 0 }

    return @($major, $minor, $patch)
}

function Compare-VersionString {
    param(
        [string]$Current,
        [string]$Target
    )

    $c = Get-VersionParts $Current
    $t = Get-VersionParts $Target

    if ($c.Count -eq 0 -or $t.Count -eq 0) {
        return $null
    }

    for ($i = 0; $i -lt 3; $i++) {
        if ($c[$i] -lt $t[$i]) { return -1 }
        if ($c[$i] -gt $t[$i]) { return 1 }
    }

    return 0
}

function Get-ComplianceStatus {
    param(
        [string]$CurrentVersion,
        [string]$MinimumVersion,
        [string]$RecommendedVersion
    )

    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
        return "Unknown"
    }

    $minimumComparison = Compare-VersionString -Current $CurrentVersion -Target $MinimumVersion

    if ($null -eq $minimumComparison) {
        return "Unknown"
    }

    if ($minimumComparison -lt 0) {
        return "Upgrade Required"
    }

    $recommendedComparison = Compare-VersionString -Current $CurrentVersion -Target $RecommendedVersion

    if ($null -eq $recommendedComparison) {
        return "Compliant"
    }

    if ($recommendedComparison -lt 0) {
        return "Upgrade Recommended"
    }

    return "Compliant"
}

function Get-NodeMajorVersion {
    param([string]$Runtime)

    if ([string]::IsNullOrWhiteSpace($Runtime)) {
        return $null
    }

    $match = [regex]::Match($Runtime, 'NODE\|?(\d+)|node\|?(\d+)|nodejs\|?(\d+)', "IgnoreCase")

    if ($match.Success) {
        foreach ($group in $match.Groups[1..3]) {
            if ($group.Success) {
                return $group.Value
            }
        }
    }

    return $null
}

function Get-NodeCompliance {
    param(
        [string]$CurrentMajor,
        [string]$MinimumMajor,
        [string]$RecommendedMajor
    )

    if ([string]::IsNullOrWhiteSpace($CurrentMajor)) {
        return "Unknown"
    }

    $current = [int]$CurrentMajor
    $minimum = [int]$MinimumMajor
    $recommended = [int]$RecommendedMajor

    if ($current -lt $minimum) {
        return "Upgrade Required"
    }

    if ($current -lt $recommended) {
        return "Upgrade Recommended"
    }

    return "Compliant"
}

function Add-ReportRow {
    param(
        [string]$SubscriptionName,
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$ResourceName,
        [string]$ResourceType,
        [string]$Location,
        [string]$Service,
        [string]$Component,
        [string]$CurrentVersion,
        [string]$MinimumSupportedVersion,
        [string]$RecommendedVersion,
        [string]$Status,
        [string]$Recommendation,
        [string]$ResourceId
    )

    [PSCustomObject]@{
        ScanDate                 = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        SubscriptionName        = $SubscriptionName
        SubscriptionId          = $SubscriptionId
        ResourceGroup           = $ResourceGroup
        ResourceName            = $ResourceName
        ResourceType            = $ResourceType
        Location                = $Location
        Service                 = $Service
        Component               = $Component
        CurrentVersion          = $CurrentVersion
        MinimumSupportedVersion = $MinimumSupportedVersion
        RecommendedVersion      = $RecommendedVersion
        Status                  = $Status
        Recommendation          = $Recommendation
        ResourceId              = $ResourceId
    }
}

# ---------------------------------------------------------------------------
# PRE-CHECKS
# ---------------------------------------------------------------------------

Write-Log "Starting Azure Resource Version & Compliance scan."
Write-Log "READ-ONLY MODE: no Azure resources will be changed."

$requiredModules = @(
    "Az.Accounts",
    "Az.ResourceGraph",
    "Az.Aks",
    "Az.Websites",
    "Az.PostgreSql",
    "Az.Sql",
    "Az.RedisCache"
)

foreach ($module in $requiredModules) {
    Ensure-Module -Name $module
}

if (-not (Get-AzContext)) {
    Write-Log "No Azure session found. Starting interactive Azure login."
    Connect-AzAccount | Out-Null
}

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$context = Get-AzContext

if (-not $context) {
    throw "Unable to establish Azure context."
}

if ($context.Subscription.Id -ne $SubscriptionId) {
    throw "Azure context subscription does not match requested SubscriptionId."
}

$subscriptionName = $context.Subscription.Name

Write-Log "Subscription: $subscriptionName"
Write-Log "Subscription ID: $SubscriptionId"

# ---------------------------------------------------------------------------
# OUTPUT FOLDER
# ---------------------------------------------------------------------------

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$inventoryCsv = Join-Path $OutputPath "Azure-Resource-Inventory-$timestamp.csv"
$complianceCsv = Join-Path $OutputPath "Azure-Resource-Compliance-$timestamp.csv"
$summaryCsv = Join-Path $OutputPath "Azure-Compliance-Summary-$timestamp.csv"
$advisorCsv = Join-Path $OutputPath "Azure-Advisor-Recommendations-$timestamp.csv"
$jsonFile = Join-Path $OutputPath "Azure-Resource-Compliance-$timestamp.json"
$htmlFile = Join-Path $OutputPath "Azure-Resource-Compliance-$timestamp.html"

# ---------------------------------------------------------------------------
# 1. RESOURCE INVENTORY - AZURE RESOURCE GRAPH
# ---------------------------------------------------------------------------

Write-Log "Collecting Azure Resource Graph inventory..."

$inventoryQuery = @"
Resources
| project
    subscriptionId,
    resourceGroup,
    name,
    type,
    location,
    id,
    sku,
    tags,
    properties
| order by type asc, resourceGroup asc, name asc
"@

$inventory = Search-AzGraph -Query $inventoryQuery -Subscription $SubscriptionId -First 1000

if (-not $inventory) {
    Write-Log "No resources returned from Azure Resource Graph." "WARN"
}
else {
    $inventory |
        Select-Object subscriptionId, resourceGroup, name, type, location, id, sku, tags |
        Export-Csv -Path $inventoryCsv -NoTypeInformation -Encoding UTF8

    Write-Log "Inventory exported: $inventoryCsv"
    Write-Log "Resources discovered: $($inventory.Count)"
}

# ---------------------------------------------------------------------------
# 2. VERSION / COMPLIANCE COLLECTION
# ---------------------------------------------------------------------------

$report = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------------------
# AKS
# ---------------------------------------------------------------------------

Write-Log "Checking AKS clusters and node pools..."

try {
    $aksClusters = Get-AzAks -SubscriptionId $SubscriptionId -ErrorAction Stop
}
catch {
    Write-Log "AKS collection failed: $($_.Exception.Message)" "WARN"
    $aksClusters = @()
}

foreach ($aks in $aksClusters) {

    $clusterVersion = [string]$aks.KubernetesVersion
    $status = Get-ComplianceStatus `
        -CurrentVersion $clusterVersion `
        -MinimumVersion $AksMinimumVersion `
        -RecommendedVersion $AksRecommendedVersion

    $recommendation = switch ($status) {
        "Upgrade Required"     { "Upgrade AKS cluster. Current version is below the organizational minimum." }
        "Upgrade Recommended"  { "Plan AKS upgrade to the recommended version." }
        "Compliant"            { "No version action required." }
        default                { "Version could not be evaluated automatically." }
    }

    $report.Add(
        (Add-ReportRow `
            -SubscriptionName $subscriptionName `
            -SubscriptionId $SubscriptionId `
            -ResourceGroup $aks.ResourceGroupName `
            -ResourceName $aks.Name `
            -ResourceType "Microsoft.ContainerService/managedClusters" `
            -Location $aks.Location `
            -Service "AKS" `
            -Component "Cluster" `
            -CurrentVersion $clusterVersion `
            -MinimumSupportedVersion $AksMinimumVersion `
            -RecommendedVersion $AksRecommendedVersion `
            -Status $status `
            -Recommendation $recommendation `
            -ResourceId $aks.Id)
    )

    # Node pools are checked separately.
    try {
        $nodePools = Get-AzAksNodePool `
            -ResourceGroupName $aks.ResourceGroupName `
            -ClusterName $aks.Name `
            -ErrorAction Stop

        foreach ($pool in $nodePools) {

            $poolVersion = [string]$pool.OrchestratorVersion

            $poolStatus = Get-ComplianceStatus `
                -CurrentVersion $poolVersion `
                -MinimumVersion $AksMinimumVersion `
                -RecommendedVersion $AksRecommendedVersion

            $poolRecommendation = switch ($poolStatus) {
                "Upgrade Required"    { "Upgrade node pool Kubernetes version." }
                "Upgrade Recommended" { "Plan node pool upgrade." }
                "Compliant"           { "No version action required." }
                default               { "Node pool version could not be evaluated automatically." }
            }

            $report.Add(
                (Add-ReportRow `
                    -SubscriptionName $subscriptionName `
                    -SubscriptionId $SubscriptionId `
                    -ResourceGroup $aks.ResourceGroupName `
                    -ResourceName $aks.Name `
                    -ResourceType "Microsoft.ContainerService/managedClusters/agentPools" `
                    -Location $aks.Location `
                    -Service "AKS" `
                    -Component "NodePool:$($pool.Name)" `
                    -CurrentVersion $poolVersion `
                    -MinimumSupportedVersion $AksMinimumVersion `
                    -RecommendedVersion $AksRecommendedVersion `
                    -Status $poolStatus `
                    -Recommendation $poolRecommendation `
                    -ResourceId "$($aks.Id)/agentPools/$($pool.Name)")
            )
        }
    }
    catch {
        Write-Log "Could not read node pools for AKS '$($aks.Name)': $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# APP SERVICE / WEB APPS
# ---------------------------------------------------------------------------

Write-Log "Checking App Service / Web App runtimes..."

try {
    $webApps = Get-AzWebApp -ErrorAction Stop
}
catch {
    Write-Log "App Service collection failed: $($_.Exception.Message)" "WARN"
    $webApps = @()
}

foreach ($webApp in $webApps) {

    $linuxFx = [string]$webApp.SiteConfig.LinuxFxVersion
    $windowsFx = [string]$webApp.SiteConfig.WindowsFxVersion
    $netFx = [string]$webApp.SiteConfig.NetFrameworkVersion

    $runtime = if (-not [string]::IsNullOrWhiteSpace($linuxFx)) {
        $linuxFx
    }
    elseif (-not [string]::IsNullOrWhiteSpace($windowsFx)) {
        $windowsFx
    }
    elseif (-not [string]::IsNullOrWhiteSpace($netFx)) {
        ".NET $netFx"
    }
    else {
        "Not detected"
    }

    $nodeMajor = Get-NodeMajorVersion -Runtime $runtime

    if ($nodeMajor) {
        $webStatus = Get-NodeCompliance `
            -CurrentMajor $nodeMajor `
            -MinimumMajor $NodeMinimumMajorVersion `
            -RecommendedMajor $NodeRecommendedMajorVersion

        $webMinimum = "Node $NodeMinimumMajorVersion"
        $webRecommended = "Node $NodeRecommendedMajorVersion"

        $webRecommendation = switch ($webStatus) {
            "Upgrade Required"    { "Upgrade Node.js runtime to at least Node $NodeMinimumMajorVersion." }
            "Upgrade Recommended" { "Plan upgrade to Node $NodeRecommendedMajorVersion." }
            "Compliant"           { "No Node.js version action required." }
            default               { "Runtime could not be evaluated." }
        }
    }
    else {
        $webStatus = "Unknown"
        $webMinimum = ""
        $webRecommended = ""
        $webRecommendation = "Runtime detected as '$runtime'. Add a service-specific policy if version compliance is required."
    }

    $report.Add(
        (Add-ReportRow `
            -SubscriptionName $subscriptionName `
            -SubscriptionId $SubscriptionId `
            -ResourceGroup $webApp.ResourceGroup `
            -ResourceName $webApp.Name `
            -ResourceType "Microsoft.Web/sites" `
            -Location $webApp.Location `
            -Service "App Service" `
            -Component "Runtime" `
            -CurrentVersion $runtime `
            -MinimumSupportedVersion $webMinimum `
            -RecommendedVersion $webRecommended `
            -Status $webStatus `
            -Recommendation $webRecommendation `
            -ResourceId $webApp.Id)
    )
}

# ---------------------------------------------------------------------------
# POSTGRESQL FLEXIBLE SERVER
# ---------------------------------------------------------------------------

Write-Log "Checking PostgreSQL Flexible Servers..."

try {
    $postgresServers = Get-AzPostgreSqlFlexibleServer -ErrorAction Stop
}
catch {
    Write-Log "PostgreSQL collection failed: $($_.Exception.Message)" "WARN"
    $postgresServers = @()
}

foreach ($pg in $postgresServers) {

    $pgVersion = [string]$pg.Version

    $pgStatus = Get-ComplianceStatus `
        -CurrentVersion $pgVersion `
        -MinimumVersion $PostgreSqlMinimumVersion `
        -RecommendedVersion $PostgreSqlRecommendedVersion

    $pgRecommendation = switch ($pgStatus) {
        "Upgrade Required"    { "Upgrade PostgreSQL major version. Current version is below the organizational minimum." }
        "Upgrade Recommended" { "Plan PostgreSQL major version upgrade." }
        "Compliant"           { "No PostgreSQL version action required." }
        default               { "PostgreSQL version could not be evaluated." }
    }

    $report.Add(
        (Add-ReportRow `
            -SubscriptionName $subscriptionName `
            -SubscriptionId $SubscriptionId `
            -ResourceGroup $pg.ResourceGroupName `
            -ResourceName $pg.Name `
            -ResourceType "Microsoft.DBforPostgreSQL/flexibleServers" `
            -Location $pg.Location `
            -Service "PostgreSQL" `
            -Component "Server" `
            -CurrentVersion $pgVersion `
            -MinimumSupportedVersion $PostgreSqlMinimumVersion `
            -RecommendedVersion $PostgreSqlRecommendedVersion `
            -Status $pgStatus `
            -Recommendation $pgRecommendation `
            -ResourceId $pg.Id)
    )
}

# ---------------------------------------------------------------------------
# AZURE SQL DATABASES
# ---------------------------------------------------------------------------

Write-Log "Checking Azure SQL databases..."

try {
    $sqlServers = Get-AzSqlServer -ErrorAction Stop
}
catch {
    Write-Log "SQL server collection failed: $($_.Exception.Message)" "WARN"
    $sqlServers = @()
}

foreach ($sqlServer in $sqlServers) {

    try {
        $databases = Get-AzSqlDatabase `
            -ResourceGroupName $sqlServer.ResourceGroupName `
            -ServerName $sqlServer.ServerName `
            -ErrorAction Stop

        foreach ($db in $databases) {

            # Azure SQL logical servers do not expose a simple engine "version"
            # equivalent to AKS/PostgreSQL. CompatibilityLevel is a useful
            # database-level modernization signal.
            $compatibility = [string]$db.CompatibilityLevel

            if ($db.DatabaseName -eq "master") {
                continue
            }

            $sqlStatus = "Informational"

            $sqlRecommendation = "Review Azure SQL database compatibility level and Microsoft retirement/upgrade recommendations."

            $report.Add(
                (Add-ReportRow `
                    -SubscriptionName $subscriptionName `
                    -SubscriptionId $SubscriptionId `
                    -ResourceGroup $sqlServer.ResourceGroupName `
                    -ResourceName $db.DatabaseName `
                    -ResourceType "Microsoft.Sql/servers/databases" `
                    -Location $sqlServer.Location `
                    -Service "Azure SQL" `
                    -Component "Database Compatibility Level" `
                    -CurrentVersion $compatibility `
                    -MinimumSupportedVersion "" `
                    -RecommendedVersion "" `
                    -Status $sqlStatus `
                    -Recommendation $sqlRecommendation `
                    -ResourceId $db.ResourceId)
            )
        }
    }
    catch {
        Write-Log "Could not read databases from SQL server '$($sqlServer.ServerName)': $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# AZURE CACHE FOR REDIS
# ---------------------------------------------------------------------------

Write-Log "Checking Azure Cache for Redis..."

try {
    $redisCaches = Get-AzRedisCache -ErrorAction Stop
}
catch {
    Write-Log "Redis collection failed: $($_.Exception.Message)" "WARN"
    $redisCaches = @()
}

foreach ($redis in $redisCaches) {

    $redisVersion = [string]$redis.RedisVersion

    if ([string]::IsNullOrWhiteSpace($redisVersion)) {
        $redisStatus = "Unknown"
        $redisRecommendation = "Redis version was not exposed by the current cmdlet output. Review the resource/API and Azure retirement recommendations."
    }
    else {
        $redisMajor = (Get-VersionParts $redisVersion)[0]

        if ($redisMajor -lt [int]$RedisMinimumMajorVersion) {
            $redisStatus = "Upgrade Required"
            $redisRecommendation = "Redis major version is below the organizational minimum."
        }
        else {
            $redisStatus = "Compliant"
            $redisRecommendation = "No Redis version action required by the current policy."
        }
    }

    $report.Add(
        (Add-ReportRow `
            -SubscriptionName $subscriptionName `
            -SubscriptionId $SubscriptionId `
            -ResourceGroup $redis.ResourceGroupName `
            -ResourceName $redis.Name `
            -ResourceType "Microsoft.Cache/Redis" `
            -Location $redis.Location `
            -Service "Azure Cache for Redis" `
            -Component "Redis" `
            -CurrentVersion $redisVersion `
            -MinimumSupportedVersion $RedisMinimumMajorVersion `
            -RecommendedVersion "" `
            -Status $redisStatus `
            -Recommendation $redisRecommendation `
            -ResourceId $redis.Id)
    )
}

# ---------------------------------------------------------------------------
# 3. AZURE ADVISOR RECOMMENDATIONS - BEST EFFORT
# ---------------------------------------------------------------------------

$advisorRecommendations = @()

if (-not $SkipAdvisor) {

    Write-Log "Collecting Azure Advisor recommendations..."

    try {
        $advisorQuery = @"
AdvisorResources
| where type =~ 'microsoft.advisor/recommendations'
| project
    id,
    name,
    recommendationType = tostring(properties.recommendationTypeId),
    category = tostring(properties.category),
    impact = tostring(properties.impact),
    shortDescription = tostring(properties.shortDescription.solution),
    resourceMetadata = tostring(properties.resourceMetadata.resourceId),
    lastUpdated = tostring(properties.lastUpdated)
| where isnotempty(resourceMetadata)
"@

        $advisorRecommendations = Search-AzGraph `
            -Query $advisorQuery `
            -Subscription $SubscriptionId `
            -First 1000

        if ($advisorRecommendations) {
            $advisorRecommendations |
                Export-Csv -Path $advisorCsv -NoTypeInformation -Encoding UTF8

            Write-Log "Advisor recommendations exported: $advisorCsv"
        }
        else {
            Write-Log "No Advisor recommendations returned." "WARN"
        }
    }
    catch {
        Write-Log "Advisor query failed. Continuing without Advisor data: $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# 4. EXPORT COMPLIANCE REPORT
# ---------------------------------------------------------------------------

if ($report.Count -gt 0) {

    $reportArray = @($report)

    $reportArray |
        Export-Csv -Path $complianceCsv -NoTypeInformation -Encoding UTF8

    $reportArray |
        ConvertTo-Json -Depth 10 |
        Out-File -FilePath $jsonFile -Encoding UTF8

    Write-Log "Compliance report exported: $complianceCsv"
    Write-Log "JSON report exported: $jsonFile"

    # Summary
    $summary = $reportArray |
        Group-Object Service, Status |
        ForEach-Object {
            [PSCustomObject]@{
                Service = $_.Group[0].Service
                Status  = $_.Group[0].Status
                Count   = $_.Count
            }
        } |
        Sort-Object Service, Status

    $summary |
        Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

    # Console summary
    Write-Host ""
    Write-Host "============================================================"
    Write-Host " AZURE RESOURCE VERSION COMPLIANCE SUMMARY"
    Write-Host "============================================================"
    Write-Host "Subscription : $subscriptionName"
    Write-Host "SubscriptionId: $SubscriptionId"
    Write-Host "Scan Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "------------------------------------------------------------"
    Write-Host "Total checks  : $($reportArray.Count)"

    $statusCounts = $reportArray | Group-Object Status

    foreach ($statusName in @(
        "Compliant",
        "Upgrade Recommended",
        "Upgrade Required",
        "Unknown",
        "Informational"
    )) {
        $count = ($statusCounts | Where-Object Name -eq $statusName).Count
        if ($count -gt 0) {
            $actualCount = ($statusCounts | Where-Object Name -eq $statusName).Count
            $items = ($statusCounts | Where-Object Name -eq $statusName).Group.Count
            Write-Host ("{0,-22}: {1}" -f $statusName, $items)
        }
    }

    Write-Host "------------------------------------------------------------"

    Write-Host ""
    Write-Host "TOP ITEMS REQUIRING ACTION:"
    $reportArray |
        Where-Object { $_.Status -in @("Upgrade Required","Upgrade Recommended") } |
        Select-Object Service, ResourceName, Component, CurrentVersion, RecommendedVersion, Status |
        Format-Table -AutoSize

    # -----------------------------------------------------------------------
    # 5. HTML REPORT
    # -----------------------------------------------------------------------

    $htmlRows = foreach ($item in $reportArray) {
        $statusClass = switch ($item.Status) {
            "Compliant"           { "good" }
            "Upgrade Recommended" { "warning" }
            "Upgrade Required"    { "critical" }
            default               { "unknown" }
        }

        "<tr>" +
        "<td>$($item.Service)</td>" +
        "<td>$($item.ResourceGroup)</td>" +
        "<td>$($item.ResourceName)</td>" +
        "<td>$($item.Component)</td>" +
        "<td>$($item.CurrentVersion)</td>" +
        "<td>$($item.MinimumSupportedVersion)</td>" +
        "<td>$($item.RecommendedVersion)</td>" +
        "<td class='$statusClass'>$($item.Status)</td>" +
        "<td>$($item.Recommendation)</td>" +
        "</tr>"
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Azure Resource Version Compliance</title>
<style>
body { font-family: Arial, sans-serif; margin: 30px; }
h1 { margin-bottom: 5px; }
.meta { color: #555; margin-bottom: 20px; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
th { background: #f2f2f2; }
.good { background: #d9ead3; }
.warning { background: #fff2cc; }
.critical { background: #f4cccc; }
.unknown { background: #eeeeee; }
</style>
</head>
<body>
<h1>Azure Resource Version Compliance Report</h1>
<div class="meta">
Subscription: $subscriptionName<br/>
Subscription ID: $SubscriptionId<br/>
Scan Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
</div>

<table>
<thead>
<tr>
<th>Service</th>
<th>Resource Group</th>
<th>Resource</th>
<th>Component</th>
<th>Current Version</th>
<th>Minimum</th>
<th>Recommended</th>
<th>Status</th>
<th>Recommendation</th>
</tr>
</thead>
<tbody>
$($htmlRows -join "`n")
</tbody>
</table>
</body>
</html>
"@

    $html | Out-File -FilePath $htmlFile -Encoding UTF8

    Write-Log "HTML report exported: $htmlFile"
}
else {
    Write-Log "No version/compliance records were collected." "WARN"
}

$duration = (Get-Date) - $scriptStart

Write-Host ""
Write-Host "============================================================"
Write-Host "SCAN COMPLETE"
Write-Host "============================================================"
Write-Host "Duration      : $($duration.ToString('hh\:mm\:ss'))"
Write-Host "Output folder : $(Resolve-Path $OutputPath)"
Write-Host ""
Write-Host "Files:"
Write-Host "  Inventory   : $inventoryCsv"
Write-Host "  Compliance  : $complianceCsv"
Write-Host "  Summary     : $summaryCsv"
if (-not $SkipAdvisor) {
    Write-Host "  Advisor     : $advisorCsv"
}
Write-Host "  JSON        : $jsonFile"
Write-Host "  HTML        : $htmlFile"
Write-Host ""
Write-Host "READ-ONLY SCAN - no Azure resources were modified."
