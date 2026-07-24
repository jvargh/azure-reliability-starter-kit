<#
.SYNOPSIS
  Upload knowledge documents into an Azure SRE Agent's Knowledge settings so it has the app
  topology and triage/mitigation runbook up front (and stops rediscovering the layout each incident).

.DESCRIPTION
  Uploads every .md/.txt file in the -KnowledgeDir folder to the agent's data-plane AgentMemory
  endpoint (POST {agentEndpoint}/api/v1/AgentMemory/upload?triggerIndexing=true), the same mechanism
  the upstream Apply-Extras.ps1 uses for `knowledge` entries. Documents are indexed for semantic
  search; re-uploading the same filename replaces the content (idempotent).

  Requires a data-plane token (audience https://azuresre.dev). If you are not signed in for that
  audience the script tells you how: az login --scope "https://azuresre.dev/.default".

  See: https://learn.microsoft.com/en-us/azure/sre-agent/upload-knowledge-document

.EXAMPLE
  ./upload-knowledge.ps1
  ./upload-knowledge.ps1 -AgentName sre-checkout -ResourceGroup rg-sre-checkout
#>
param(
  [string]$Subscription,
  [string]$ResourceGroup = 'rg-sre-checkout',
  [string]$AgentName = 'sre-checkout',
  [string]$KnowledgeDir = (Join-Path $PSScriptRoot 'knowledge'),
  [string]$RunbooksDir = (Join-Path $PSScriptRoot 'src/remediation-runbooks'),
  [switch]$SkipRunbooks,
  [switch]$NoIndex
)

$ErrorActionPreference = 'Stop'
$ApiVersion = '2025-05-01-preview'

function Write-Info([string]$m) { Write-Host "    $m" }
function Write-Good([string]$m) { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "    $m" -ForegroundColor Yellow }

if ($Subscription) { az account set --subscription $Subscription | Out-Null }
$Subscription = az account show --query id -o tsv

if (-not (Test-Path $KnowledgeDir -PathType Container)) { throw "Knowledge folder not found: $KnowledgeDir" }
$files = Get-ChildItem -Path $KnowledgeDir -File -Recurse | Where-Object { $_.Extension -in '.md', '.txt' }
if (-not $files) { throw "No .md/.txt files found in $KnowledgeDir" }

# Remediation runbooks are executable .ps1 scripts (not an indexable knowledge type), so wrap each
# one into a Markdown doc generated from the real script (single source of truth) and upload those too.
$runbookDocs = @()
if (-not $SkipRunbooks -and (Test-Path $RunbooksDir -PathType Container)) {
  foreach ($rb in (Get-ChildItem -Path $RunbooksDir -File -Filter '*.ps1' | Sort-Object Name)) {
    $code = Get-Content -Raw $rb.FullName
    $synopsis = ''
    if ($code -match '(?ms)\.SYNOPSIS\s*\r?\n\s*(.+?)\r?\n\s*(\.[A-Z]|#>)') { $synopsis = $Matches[1].Trim() }
    $md = @"
# Remediation runbook: $($rb.Name)

$synopsis

Run this script to apply the mitigation. It auto-discovers the backend App Service in ``rg-sli-demo``.
The agent can perform the equivalent action directly via the Azure CLI commands shown below.

``````powershell
$code
``````
"@
    $runbookDocs += [pscustomobject]@{ Name = "runbook-$($rb.BaseName).md"; Bytes = [System.Text.Encoding]::UTF8.GetBytes($md) }
  }
}

Write-Host ''
Write-Host '=================== Upload knowledge to SRE Agent ===================' -ForegroundColor DarkCyan
Write-Info "Agent : $AgentName ($ResourceGroup)"
Write-Info "Files : $($files.Count) knowledge + $($runbookDocs.Count) runbook doc(s)"

# Resolve the agent's data-plane endpoint from ARM.
$armBase = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName"
$agent = az rest -m GET --url "$armBase`?api-version=$ApiVersion" -o json 2>$null | ConvertFrom-Json
$endpoint = $agent.properties.agentEndpoint
if (-not $endpoint) { throw "Could not resolve agent endpoint. Is $AgentName provisioned in $ResourceGroup?" }
Write-Info "Endpoint : $endpoint"

# Data-plane token (audience https://azuresre.dev).
$token = az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $token) {
  Write-Warn 'No data-plane token. Sign in for the SRE data-plane audience, then re-run:'
  Write-Warn '  az login --scope "https://azuresre.dev/.default"'
  throw 'data-plane token unavailable'
}

$trigger = if ($NoIndex) { 'false' } else { 'true' }
$url = "$endpoint/api/v1/AgentMemory/upload?triggerIndexing=$trigger"
$LF = "`r`n"
$ok = 0

function Send-Doc([string]$Name, [byte[]]$FileBytes) {
  Write-Host "==> Uploading $Name" -ForegroundColor Cyan
  try {
    $boundary = [guid]::NewGuid().ToString()
    $header = @(
      "--$boundary"
      "Content-Disposition: form-data; name=`"files`"; filename=`"$Name`""
      'Content-Type: text/markdown'
      ''
    ) -join $LF
    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($header + $LF)
    $footerBytes = [System.Text.Encoding]::UTF8.GetBytes("$LF--$boundary--$LF")

    $ms = [System.IO.MemoryStream]::new()
    $ms.Write($headerBytes, 0, $headerBytes.Length)
    $ms.Write($FileBytes, 0, $FileBytes.Length)
    $ms.Write($footerBytes, 0, $footerBytes.Length)
    $body = $ms.ToArray(); $ms.Dispose()

    $null = Invoke-WebRequest -TimeoutSec 60 -Uri $url -Method Post `
      -Headers @{ Authorization = "Bearer $token" } `
      -ContentType "multipart/form-data; boundary=$boundary" `
      -Body $body
    Write-Good 'ok (indexed for semantic search)'
    return $true
  } catch {
    Write-Warn "FAILED - $($_.Exception.Message)"
    return $false
  }
}

foreach ($f in $files) {
  if (Send-Doc $f.Name ([System.IO.File]::ReadAllBytes($f.FullName))) { $ok++ }
}
foreach ($d in $runbookDocs) {
  if (Send-Doc $d.Name $d.Bytes) { $ok++ }
}

$total = $files.Count + $runbookDocs.Count
Write-Host ''
Write-Good "$ok/$total document(s) uploaded to $AgentName Knowledge settings."
Write-Info 'Verify in the portal: Builder -> Knowledge settings. New incidents will reference these docs.'
