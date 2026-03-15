[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("track", "sync", "status", "watch", "watch-status", "serve")]
  [string]$Command,

  [string]$Id,
  [string]$Url,
  [string]$Branch,
  [string]$Focus,
  [int]$IntervalSeconds = 300,
  [int]$Iterations = 0,
  [int]$Port = 8787
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "Repobrdige.psm1") -Force

switch ($Command) {
  "track" {
    if (-not $Url) {
      throw "--Url is required for track"
    }

    Ensure-TrackedRepo -Root $PSScriptRoot -Id $Id -UpstreamUrl $Url -DefaultBranch $Branch -Focus $Focus |
      ConvertTo-Json -Depth 100
    break
  }

  "sync" {
    if (-not $Id) {
      throw "--Id is required for sync"
    }

    $null = Sync-TrackedRepo -Root $PSScriptRoot -RepoId $Id
    [ordered]@{
      repo = Get-RepoSummary -Root $PSScriptRoot -RepoId $Id
    } | ConvertTo-Json -Depth 100
    break
  }

  "status" {
    if (-not $Id) {
      throw "--Id is required for status"
    }

    [ordered]@{
      repo = Get-RepoSummary -Root $PSScriptRoot -RepoId $Id
    } | ConvertTo-Json -Depth 100
    break
  }

  "watch" {
    Start-RepobrdigeWatch -Root $PSScriptRoot -IntervalSeconds $IntervalSeconds -Iterations $Iterations |
      ConvertTo-Json -Depth 100
    break
  }

  "watch-status" {
    Get-WatchStatus -Root $PSScriptRoot |
      ConvertTo-Json -Depth 100
    break
  }

  "serve" {
    Start-RepobrdigeServer -Root $PSScriptRoot -Port $Port -MaxRequests $Iterations
    break
  }
}
