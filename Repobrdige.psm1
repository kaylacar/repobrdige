Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AppPaths {
  param([string]$Root)

  [pscustomobject]@{
    Root = $Root
    DataRoot = Join-Path $Root "data"
    ReposRoot = Join-Path $Root "data\repos"
    MirrorsRoot = Join-Path $Root "data\mirrors"
    RuntimeRoot = Join-Path $Root "data\runtime"
    LocksRoot = Join-Path $Root "data\locks"
  }
}

function Get-RepoPaths {
  param(
    [string]$Root,
    [string]$RepoId
  )

  $appPaths = Get-AppPaths -Root $Root
  $base = Join-Path $appPaths.ReposRoot $RepoId

  [pscustomobject]@{
    Base = $base
    ConfigFile = Join-Path $base "config.json"
    StateFile = Join-Path $base "state.json"
    ContextDir = Join-Path $base "context"
    DraftsDir = Join-Path $base "drafts"
    MirrorDir = Join-Path $appPaths.MirrorsRoot $RepoId
  }
}

function Ensure-Directory {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Read-JsonFile {
  param(
    [string]$Path,
    $Fallback = $null
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $Fallback
  }

  Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile {
  param(
    [string]$Path,
    $Value
  )

  Ensure-Directory -Path (Split-Path -Parent $Path)
  $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-IsoNow {
  (Get-Date).ToUniversalTime().ToString("o")
}

function Get-Slug {
  param([string]$Value)

  $slug = $Value.ToLowerInvariant() -replace "[^a-z0-9]+", "-" -replace "^-+|-+$", ""
  if ($slug.Length -gt 80) {
    return $slug.Substring(0, 80)
  }
  return $slug
}

function Invoke-Git {
  param(
    [string[]]$Arguments,
    [string]$WorkingDirectory
  )

  Push-Location
  $oldPreference = $ErrorActionPreference
  try {
    if ($WorkingDirectory) {
      Set-Location -LiteralPath $WorkingDirectory
      $normalizedSafeDirectory = ((Resolve-Path -LiteralPath $WorkingDirectory).Path -replace "\\", "/")
      $Arguments = @("-c", "safe.directory=$normalizedSafeDirectory") + $Arguments
    }

    $ErrorActionPreference = "Continue"
    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
      $joined = "git " + ($Arguments -join " ")
      $detail = ($output | Out-String).Trim()
      throw "$joined failed: $detail"
    }

    return ($output | Out-String).Trim()
  } finally {
    $ErrorActionPreference = $oldPreference
    Pop-Location
  }
}

function Ensure-TrackedRepo {
  param(
    [string]$Root,
    [string]$Id,
    [string]$UpstreamUrl,
    [string]$DefaultBranch,
    [string]$Focus
  )

  $repoId = if ($Id) { $Id } else { Get-Slug -Value $UpstreamUrl }
  $appPaths = Get-AppPaths -Root $Root
  $paths = Get-RepoPaths -Root $Root -RepoId $repoId

  Ensure-Directory -Path $appPaths.ReposRoot
  Ensure-Directory -Path $appPaths.MirrorsRoot
  Ensure-Directory -Path $paths.Base
  Ensure-Directory -Path $paths.ContextDir
  Ensure-Directory -Path $paths.DraftsDir

  $existing = Read-JsonFile -Path $paths.ConfigFile
  $config = [ordered]@{
    id = $repoId
    upstreamUrl = $UpstreamUrl
    defaultBranch = $DefaultBranch
    focus = $Focus
    createdAt = if ($existing) { $existing.createdAt } else { Get-IsoNow }
    updatedAt = Get-IsoNow
  }

  Write-JsonFile -Path $paths.ConfigFile -Value $config

  New-TrackResponse -RepoId $repoId -Config $config
}

function Start-RepobrdigeWatch {
  param(
    [string]$Root,
    [int]$IntervalSeconds = 300,
    [int]$Iterations = 0
  )

  if ($IntervalSeconds -lt 5) {
    throw "IntervalSeconds must be at least 5."
  }

  $appPaths = Get-AppPaths -Root $Root
  Ensure-Directory -Path $appPaths.RuntimeRoot
  Ensure-Directory -Path $appPaths.LocksRoot

  $runId = [guid]::NewGuid().ToString("N")
  $watchFile = Join-Path $appPaths.RuntimeRoot "watch-state.json"
  $iteration = 0

  return Use-FileLock -LockFile (Join-Path $appPaths.LocksRoot "watch.lock") -Script {
    while ($true) {
      $iteration += 1
      $cycleStartedAt = Get-IsoNow
      $cycle = Invoke-SyncCycle -Root $Root
      $watchState = [ordered]@{
        runId = $runId
        intervalSeconds = $IntervalSeconds
        iteration = $iteration
        cycleStartedAt = $cycleStartedAt
        cycleFinishedAt = Get-IsoNow
        trackedRepoCount = Get-ListCount -Items $cycle.results
        results = $cycle.results
      }

      Write-JsonFile -Path $watchFile -Value $watchState

      if ($Iterations -gt 0 -and $iteration -ge $Iterations) {
        return [pscustomobject]$watchState
      }

      Start-Sleep -Seconds $IntervalSeconds
    }
  }
}

function Start-RepobrdigeServer {
  param(
    [string]$Root,
    [int]$Port = 8787,
    [int]$MaxRequests = 0
  )

  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
  $listener.Start()

  $handled = 0
  try {
    while ($true) {
      $client = $listener.AcceptTcpClient()
      $handled += 1

      try {
        $request = Read-HttpRequest -Client $client
        $asset = Get-StaticAsset -Root $Root -AbsolutePath $request.Path
        if ($asset) {
          Write-StaticTcpResponse -Client $client -StatusCode 200 -ContentType $asset.type -FilePath $asset.path
        } else {
          $payload = Invoke-RepobrdigeApiRequest -Root $Root -Request $request
          Write-JsonTcpResponse -Client $client -StatusCode 200 -Payload $payload
        }
      } catch {
        Write-JsonTcpResponse -Client $client -StatusCode 500 -Payload ([ordered]@{
          error = $_.Exception.Message
        })
      } finally {
        $client.Close()
      }

      if ($MaxRequests -gt 0 -and $handled -ge $MaxRequests) {
        break
      }
    }
  } finally {
    $listener.Stop()
    $listener.Close()
  }
}

function Invoke-RepobrdigeApiRequest {
  param(
    [string]$Root,
    $Request
  )

  $segments = @($Request.Path.Trim("/") -split "/" | Where-Object { $_ })
  if ($segments.Count -eq 0) {
    return [ordered]@{
      service = "repobrdige"
      version = "v2"
      endpoints = @(
        "/health",
        "/repos",
        "/repos/{id}/status",
        "/repos/{id}/sync",
        "/watch-status"
      )
    }
  }

  if ($segments[0] -eq "health") {
    return [ordered]@{
      ok = $true
      service = "repobrdige"
      time = Get-IsoNow
    }
  }

  if ($segments[0] -eq "watch-status") {
    return [ordered]@{
      watch = Get-WatchStatus -Root $Root
    }
  }

  if ($segments[0] -eq "repos" -and $segments.Count -eq 1) {
    if ($Request.Method -eq "POST") {
      $payload = Get-JsonBody -Request $Request
      if (-not $payload.url) {
        throw "Field 'url' is required."
      }

      $payloadId = if ($payload.PSObject.Properties.Name -contains "id") { $payload.id } else { $null }
      $payloadBranch = if ($payload.PSObject.Properties.Name -contains "branch") { $payload.branch } else { $null }
      $payloadFocus = if ($payload.PSObject.Properties.Name -contains "focus") { $payload.focus } else { $null }
      $track = Ensure-TrackedRepo -Root $Root -Id $payloadId -UpstreamUrl $payload.url -DefaultBranch $payloadBranch -Focus $payloadFocus
      return $track
    }

    $repoIds = Get-TrackedRepoIds -Root $Root
    return [ordered]@{
      repos = @($repoIds | ForEach-Object {
        New-RepoApiSummary -RepoId $_ -Status (Get-RepoStatus -Root $Root -RepoId $_)
      })
    }
  }

  if ($segments[0] -eq "repos" -and $segments.Count -ge 2) {
    $repoId = $segments[1]

    if ($segments.Count -eq 3 -and $segments[2] -eq "status") {
      return [ordered]@{
        repo = New-RepoApiSummary -RepoId $repoId -Status (Get-RepoStatus -Root $Root -RepoId $repoId)
      }
    }

    if ($segments.Count -eq 3 -and $segments[2] -eq "sync") {
      if ($Request.Method -ne "POST") {
        throw "POST required for /repos/$repoId/sync"
      }
      return [ordered]@{
        repo = New-SyncResponse -SyncResult (Sync-TrackedRepo -Root $Root -RepoId $repoId)
      }
    }
  }

  throw "Unknown endpoint: $($Request.Path)"
}

function Get-StaticAsset {
  param(
    [string]$Root,
    [string]$AbsolutePath
  )

  $uiRoot = Join-Path $Root "ui"
  switch ($AbsolutePath) {
    "/app" {
      return [ordered]@{
        type = "text/html; charset=utf-8"
        path = Join-Path $uiRoot "app.html"
      }
    }
    "/app.js" {
      return [ordered]@{
        type = "application/javascript; charset=utf-8"
        path = Join-Path $uiRoot "app.js"
      }
    }
    default {
      return $null
    }
  }
}

function Invoke-SyncCycle {
  param([string]$Root)

  $repoIds = Get-TrackedRepoIds -Root $Root
  $results = @()
  foreach ($repoId in $repoIds) {
    try {
      $syncResult = Sync-TrackedRepo -Root $Root -RepoId $repoId
      $results += [ordered]@{
        repoId = $repoId
        status = "synced"
        basisCommit = $syncResult.state.lastSyncedCommit
        draftGenerated = ($null -ne $syncResult.draft)
        syncedAt = $syncResult.state.lastSyncAt
      }
    } catch {
      $results += [ordered]@{
        repoId = $repoId
        status = "failed"
        error = $_.Exception.Message
        syncedAt = Get-IsoNow
      }
    }
  }

  [pscustomobject]@{
    repoIds = $repoIds
    results = $results
  }
}

function Sync-TrackedRepo {
  param(
    [string]$Root,
    [string]$RepoId
  )

  $paths = Get-RepoPaths -Root $Root -RepoId $RepoId
  $config = Read-JsonFile -Path $paths.ConfigFile
  if (-not $config) {
    throw "Unknown repo id: $RepoId"
  }
  $locksRoot = (Get-AppPaths -Root $Root).LocksRoot
  Ensure-Directory -Path $locksRoot

  return Use-FileLock -LockFile (Join-Path $locksRoot "$RepoId.lock") -Script {
    Ensure-Directory -Path (Split-Path -Parent $paths.MirrorDir)

    $localSource = Get-LocalRepoSourcePath -UpstreamUrl $config.upstreamUrl
    if ($localSource) {
      Sync-LocalMirror -SourcePath $localSource -MirrorDir $paths.MirrorDir
    } else {
      if (-not (Test-Path -LiteralPath (Join-Path $paths.MirrorDir ".git"))) {
        Invoke-Git -Arguments @("clone", $config.upstreamUrl, $paths.MirrorDir) | Out-Null
      } else {
        Invoke-Git -Arguments @("fetch", "--all", "--prune") -WorkingDirectory $paths.MirrorDir | Out-Null
      }
    }

    $branch = if ($config.defaultBranch) {
      $config.defaultBranch
    } elseif ($localSource) {
      Invoke-Git -Arguments @("rev-parse", "--abbrev-ref", "HEAD") -WorkingDirectory $paths.MirrorDir
    } else {
      (Invoke-Git -Arguments @("symbolic-ref", "--short", "refs/remotes/origin/HEAD") -WorkingDirectory $paths.MirrorDir) -replace "^origin/", ""
    }

    if (-not $localSource) {
      $hasLocalBranch = Invoke-Git -Arguments @("branch", "--list", $branch) -WorkingDirectory $paths.MirrorDir
      if ([string]::IsNullOrWhiteSpace($hasLocalBranch)) {
        Invoke-Git -Arguments @("switch", "-c", $branch, "--track", "origin/$branch") -WorkingDirectory $paths.MirrorDir | Out-Null
      } else {
        Invoke-Git -Arguments @("switch", $branch) -WorkingDirectory $paths.MirrorDir | Out-Null
      }

      Invoke-Git -Arguments @("pull", "--ff-only", "origin", $branch) -WorkingDirectory $paths.MirrorDir | Out-Null
    }

    $previousState = Read-JsonFile -Path $paths.StateFile -Fallback ([ordered]@{})
    $previousLastAnalyzedCommit = if ($previousState -and $previousState.PSObject.Properties.Name -contains "lastAnalyzedCommit") {
      $previousState.lastAnalyzedCommit
    } else {
      $null
    }
    $lastSyncedCommit = Invoke-Git -Arguments @("rev-parse", "HEAD") -WorkingDirectory $paths.MirrorDir
    $contextPack = New-ContextPack -MirrorDir $paths.MirrorDir -RepoId $RepoId -BasisCommit $lastSyncedCommit -PreviousCommit $previousLastAnalyzedCommit

    $state = [ordered]@{
      id = $RepoId
      upstreamUrl = $config.upstreamUrl
      defaultBranch = $branch
      localPath = $paths.MirrorDir
      lastSyncedCommit = $lastSyncedCommit
      lastAnalyzedCommit = $previousLastAnalyzedCommit
      lastSyncAt = Get-IsoNow
      status = "synced"
      lastError = $null
    }

    Write-JsonFile -Path $paths.StateFile -Value $state
    Write-JsonFile -Path (Join-Path $paths.ContextDir "$lastSyncedCommit.json") -Value $contextPack

    $draft = $null
    if ($contextPack.deltaSummary.meaningful) {
      Set-SupersededDrafts -DraftsDir $paths.DraftsDir -LatestCommit $lastSyncedCommit | Out-Null
      $draft = New-RepoMessageDraft -RepoId $RepoId -RepoLabel (Get-RepoLabel -Url $config.upstreamUrl) -BasisCommit $lastSyncedCommit -ContextPack $contextPack -Focus $config.focus
      Write-JsonFile -Path (Join-Path $paths.DraftsDir "$($draft.id).json") -Value $draft
    }

    $state.lastAnalyzedCommit = $lastSyncedCommit
    $state.lastAnalyzedAt = Get-IsoNow
    Write-JsonFile -Path $paths.StateFile -Value $state

    [pscustomobject]@{
      repoId = $RepoId
      state = $state
      contextPack = $contextPack
      draft = $draft
      drafts = [object[]](Get-RepoDrafts -DraftsDir $paths.DraftsDir)
    }
  }
}

function Get-RepoStatus {
  param(
    [string]$Root,
    [string]$RepoId
  )

  $paths = Get-RepoPaths -Root $Root -RepoId $RepoId
  [pscustomobject]@{
    config = Read-JsonFile -Path $paths.ConfigFile
    state = Read-JsonFile -Path $paths.StateFile
    drafts = [object[]](Get-RepoDrafts -DraftsDir $paths.DraftsDir)
  }
}

function Get-WatchStatus {
  param([string]$Root)

  $watchFile = Join-Path (Get-AppPaths -Root $Root).RuntimeRoot "watch-state.json"
  Read-JsonFile -Path $watchFile -Fallback $null
}

function Use-FileLock {
  param(
    [string]$LockFile,
    [scriptblock]$Script
  )

  Ensure-Directory -Path (Split-Path -Parent $LockFile)
  $lockStream = $null
  try {
    $lockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  } catch {
    throw "Lock unavailable for $LockFile"
  }

  try {
    & $Script
  } finally {
    if ($lockStream) {
      $lockStream.Dispose()
    }
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
  }
}

function Write-JsonResponse {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    $Payload
  )

  $json = if ($null -eq $Payload) { "null" } else { $Payload | ConvertTo-Json -Depth 100 }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = "application/json; charset=utf-8"
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Response.OutputStream.Close()
}

function Write-StaticResponse {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    [string]$ContentType,
    [string]$FilePath
  )

  $bytes = [System.IO.File]::ReadAllBytes($FilePath)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Response.OutputStream.Close()
}

function Read-HttpRequest {
  param([System.Net.Sockets.TcpClient]$Client)

  $stream = $Client.GetStream()
  $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
  $requestLine = $reader.ReadLine()
  if ([string]::IsNullOrWhiteSpace($requestLine)) {
    throw "Invalid HTTP request"
  }

  $parts = $requestLine.Split(" ")
  $method = $parts[0]
  $target = $parts[1]
  $headers = @{}
  while ($true) {
    $line = $reader.ReadLine()
    if ([string]::IsNullOrEmpty($line)) {
      break
    }
    $split = $line.Split(":", 2)
    if ($split.Length -eq 2) {
      $headers[$split[0].Trim().ToLowerInvariant()] = $split[1].Trim()
    }
  }

  $body = $null
  if ($headers.ContainsKey("content-length")) {
    $length = [int]$headers["content-length"]
    if ($length -gt 0) {
      $buffer = New-Object char[] $length
      $read = $reader.ReadBlock($buffer, 0, $length)
      $body = -join $buffer[0..($read - 1)]
    }
  }

  [pscustomobject]@{
    Method = $method
    Path = ($target -split "\?")[0]
    Headers = $headers
    Body = $body
  }
}

function Write-JsonTcpResponse {
  param(
    [System.Net.Sockets.TcpClient]$Client,
    [int]$StatusCode,
    $Payload
  )

  $json = if ($null -eq $Payload) { "null" } else { $Payload | ConvertTo-Json -Depth 100 }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  Write-TcpResponse -Client $Client -StatusCode $StatusCode -ContentType "application/json; charset=utf-8" -Bytes $bytes
}

function Write-StaticTcpResponse {
  param(
    [System.Net.Sockets.TcpClient]$Client,
    [int]$StatusCode,
    [string]$ContentType,
    [string]$FilePath
  )

  $bytes = [System.IO.File]::ReadAllBytes($FilePath)
  Write-TcpResponse -Client $Client -StatusCode $StatusCode -ContentType $ContentType -Bytes $bytes
}

function Write-TcpResponse {
  param(
    [System.Net.Sockets.TcpClient]$Client,
    [int]$StatusCode,
    [string]$ContentType,
    [byte[]]$Bytes
  )

  $statusText = Get-HttpStatusText -StatusCode $StatusCode
  $header = @(
    "HTTP/1.1 $StatusCode $statusText",
    "Content-Type: $ContentType",
    "Content-Length: $($Bytes.Length)",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"

  $stream = $Client.GetStream()
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  $stream.Write($Bytes, 0, $Bytes.Length)
  $stream.Flush()
}

function Get-HttpStatusText {
  param([int]$StatusCode)

  switch ($StatusCode) {
    200 { "OK" }
    500 { "Internal Server Error" }
    default { "OK" }
  }
}

function Get-JsonBody {
  param($Request)

  if ([string]::IsNullOrWhiteSpace($Request.Body)) {
    return [pscustomobject]@{}
  }

  $Request.Body | ConvertFrom-Json
}

function New-ContextPack {
  param(
    [string]$MirrorDir,
    [string]$RepoId,
    [string]$BasisCommit,
    [AllowNull()][string]$PreviousCommit
  )

  $readmePreview = Get-ReadmePreview -MirrorDir $MirrorDir
  $keyFiles = Get-KeyFiles -MirrorDir $MirrorDir
  $recentCommits = Get-RecentCommits -MirrorDir $MirrorDir -Limit 5
  $changedFiles = if ($PreviousCommit) {
    Split-Lines (Invoke-Git -Arguments @("diff", "--name-only", "$PreviousCommit..$BasisCommit") -WorkingDirectory $MirrorDir)
  } else {
    @($keyFiles | ForEach-Object { $_.path })
  }
  $commitSubjects = if ($PreviousCommit) {
    Split-Lines (Invoke-Git -Arguments @("log", "--pretty=format:%s", "$PreviousCommit..$BasisCommit") -WorkingDirectory $MirrorDir)
  } else {
    @($recentCommits | ForEach-Object { $_.subject })
  }

  $delta = Test-MeaningfulDelta -ChangedFiles $changedFiles -LastAnalyzedCommit $PreviousCommit

  [ordered]@{
    repoId = $RepoId
    basisCommit = $BasisCommit
    previousCommit = $PreviousCommit
    generatedAt = Get-IsoNow
    repoSummary = $readmePreview
    keyFiles = $keyFiles
    recentCommits = $recentCommits
    deltaSummary = [ordered]@{
      changedFiles = [object[]]$changedFiles
      commitSubjects = [object[]]$commitSubjects
      changedFileCount = Get-ListCount -Items $changedFiles
      commitCount = Get-ListCount -Items $commitSubjects
      meaningful = $delta.meaningful
      reason = $delta.reason
    }
  }
}

function Test-MeaningfulDelta {
  param(
    [string[]]$ChangedFiles,
    [AllowNull()][string]$LastAnalyzedCommit
  )

  if (-not $LastAnalyzedCommit) {
    return [ordered]@{ meaningful = $true; reason = "initial-analysis" }
  }

  if ((Get-ListCount -Items $ChangedFiles) -eq 0) {
    return [ordered]@{ meaningful = $false; reason = "no-change" }
  }

  $substantive = @(
    $ChangedFiles | Where-Object {
      $_ -notmatch "^\.gitignore$" -and
      $_ -notmatch "^license" -and
      $_ -notmatch "^.*\.lock$" -and
      $_ -notmatch "^\.github/" -and
      $_ -notmatch "^.*\.(png|jpg|jpeg|gif|svg)$"
    }
  )

  if ((Get-ListCount -Items $substantive) -eq 0) {
    return [ordered]@{ meaningful = $false; reason = "trivial-change-only" }
  }

  [ordered]@{
    meaningful = $true
    reason = "substantive-files-changed"
  }
}

function New-RepoMessageDraft {
  param(
    [string]$RepoId,
    [string]$RepoLabel,
    [string]$BasisCommit,
    $ContextPack,
    [string]$Focus
  )

  $shortCommit = $BasisCommit.Substring(0, [Math]::Min(12, $BasisCommit.Length))
  $changedFiles = @($ContextPack.deltaSummary.changedFiles | Select-Object -First 5)
  $subjects = @($ContextPack.deltaSummary.commitSubjects | Select-Object -First 3)

  [ordered]@{
    id = "$shortCommit-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    repoId = $RepoId
    basisCommit = $BasisCommit
    title = "${RepoLabel}: current upstream delta at $shortCommit"
    summary = @(
      "I mirrored the latest upstream state for $RepoLabel and reviewed the delta at $shortCommit.",
      "This draft is based on $($ContextPack.deltaSummary.commitCount) recent commit(s) and $($ContextPack.deltaSummary.changedFileCount) changed file(s).",
      $(if ($Focus) { "Tracking focus: $Focus." } else { "This is a general public-repo observation draft." })
    ) -join " "
    evidence = @(
      $(if ((Get-ListCount -Items $changedFiles) -gt 0) { "Changed files: $($changedFiles -join ', ')" } else { "Changed files: none" }),
      $(if ((Get-ListCount -Items $subjects) -gt 0) { "Recent commit subjects: $($subjects -join ' | ')" } else { "Recent commit subjects: unavailable" }),
      "README snapshot: $(Get-ShortText -Text $ContextPack.repoSummary -MaxLength 220)"
    )
    proposalOrQuestion = $(if ($Focus) {
      "I am tracking this repo for $Focus. If useful, I can turn this delta into a tighter patch or question scoped to the current upstream state."
    } else {
      "If useful, I can follow up with a tighter patch, issue, or question scoped to the current upstream state rather than a stale snapshot."
    })
    references = @($changedFiles | ForEach-Object { [ordered]@{ type = "file"; value = $_ } })
    status = "ready"
    generatedAt = Get-IsoNow
  }
}

function Set-SupersededDrafts {
  param(
    [string]$DraftsDir,
    [string]$LatestCommit
  )

  foreach ($draft in [object[]](Get-RepoDrafts -DraftsDir $DraftsDir)) {
    if (($draft.status -eq "draft" -or $draft.status -eq "ready") -and $draft.basisCommit -ne $LatestCommit) {
      $draft.status = "superseded"
      $draft | Add-Member -NotePropertyName supersededAt -NotePropertyValue (Get-IsoNow) -Force
      Write-JsonFile -Path (Join-Path $DraftsDir "$($draft.id).json") -Value $draft
    }
  }
}

function Get-RepoDrafts {
  param([string]$DraftsDir)

  if (-not (Test-Path -LiteralPath $DraftsDir)) {
    return @()
  }

  [object[]]$items = @(Get-ChildItem -LiteralPath $DraftsDir -Filter *.json | Sort-Object Name | ForEach-Object {
    Read-JsonFile -Path $_.FullName
  } | Sort-Object -Property generatedAt -Descending)
  return $items
}

function Get-ReadmePreview {
  param([string]$MirrorDir)

  foreach ($candidate in @("README.md", "README", "readme.md")) {
    $fullPath = Join-Path $MirrorDir $candidate
    if (Test-Path -LiteralPath $fullPath) {
      $lines = Get-Content -LiteralPath $fullPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Select-Object -First 8
      if ($lines) {
        return ($lines -join " ")
      }
    }
  }

  "No README preview available."
}

function Get-KeyFiles {
  param([string]$MirrorDir)

  $priority = @("README.md", "README", "package.json", "Cargo.toml", "pyproject.toml", "Makefile", "CMakeLists.txt", "go.mod")
  $rootFiles = @(Get-ChildItem -LiteralPath $MirrorDir -File | Select-Object -ExpandProperty Name)
  $selected = @()
  foreach ($name in $priority) {
    if ($rootFiles -contains $name) {
      $selected += $name
    }
  }
  $selected += @($rootFiles | Where-Object { $_ -notin $selected } | Sort-Object | Select-Object -First 5)
  $selected = @($selected | Select-Object -First 8)

  @($selected | ForEach-Object {
    $fullPath = Join-Path $MirrorDir $_
    $preview = try {
      $lines = Get-Content -LiteralPath $fullPath -ErrorAction Stop |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Select-Object -First 3
      if ($lines) { $lines -join " " } else { "(empty file)" }
    } catch {
      "(binary or unreadable preview)"
    }

    [ordered]@{
      path = $_
      preview = $preview
    }
  })
}

function Get-RecentCommits {
  param(
    [string]$MirrorDir,
    [int]$Limit
  )

  $lines = Split-Lines (Invoke-Git -Arguments @("log", "-n$Limit", "--pretty=format:%H%x09%ad%x09%s", "--date=short") -WorkingDirectory $MirrorDir)
  @($lines | ForEach-Object {
    $parts = $_ -split "`t", 3
    [ordered]@{
      sha = $parts[0]
      date = $parts[1]
      subject = $parts[2]
    }
  })
}

function Split-Lines {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return @()
  }

  @($Text -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ShortText {
  param(
    [string]$Text,
    [int]$MaxLength
  )

  if ($Text.Length -le $MaxLength) {
    return $Text
  }

  $Text.Substring(0, $MaxLength - 3) + "..."
}

function Get-RepoLabel {
  param([string]$Url)

  (($Url -replace "\.git$", "") -split "/" | Select-Object -Last 2) -join "/"
}

function Get-ListCount {
  param($Items)

  if ($null -eq $Items) {
    return 0
  }

  @($Items).Length
}

function Get-TrackedRepoIds {
  param([string]$Root)

  $reposRoot = (Get-AppPaths -Root $Root).ReposRoot
  if (-not (Test-Path -LiteralPath $reposRoot)) {
    return @()
  }

  @(
    Get-ChildItem -LiteralPath $reposRoot -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "config.json") } |
      Select-Object -ExpandProperty Name |
      Sort-Object
  )
}

function Get-RepoFreshness {
  param($State)

  if (-not $State) {
    return "untracked"
  }

  if ($State.status -ne "synced") {
    return "degraded"
  }

  "fresh"
}

function New-TrackResponse {
  param(
    [string]$RepoId,
    $Config
  )

  [ordered]@{
    repo = [ordered]@{
      id = $RepoId
      upstreamUrl = $Config.upstreamUrl
      defaultBranch = $Config.defaultBranch
      focus = $Config.focus
      tracked = $true
      createdAt = $Config.createdAt
      updatedAt = $Config.updatedAt
    }
  }
}

function New-SyncResponse {
  param($SyncResult)

  New-RepoApiSummary -RepoId $SyncResult.repoId -Status ([ordered]@{
    config = [ordered]@{
      id = $SyncResult.repoId
      upstreamUrl = $SyncResult.state.upstreamUrl
      defaultBranch = $SyncResult.state.defaultBranch
      focus = $null
    }
    state = $SyncResult.state
    drafts = $SyncResult.drafts
  })
}

function Get-RepoSummary {
  param(
    [string]$Root,
    [string]$RepoId
  )

  New-RepoApiSummary -RepoId $RepoId -Status (Get-RepoStatus -Root $Root -RepoId $RepoId)
}

function New-RepoApiSummary {
  param(
    [string]$RepoId,
    $Status
  )

  $config = $Status.config
  $state = $Status.state
  $drafts = @($Status.drafts)
  $latestDraft = if ((Get-ListCount -Items $drafts) -gt 0) { $drafts[0] } else { $null }

  [ordered]@{
    id = $RepoId
    upstreamUrl = if ($config) { $config.upstreamUrl } else { $state.upstreamUrl }
    defaultBranch = if ($state) { $state.defaultBranch } else { $config.defaultBranch }
    focus = if ($config) { $config.focus } else { $null }
    sync = [ordered]@{
      status = if ($state) { $state.status } else { "untracked" }
      freshness = Get-RepoFreshness -State $state
      lastSyncedCommit = if ($state) { $state.lastSyncedCommit } else { $null }
      lastAnalyzedCommit = if ($state) { $state.lastAnalyzedCommit } else { $null }
      lastSyncAt = if ($state) { $state.lastSyncAt } else { $null }
      lastAnalyzedAt = if ($state) { $state.lastAnalyzedAt } else { $null }
      lastError = if ($state) { $state.lastError } else { $null }
    }
    latestDraft = if ($latestDraft) {
      [ordered]@{
        id = $latestDraft.id
        status = $latestDraft.status
        basisCommit = $latestDraft.basisCommit
        title = $latestDraft.title
        generatedAt = $latestDraft.generatedAt
      }
    } else {
      $null
    }
    draftCount = Get-ListCount -Items $drafts
  }
}

function Get-LocalRepoSourcePath {
  param([string]$UpstreamUrl)

  if ([string]::IsNullOrWhiteSpace($UpstreamUrl)) {
    return $null
  }

  if (Test-Path -LiteralPath $UpstreamUrl) {
    return (Resolve-Path -LiteralPath $UpstreamUrl).Path
  }

  if ($UpstreamUrl -match "^file://") {
    return ([System.Uri]$UpstreamUrl).LocalPath
  }

  return $null
}

function Sync-LocalMirror {
  param(
    [string]$SourcePath,
    [string]$MirrorDir
  )

  if (Test-Path -LiteralPath $MirrorDir) {
    Remove-Item -LiteralPath $MirrorDir -Recurse -Force
  }

  Copy-Item -LiteralPath $SourcePath -Destination $MirrorDir -Recurse -Force
}

Export-ModuleMember -Function Ensure-TrackedRepo, Sync-TrackedRepo, Get-RepoStatus, Start-RepobrdigeWatch, Get-WatchStatus, Start-RepobrdigeServer, Get-RepoSummary
