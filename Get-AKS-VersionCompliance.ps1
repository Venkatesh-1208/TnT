#requires -Version 5.1
<#
.SYNOPSIS
    Read-only AKS Kubernetes version compliance report for ONE Azure subscription.

.DESCRIPTION
    Finds all AKS clusters in the selected subscription and reports:
      - control-plane Kubernetes version
      - every node-pool Kubernetes version
      - latest non-preview version returned for the cluster region
      - cluster-specific upgrade targets returned by AKS
      - node-pool-specific upgrade targets returned by AKS
      - a recommended target based on the highest upgrade target AKS currently offers

    NO Kubernetes versions are hardcoded in this script.

    IMPORTANT: This script is READ-ONLY. It does not run any command that
    upgrades, updates, restarts, scales, creates, deletes, or modifies AKS.

.REQUIREMENTS
    Azure CLI installed and available as "az".
    Azure CLI login:
        az login

    Reader-level access is normally sufficient for the read operations.

.EXAMPLE
    .\Get-AKS-VersionCompliance.ps1 -SubscriptionId "<subscription-id>"

.EXAMPLE
    .\Get-AKS-VersionCompliance.ps1 `
        -SubscriptionId "<subscription-id>" `
        -OutputPath "C:\Reports\AKS"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\AKS-Version-Compliance"
)

$ErrorActionPreference = "Stop"
$scanStart = Get-Date

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "INFO"  { Write-Host "[$ts] [INFO ] $Message" }
        "WARN"  { Write-Host "[$ts] [WARN ] $Message" -ForegroundColor Yellow }
        "ERROR" { Write-Host "[$ts] [ERROR] $Message" -ForegroundColor Red }
    }
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)

    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue

        if ($exitCode -ne 0) {
            throw "Azure CLI failed (exit code $exitCode): $stderr"
        }

        $jsonText = ($output -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($jsonText)) { return $null }

        return ($jsonText | ConvertFrom-Json)
    }
    finally {
        Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-VersionParts {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return @() }

    $m = [regex]::Match($Version, '(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $m.Success) { return @() }

    @(
        [int]$m.Groups[1].Value
        $(if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 })
        $(if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 })
    )
}

function Get-VersionSortKey {
    param([string]$Version)
    $p = Get-VersionParts $Version
    if ($p.Count -eq 0) { return [long]0 }
    return [long](($p[0] * 1000000) + ($p[1] * 1000) + $p[2])
}

function Get-HighestVersion {
    param([object[]]$Versions)

    $valid = @(
        $Versions |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object { Get-VersionSortKey $_ } -Descending
    )
    if ($valid.Count -eq 0) { return $null }
    return $valid[0]
}

function Compare-Version {
    param([string]$A, [string]$B)
    $a = Get-VersionParts $A
    $b = Get-VersionParts $B
    if ($a.Count -eq 0 -or $b.Count -eq 0) { return $null }

    for ($i=0; $i -lt 3; $i++) {
        if ($a[$i] -lt $b[$i]) { return -1 }
        if ($a[$i] -gt $b[$i]) { return 1 }
    }
    return 0
}

function Get-UpgradeVersions {
    param($Response)

    $versions = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Response) { return @() }

    if ($Response.properties -and $Response.properties.upgrades) {
        foreach ($u in @($Response.properties.upgrades)) {
            if ($u.kubernetesVersion) {
                $versions.Add([string]$u.kubernetesVersion)
            }
        }
    }

    if ($versions.Count -eq 0 -and $Response.upgrades) {
        foreach ($u in @($Response.upgrades)) {
            if ($u.kubernetesVersion) { $versions.Add([string]$u.kubernetesVersion) }
            elseif ($u.version) { $versions.Add([string]$u.version) }
        }
    }

    @($versions | Select-Object -Unique)
}

function Get-RegionalVersions {
    param([string]$Location)

    try {
        $r = Invoke-AzCliJson -Arguments @(
            "aks","get-versions",
            "--location",$Location,
            "--subscription",$SubscriptionId,
            "--output","json"
        )

        if ($null -eq $r) { return @() }

        $items = if ($r.values) { @($r.values) }
                 elseif ($r.orchestrators) { @($r.orchestrators) }
                 else { @($r) }

        $result = New-Object System.Collections.Generic.List[object]

        foreach ($item in $items) {
            $version = $null
            foreach ($name in @("version","orchestratorVersion","kubernetesVersion")) {
                if ($item.PSObject.Properties.Name -contains $name -and $item.$name) {
                    $version = [string]$item.$name
                    break
                }
            }

            if ($version) {
                $isPreview = $false
                if ($item.PSObject.Properties.Name -contains "isPreview") {
                    $isPreview = [bool]$item.isPreview
                }
                $result.Add([PSCustomObject]@{
                    Version   = $version
                    IsPreview = $isPreview
                })
            }
        }
        return @($result)
    }
    catch {
        Write-Log "Could not query regional versions for $Location : $($_.Exception.Message)" "WARN"
        return @()
    }
}

function New-Row {
    param(
        [string]$SubscriptionName,
        [string]$ResourceGroup,
        [string]$ClusterName,
        [string]$Location,
        [string]$Component,
        [string]$CurrentVersion,
        [string]$LatestRegionalVersion,
        [string]$HighestOfferedUpgrade,
        [string]$Status,
        [string]$RecommendedTarget,
        [string]$UpgradePath,
        [string]$Reason,
        [string]$ResourceId
    )

    [PSCustomObject]@{
        ScanDate              = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        SubscriptionName      = $SubscriptionName
        SubscriptionId        = $SubscriptionId
        ResourceGroup         = $ResourceGroup
        ClusterName           = $ClusterName
        Location              = $Location
        Component             = $Component
        CurrentVersion        = $CurrentVersion
        LatestRegionalVersion = $LatestRegionalVersion
        HighestOfferedUpgrade = $HighestOfferedUpgrade
        Status                = $Status
        RecommendedTarget     = $RecommendedTarget
        UpgradePath           = $UpgradePath
        Reason                = $Reason
        ResourceId            = $ResourceId
    }
}

# -------------------- PRE-CHECKS --------------------

Write-Log "Starting AKS version compliance scan."
Write-Log "READ-ONLY: no AKS upgrade/update operation will be executed."

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI 'az' was not found in PATH. Install Azure CLI first."
}

$account = Invoke-AzCliJson -Arguments @(
    "account","show",
    "--subscription",$SubscriptionId,
    "--output","json"
)

if ($null -eq $account) {
    throw "Azure CLI is not logged in or the subscription cannot be accessed. Run 'az login'."
}

$actualId = [string]$account.id
$subscriptionName = [string]$account.name

if ($actualId -ne $SubscriptionId) {
    throw "Azure returned subscription '$actualId' instead of requested '$SubscriptionId'."
}

& az account set --subscription $SubscriptionId | Out-Null

Write-Log "Subscription: $subscriptionName"
Write-Log "Subscription ID: $SubscriptionId"

# -------------------- OUTPUT --------------------

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$reportCsv    = Join-Path $OutputPath "AKS-Version-Compliance-$timestamp.csv"
$inventoryCsv = Join-Path $OutputPath "AKS-Cluster-Inventory-$timestamp.csv"
$versionsCsv  = Join-Path $OutputPath "AKS-Available-Versions-$timestamp.csv"
$jsonFile     = Join-Path $OutputPath "AKS-Version-Compliance-$timestamp.json"
$htmlFile     = Join-Path $OutputPath "AKS-Version-Compliance-$timestamp.html"

# -------------------- DISCOVER CLUSTERS --------------------

Write-Log "Discovering AKS clusters..."

$clusters = @(Invoke-AzCliJson -Arguments @(
    "aks","list",
    "--subscription",$SubscriptionId,
    "--output","json"
))

if ($clusters.Count -eq 0) {
    Write-Log "No AKS clusters found in this subscription." "WARN"
    return
}

Write-Log "AKS clusters found: $($clusters.Count)"

$report = New-Object System.Collections.Generic.List[object]
$inventory = New-Object System.Collections.Generic.List[object]
$regionalVersionRows = New-Object System.Collections.Generic.List[object]
$regionCache = @{}

foreach ($cluster in $clusters) {

    $name = [string]$cluster.name
    $rg = [string]$cluster.resourceGroup
    $location = [string]$cluster.location
    $id = [string]$cluster.id

    Write-Log "Processing: $name | RG: $rg | Region: $location"

    # -------- cluster details --------
    $details = Invoke-AzCliJson -Arguments @(
        "aks","show",
        "--resource-group",$rg,
        "--name",$name,
        "--subscription",$SubscriptionId,
        "--output","json"
    )

    if ($null -eq $details) {
        Write-Log "Unable to read cluster details for $name. Skipping." "WARN"
        continue
    }

    $current = [string]$details.currentKubernetesVersion
    if ([string]::IsNullOrWhiteSpace($current)) {
        $current = [string]$details.kubernetesVersion
    }

    $supportPlan = [string]$details.k8sSupportPlan
    if ([string]::IsNullOrWhiteSpace($supportPlan)) {
        $supportPlan = [string]$details.kubernetesSupportPlan
    }

    $upgradeChannel = [string]$details.autoUpgradeProfile.upgradeChannel

    $inventory.Add([PSCustomObject]@{
        ScanDate       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Subscription   = $subscriptionName
        SubscriptionId = $SubscriptionId
        ResourceGroup  = $rg
        ClusterName    = $name
        Location       = $location
        CurrentVersion = $current
        SupportPlan    = $supportPlan
        UpgradeChannel = $upgradeChannel
        ResourceId     = $id
    })

    # -------- regional versions --------
    if (-not $regionCache.ContainsKey($location)) {
        Write-Log "Getting AKS versions currently available in region: $location"
        $regionCache[$location] = @(Get-RegionalVersions $location)
    }

    $regional = @($regionCache[$location])

    foreach ($v in $regional) {
        $regionalVersionRows.Add([PSCustomObject]@{
            SubscriptionId = $SubscriptionId
            Location       = $location
            Version        = $v.Version
            IsPreview      = $v.IsPreview
        })
    }

    $latestRegional = Get-HighestVersion @(
        $regional |
        Where-Object { -not $_.IsPreview } |
        Select-Object -ExpandProperty Version
    )

    # -------- cluster-specific upgrade targets --------
    $clusterUpgradeVersions = @()

    try {
        $upgradeResponse = Invoke-AzCliJson -Arguments @(
            "aks","get-upgrades",
            "--resource-group",$rg,
            "--name",$name,
            "--subscription",$SubscriptionId,
            "--output","json"
        )

        $clusterUpgradeVersions = @(Get-UpgradeVersions $upgradeResponse)
    }
    catch {
        Write-Log "Could not retrieve upgrade targets for $name : $($_.Exception.Message)" "WARN"
    }

    $highestClusterUpgrade = Get-HighestVersion $clusterUpgradeVersions

    if ([string]::IsNullOrWhiteSpace($current)) {
        $status = "Unknown"
        $target = ""
        $path = ""
        $reason = "Current Kubernetes version was not returned by AKS."
    }
    elseif ($clusterUpgradeVersions.Count -gt 0) {

        $target = $highestClusterUpgrade
        $comparison = Compare-Version $current $target

        if ($comparison -lt 0) {
            $status = "Upgrade Available"
            $path = (
                $clusterUpgradeVersions |
                Sort-Object { Get-VersionSortKey $_ }
            ) -join " -> "
            $reason = "AKS returned one or more valid upgrade targets for this cluster."
        }
        else {
            $status = "Current / No Upgrade Returned"
            $path = ""
            $reason = "Current version is not below the highest upgrade target returned by AKS."
        }
    }
    else {
        $target = ""
        $path = ""

        $currentMinor = if ((Get-VersionParts $current).Count -ge 2) {
            $p = Get-VersionParts $current
            "$($p[0]).$($p[1])"
        } else { "" }

        $latestMinor = if ((Get-VersionParts $latestRegional).Count -ge 2) {
            $p = Get-VersionParts $latestRegional
            "$($p[0]).$($p[1])"
        } else { "" }

        if ($currentMinor -and $latestMinor -and $currentMinor -eq $latestMinor) {
            $status = "Current / No Upgrade Returned"
            $reason = "Current minor version matches the highest non-preview regional version returned by AKS."
        }
        else {
            $status = "Review Required"
            $reason = "AKS returned no cluster-specific upgrade target. Review support status and upgrade availability before taking action."
        }
    }

    $report.Add((New-Row `
        -SubscriptionName $subscriptionName `
        -ResourceGroup $rg `
        -ClusterName $name `
        -Location $location `
        -Component "Control Plane" `
        -CurrentVersion $current `
        -LatestRegionalVersion $latestRegional `
        -HighestOfferedUpgrade $highestClusterUpgrade `
        -Status $status `
        -RecommendedTarget $target `
        -UpgradePath $path `
        -Reason $reason `
        -ResourceId $id))

    # -------- node pools --------
    Write-Log "Checking node pools for $name..."

    $nodePools = @()
    try {
        $nodePools = @(Invoke-AzCliJson -Arguments @(
            "aks","nodepool","list",
            "--resource-group",$rg,
            "--cluster-name",$name,
            "--subscription",$SubscriptionId,
            "--output","json"
        ))
    }
    catch {
        Write-Log "Unable to read node pools for $name : $($_.Exception.Message)" "WARN"
    }

    foreach ($pool in $nodePools) {

        $poolName = [string]$pool.name
        $poolVersion = [string]$pool.orchestratorVersion
        $poolId = [string]$pool.id

        Write-Log "  Node pool: $poolName | Version: $poolVersion"

        $poolUpgradeVersions = @()

        try {
            $poolResponse = Invoke-AzCliJson -Arguments @(
                "aks","nodepool","get-upgrades",
                "--resource-group",$rg,
                "--cluster-name",$name,
                "--name",$poolName,
                "--subscription",$SubscriptionId,
                "--output","json"
            )

            $poolUpgradeVersions = @(Get-UpgradeVersions $poolResponse)
        }
        catch {
            Write-Log "Unable to retrieve upgrade targets for node pool $poolName : $($_.Exception.Message)" "WARN"
        }

        $highestPoolUpgrade = Get-HighestVersion $poolUpgradeVersions

        if ([string]::IsNullOrWhiteSpace($poolVersion)) {
            $poolStatus = "Unknown"
            $poolTarget = ""
            $poolPath = ""
            $poolReason = "Node pool Kubernetes version was not returned."
        }
        elseif ($poolUpgradeVersions.Count -gt 0) {

            $poolTarget = $highestPoolUpgrade
            $poolComparison = Compare-Version $poolVersion $poolTarget

            if ($poolComparison -lt 0) {
                $poolStatus = "Upgrade Available"
                $poolPath = (
                    $poolUpgradeVersions |
                    Sort-Object { Get-VersionSortKey $_ }
                ) -join " -> "
                $poolReason = "AKS returned one or more upgrade targets for this node pool."
            }
            else {
                $poolStatus = "Current / No Upgrade Returned"
                $poolPath = ""
                $poolReason = "Node pool version is not below the highest upgrade target returned by AKS."
            }
        }
        else {
            $poolStatus = "Review Required"
            $poolTarget = ""
            $poolPath = ""
            $poolReason = "AKS returned no node-pool-specific upgrade target."
        }

        $report.Add((New-Row `
            -SubscriptionName $subscriptionName `
            -ResourceGroup $rg `
            -ClusterName $name `
            -Location $location `
            -Component "Node Pool: $poolName" `
            -CurrentVersion $poolVersion `
            -LatestRegionalVersion $latestRegional `
            -HighestOfferedUpgrade $highestPoolUpgrade `
            -Status $poolStatus `
            -RecommendedTarget $poolTarget `
            -UpgradePath $poolPath `
            -Reason $poolReason `
            -ResourceId $poolId))
    }
}

# -------------------- EXPORT --------------------

@($report) | Export-Csv $reportCsv -NoTypeInformation -Encoding UTF8
@($inventory) | Export-Csv $inventoryCsv -NoTypeInformation -Encoding UTF8
@($regionalVersionRows | Sort-Object Location, Version -Unique) |
    Export-Csv $versionsCsv -NoTypeInformation -Encoding UTF8
@($report) | ConvertTo-Json -Depth 10 | Out-File $jsonFile -Encoding UTF8

# -------------------- CONSOLE SUMMARY --------------------

Write-Host ""
Write-Host "============================================================"
Write-Host "             AKS VERSION COMPLIANCE SUMMARY"
Write-Host "============================================================"
Write-Host "Subscription : $subscriptionName"
Write-Host "Subscription : $SubscriptionId"
Write-Host "Clusters     : $($clusters.Count)"
Write-Host "Checks       : $($report.Count)"
Write-Host "------------------------------------------------------------"

@($report) |
    Group-Object Status |
    Sort-Object Name |
    ForEach-Object {
        Write-Host ("{0,-32}: {1}" -f $_.Name, $_.Count)
    }

Write-Host "------------------------------------------------------------"
Write-Host "ACTION ITEMS"
Write-Host ""

$actions = @($report | Where-Object {
    $_.Status -in @("Upgrade Available","Review Required")
})

if ($actions.Count -eq 0) {
    Write-Host "No AKS upgrade action items were identified." -ForegroundColor Green
}
else {
    $actions |
        Select-Object ClusterName,Component,CurrentVersion,HighestOfferedUpgrade,Status,RecommendedTarget |
        Format-Table -AutoSize
}

# -------------------- HTML --------------------

$htmlRows = foreach ($r in @($report)) {

    $class = switch ($r.Status) {
        "Upgrade Available"            { "warning" }
        "Review Required"              { "critical" }
        "Current / No Upgrade Returned"{ "good" }
        default                        { "unknown" }
    }

    "<tr>" +
    "<td>$($r.ClusterName)</td>" +
    "<td>$($r.Location)</td>" +
    "<td>$($r.Component)</td>" +
    "<td>$($r.CurrentVersion)</td>" +
    "<td>$($r.LatestRegionalVersion)</td>" +
    "<td>$($r.HighestOfferedUpgrade)</td>" +
    "<td class='$class'>$($r.Status)</td>" +
    "<td>$($r.RecommendedTarget)</td>" +
    "<td>$($r.Reason)</td>" +
    "</tr>"
}

$html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>AKS Version Compliance Report</title>
<style>
body{font-family:Arial,sans-serif;margin:30px}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{border:1px solid #ddd;padding:8px;text-align:left;vertical-align:top}
th{background:#f2f2f2}
.good{background:#d9ead3}
.warning{background:#fff2cc}
.critical{background:#f4cccc}
.unknown{background:#eee}
.meta{color:#555;margin-bottom:20px}
</style>
</head>
<body>
<h1>AKS Kubernetes Version Compliance Report</h1>
<div class="meta">
Subscription: $subscriptionName<br>
Subscription ID: $SubscriptionId<br>
Scan Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")<br>
<strong>READ-ONLY: No Azure resources were modified.</strong>
</div>
<table>
<thead>
<tr>
<th>Cluster</th>
<th>Region</th>
<th>Component</th>
<th>Current</th>
<th>Latest Regional</th>
<th>Highest Offered Upgrade</th>
<th>Status</th>
<th>Recommended Target</th>
<th>Reason</th>
</tr>
</thead>
<tbody>
$($htmlRows -join "`n")
</tbody>
</table>
</body>
</html>
"@

$html | Out-File $htmlFile -Encoding UTF8

$duration = (Get-Date) - $scanStart

Write-Host ""
Write-Host "============================================================"
Write-Host "SCAN COMPLETE"
Write-Host "============================================================"
Write-Host "Duration      : $($duration.ToString('hh\:mm\:ss'))"
Write-Host "Output folder : $(Resolve-Path $OutputPath)"
Write-Host ""
Write-Host "Compliance    : $reportCsv"
Write-Host "Inventory     : $inventoryCsv"
Write-Host "Versions      : $versionsCsv"
Write-Host "JSON          : $jsonFile"
Write-Host "HTML          : $htmlFile"
Write-Host ""
Write-Host "READ-ONLY: No AKS upgrade/update operation was executed."
