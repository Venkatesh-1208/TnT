<#
.SYNOPSIS
Creates an Azure DevOps pipeline-health report for every accessible project.

.DESCRIPTION
The report contains every YAML/classic pipeline returned by the Pipelines API and
its newest build. A PAT is read from AZURE_DEVOPS_EXT_PAT when available; otherwise
the script prompts for it. The token is never written to the report or console.

.PARAMETER Organization
Azure DevOps organization name, without the dev.azure.com URL.

.PARAMETER OutputDirectory
Folder in which the CSV (and, optionally, Excel) reports are created.

.PARAMETER SkipExcel
Do not create an Excel report, even when the ImportExcel module is installed.

.EXAMPLE
$env:AZURE_DEVOPS_EXT_PAT = '<PAT>'
.\Get-AdoPipelineHealthReport.ps1 -Organization contoso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Organization,

    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path -Path $PWD -ChildPath 'ADO-Pipeline-Report'),

    [switch]$SkipExcel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$apiVersion = '7.1'

function ConvertTo-AdoQueryString {
    param([hashtable]$Query)

    ($Query.GetEnumerator() |
        Where-Object { $null -ne $_.Value -and '' -ne $_.Value } |
        ForEach-Object {
            '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
        }) -join '&'
}

function New-AdoUri {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [hashtable]$Query = @{}
    )

    $queryString = ConvertTo-AdoQueryString -Query $Query
    $baseUri = 'https://dev.azure.com/{0}/{1}' -f [uri]::EscapeDataString($Organization), $Path.TrimStart('/')

    if ($queryString) { return "$baseUri`?$queryString" }
    return $baseUri
}

function Invoke-AdoWebRequest {
    param([Parameter(Mandatory)] [string]$Uri)

    try {
        $response = Invoke-WebRequest -Uri $Uri -Headers $script:headers -Method Get -ErrorAction Stop
        return [pscustomobject]@{
            Body    = $response.Content | ConvertFrom-Json
            Headers = $response.Headers
        }
    }
    catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
        throw "Azure DevOps request failed (HTTP $statusCode): $Uri`n$($_.Exception.Message)"
    }
}

function Get-AdoPagedCollection {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [hashtable]$Query = @{}
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $continuationToken = $null

    do {
        $pageQuery = @{}
        foreach ($key in $Query.Keys) { $pageQuery[$key] = $Query[$key] }
        $pageQuery['api-version'] = $apiVersion
        if ($continuationToken) { $pageQuery['continuationToken'] = $continuationToken }

        $response = Invoke-AdoWebRequest -Uri (New-AdoUri -Path $Path -Query $pageQuery)
        foreach ($item in @($response.Body.value)) {
            if ($null -ne $item) { $items.Add($item) }
        }

        $continuationToken = $response.Headers['x-ms-continuationtoken']
    } while ($continuationToken)

    return $items
}

function Get-PipelineHealth {
    param([object]$Build)

    if ($null -eq $Build) { return 'NoRun' }

    switch ($Build.status) {
        'inProgress' { return 'Running' }
        'notStarted' { return 'Queued' }
        'postponed'  { return 'Queued' }
        'cancelling' { return 'Cancelling' }
        'completed' {
            switch ($Build.result) {
                'succeeded'          { return 'Green' }
                'partiallySucceeded' { return 'Warning' }
                'failed'             { return 'Red' }
                'canceled'           { return 'Canceled' }
                default              { return [string]$Build.result }
            }
        }
        default { return [string]$Build.status }
    }
}

Write-Host "Azure DevOps Pipeline Health Report" -ForegroundColor Cyan

$pat = $env:AZURE_DEVOPS_EXT_PAT
if ([string]::IsNullOrWhiteSpace($pat)) {
    $securePat = Read-Host -Prompt 'Enter Azure DevOps PAT' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat)
    try { $pat = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if ([string]::IsNullOrWhiteSpace($pat)) {
    throw 'A non-empty Azure DevOps PAT is required.'
}

$encodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = "Basic $encodedPat"; Accept = 'application/json' }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$csvFile = Join-Path $OutputDirectory 'ADO-Pipeline-Health.csv'
$excelFile = Join-Path $OutputDirectory 'ADO-Pipeline-Health.xlsx'

Write-Host 'Fetching projects...' -ForegroundColor Cyan
$projects = @(Get-AdoPagedCollection -Path '_apis/projects' -Query @{ '$top' = 100; stateFilter = 'wellFormed' })
Write-Host "Found $($projects.Count) project(s)." -ForegroundColor Green

$results = [System.Collections.Generic.List[object]]::new()
$projectNumber = 0

foreach ($project in $projects) {
    $projectNumber++
    Write-Progress -Activity 'Checking pipelines' -Status $project.name -PercentComplete (($projectNumber / [Math]::Max($projects.Count, 1)) * 100)

    try {
        $pipelines = @(Get-AdoPagedCollection -Path "$($project.id)/_apis/pipelines" -Query @{ '$top' = 100; orderBy = 'name asc' })
    }
    catch {
        Write-Warning "Skipping project '$($project.name)': $($_.Exception.Message)"
        continue
    }

    foreach ($pipeline in $pipelines) {
        $latestBuild = $null
        $lookupError = $null

        try {
            $buildResponse = Invoke-AdoWebRequest -Uri (New-AdoUri -Path "$($project.id)/_apis/build/builds" -Query @{
                'api-version' = $apiVersion; definitions = $pipeline.id; '$top' = 1; queryOrder = 'queueTimeDescending'
            })
            $latestBuild = @($buildResponse.Body.value | Select-Object -First 1)[0]
        }
        catch {
            $lookupError = $_.Exception.Message
            Write-Warning "Could not get the latest run for '$($project.name) / $($pipeline.name)'."
        }

        $projectSegment = [uri]::EscapeDataString($project.name)
        $pipelineUrl = "https://dev.azure.com/$([uri]::EscapeDataString($Organization))/$projectSegment/_build?definitionId=$($pipeline.id)"
        $runUrl = if ($latestBuild -and $latestBuild._links.web.href) { $latestBuild._links.web.href } else { $null }

        $results.Add([pscustomobject]@{
            Organization = $Organization
            ProjectName  = $project.name
            ProjectId    = $project.id
            PipelineName = $pipeline.name
            PipelineId   = $pipeline.id
            PipelineUrl  = $pipelineUrl
            RunId        = if ($latestBuild) { $latestBuild.id } else { $null }
            RunNumber    = if ($latestBuild) { $latestBuild.buildNumber } else { $null }
            RunState     = if ($latestBuild) { $latestBuild.status } else { 'NoRun' }
            RunResult    = if ($latestBuild) { $latestBuild.result } else { 'NoRun' }
            Health       = if ($lookupError) { 'Unknown' } else { Get-PipelineHealth -Build $latestBuild }
            Branch       = if ($latestBuild) { $latestBuild.sourceBranch } else { $null }
            Reason       = if ($latestBuild) { $latestBuild.reason } else { $null }
            Queued       = if ($latestBuild) { $latestBuild.queueTime } else { $null }
            Started      = if ($latestBuild) { $latestBuild.startTime } else { $null }
            Finished     = if ($latestBuild) { $latestBuild.finishTime } else { $null }
            RunUrl       = $runUrl
            Error        = $lookupError
        })
    }
}

Write-Progress -Activity 'Checking pipelines' -Completed

$sortedResults = $results | Sort-Object ProjectName, PipelineName
$sortedResults | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8
Write-Host "CSV report: $csvFile" -ForegroundColor Green

$excelCreated = $false
if (-not $SkipExcel -and (Get-Module -ListAvailable -Name ImportExcel)) {
    Import-Module ImportExcel -ErrorAction Stop
    $sortedResults | Export-Excel -Path $excelFile -WorksheetName 'Pipeline Health' -AutoSize -FreezeTopRow -BoldTopRow
    $excelCreated = $true
    Write-Host "Excel report: $excelFile" -ForegroundColor Green
}
elseif (-not $SkipExcel) {
    Write-Warning 'ImportExcel is not installed; only the CSV report was created. Install it with: Install-Module ImportExcel -Scope CurrentUser'
}

Write-Host "`nPipeline health summary:" -ForegroundColor Cyan
$sortedResults | Group-Object Health | Sort-Object Name | Select-Object @{ Name = 'Health'; Expression = Name }, Count | Format-Table -AutoSize
Write-Host "Total pipelines: $($results.Count)" -ForegroundColor Cyan

if ($excelCreated) { Write-Host 'Completed successfully.' -ForegroundColor Green }
else { Write-Host 'Completed successfully (CSV report created).' -ForegroundColor Green }
