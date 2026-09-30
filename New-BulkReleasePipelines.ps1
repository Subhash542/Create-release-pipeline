<#
.SYNOPSIS
  Bulk-create Classic Release Pipelines in Azure DevOps from a template release definition (default id 27).

.DESCRIPTION
  Input CSV columns : ApiName, BuildName
  Release name      : same as ApiName
  If a release pipeline with that name already exists, a message is shown and the row is skipped.

.EXAMPLE
  $env:ADO_PAT = "xxxx"
  .\New-BulkReleasePipelines.ps1 -Organization myorg -Project "My Project" -CsvPath .\apis.csv -DryRun
  .\New-BulkReleasePipelines.ps1 -Organization myorg -Project "My Project" -CsvPath .\apis.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CsvPath,
    [string] $Organization = $env:ADO_ORG,
    [string] $Project      = $env:ADO_PROJECT,
    [string] $Pat          = $env:ADO_PAT,
    [int]    $TemplateId   = 27,
    [string] $ArtifactAlias,
    [string] $ReportPath   = ".\results.csv",
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$ApiVersion = '7.1'

if (-not $Organization -or -not $Project -or -not $Pat) {
    throw "Provide -Organization, -Project and a PAT (-Pat or `$env:ADO_PAT). Env vars ADO_ORG / ADO_PROJECT are also supported."
}

$authHeader = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat")) }
$projEnc    = [uri]::EscapeDataString($Project)
$releaseApi = "https://vsrm.dev.azure.com/$Organization/$projEnc/_apis"
$coreApi    = "https://dev.azure.com/$Organization/$projEnc/_apis"

function Invoke-Ado {
    param([string] $Method, [string] $Url, $Body)
    $sep = if ($Url.Contains('?')) { '&' } else { '?' }
    $uri = "$Url${sep}api-version=$ApiVersion"
    try {
        if ($null -ne $Body) {
            $json  = $Body | ConvertTo-Json -Depth 100
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $authHeader -ContentType 'application/json' -Body $bytes
        }
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $authHeader
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) }
        throw "$Method $Url failed: $detail"
    }
}

function Test-ReleaseExists([string] $Name) {
    $enc  = [uri]::EscapeDataString($Name)
    $resp = Invoke-Ado GET "$releaseApi/release/definitions?searchText=$enc"
    return [bool]($resp.value | Where-Object { $_.name -ieq $Name })
}

function Get-BuildDefinition([string] $Name) {
    $enc     = [uri]::EscapeDataString($Name)
    $resp    = Invoke-Ado GET "$coreApi/build/definitions?name=$enc"
    $matches = @($resp.value | Where-Object { $_.name -ieq $Name })
    if ($matches.Count -eq 0) { throw "Build pipeline '$Name' not found." }
    if ($matches.Count -gt 1) {
        throw "Build pipeline name '$Name' is ambiguous (folders: $(($matches | ForEach-Object { $_.path }) -join ', '))."
    }
    return $matches[0]
}

function New-ReleasePayload($Template, [string] $ApiName, $BuildDef) {
    # Deep clone
    $body = $Template | ConvertTo-Json -Depth 100 | ConvertFrom-Json

    foreach ($key in 'id','revision','_links','createdBy','createdOn','modifiedBy','modifiedOn','url','lastRelease') {
        $body.PSObject.Properties.Remove($key)
    }
    $body.name        = $ApiName
    $body.description = "Created by bulk automation for $ApiName on $(Get-Date -Format 'yyyy-MM-dd')"

    # Point the build artifact to this API's build (alias is kept so tasks/triggers still work)
    $buildArtifacts = @($body.artifacts | Where-Object { $_.type -eq 'Build' })
    if ($ArtifactAlias) { $buildArtifacts = @($buildArtifacts | Where-Object { $_.alias -eq $ArtifactAlias }) }
    if ($buildArtifacts.Count -eq 0) { throw "Template has no matching Build artifact." }
    if ($buildArtifacts.Count -gt 1) {
        throw "Template has multiple Build artifacts ($(($buildArtifacts.alias) -join ', ')); use -ArtifactAlias."
    }

    $ref = $buildArtifacts[0].definitionReference
    $ref.definition = [pscustomobject]@{ id = [string]$BuildDef.id; name = $BuildDef.name }
    $ref.project    = [pscustomobject]@{ id = $BuildDef.project.id; name = $BuildDef.project.name }
    foreach ($k in 'defaultVersionSpecific','defaultVersionBranch','defaultVersionTags') {
        $ref.PSObject.Properties.Remove($k)
    }

    # New stages need fresh ids
    foreach ($env in $body.environments) { $env.id = 0 }
    return $body
}

# ---------- main ----------
Write-Host "Loading template $TemplateId ..."
$template = Invoke-Ado GET "$releaseApi/release/definitions/$TemplateId"
Write-Host "Template: [$TemplateId] $($template.name)"
Write-Host "Mode    : $(if ($DryRun) { 'DRY RUN' } else { 'CREATE' })`n"

$rows = @(Import-Csv -Path $CsvPath)
if ($rows.Count -eq 0 -or -not ($rows[0].PSObject.Properties.Name -contains 'ApiName') -or -not ($rows[0].PSObject.Properties.Name -contains 'BuildName')) {
    throw "CSV must contain the columns: ApiName, BuildName"
}

$results = New-Object System.Collections.Generic.List[object]
$seen    = @{}
$line    = 1

foreach ($row in $rows) {
    $line++
    $api   = "$($row.ApiName)".Trim()
    $build = "$($row.BuildName)".Trim()
    $status = $null; $msg = $null

    try {
        if (-not $api -or -not $build) {
            $status = 'FAILED'; $msg = "CSV line ${line}: ApiName and BuildName are both required"
        }
        elseif ($seen.ContainsKey($api.ToLower())) {
            $status = 'SKIPPED'; $msg = "Duplicate ApiName in CSV (line $line)"
        }
        else {
            $seen[$api.ToLower()] = $true
            if (Test-ReleaseExists $api) {
                $status = 'EXISTS'; $msg = "Release pipeline '$api' already exists"
            }
            else {
                $buildDef = Get-BuildDefinition $build
                $payload  = New-ReleasePayload $template $api $buildDef
                if ($DryRun) {
                    $status = 'OK-DRY'; $msg = "Would create '$api' using build '$($buildDef.name)' (id $($buildDef.id))"
                }
                else {
                    $created = Invoke-Ado POST "$releaseApi/release/definitions" $payload
                    $status = 'CREATED'; $msg = "Release id $($created.id) linked to build '$($buildDef.name)'"
                }
            }
        }
    }
    catch {
        $status = 'FAILED'; $msg = $_.Exception.Message
    }

    $color = switch ($status) { 'CREATED' {'Green'} 'OK-DRY' {'Green'} 'EXISTS' {'Yellow'} 'SKIPPED' {'Yellow'} default {'Red'} }
    Write-Host ("[{0,-7}] {1} - {2}" -f $status, $(if ($api) { $api } else { '(blank)' }), $msg) -ForegroundColor $color
    $results.Add([pscustomobject]@{ ApiName = $api; BuildName = $build; Status = $status; Message = $msg })
}

$results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8

Write-Host "`nSummary: $((($results | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '))"
Write-Host "Report : $ReportPath"

if ($results | Where-Object { $_.Status -eq 'FAILED' }) { exit 1 }
