Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
Import-Module (Join-Path $repoRoot "Repobrdige.psm1") -Force

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw "Assertion failed: $Message"
  }
}

function New-TempDirectory {
  param([string]$Prefix)

  $path = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  $path
}

function Invoke-GitRaw {
  param(
    [string[]]$Arguments,
    [string]$WorkingDirectory
  )

  Push-Location
  $oldPreference = $ErrorActionPreference
  try {
    Set-Location -LiteralPath $WorkingDirectory
    $ErrorActionPreference = "Continue"
    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw ($output | Out-String).Trim()
    }
    return ($output | Out-String).Trim()
  } finally {
    $ErrorActionPreference = $oldPreference
    Pop-Location
  }
}

function New-FixtureRepo {
  $root = New-TempDirectory -Prefix "repobrdige-fixture-"
  $work = Join-Path $root "work"

  Invoke-GitRaw -Arguments @("init", $work) -WorkingDirectory $root | Out-Null
  Invoke-GitRaw -Arguments @("config", "user.email", "repobrdige@example.com") -WorkingDirectory $work | Out-Null
  Invoke-GitRaw -Arguments @("config", "user.name", "repobrdige") -WorkingDirectory $work | Out-Null

  Set-Content -LiteralPath (Join-Path $work "README.md") -Value "# llm.c`n`nA compact language model runtime.`n" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $work "main.c") -Value "int main(void) { return 0; }`n" -Encoding utf8

  Invoke-GitRaw -Arguments @("add", "README.md", "main.c") -WorkingDirectory $work | Out-Null
  Invoke-GitRaw -Arguments @("commit", "-m", "Initial import") -WorkingDirectory $work | Out-Null

  [pscustomobject]@{
    Root = $root
    Remote = $work
    Work = $work
  }
}

function Add-Commit {
  param(
    [string]$WorkPath,
    [string]$RelativeFile,
    [string]$AppendText,
    [string]$Message
  )

  Add-Content -LiteralPath (Join-Path $WorkPath $RelativeFile) -Value $AppendText -Encoding utf8
  Invoke-GitRaw -Arguments @("add", $RelativeFile) -WorkingDirectory $WorkPath | Out-Null
  Invoke-GitRaw -Arguments @("commit", "-m", $Message) -WorkingDirectory $WorkPath | Out-Null
}

function Run-Test {
  param(
    [string]$Name,
    [scriptblock]$Body
  )

  Write-Host "RUN $Name"
  & $Body
  Write-Host "PASS $Name"
}

Run-Test "initial sync creates mirror, context pack, and ready draft" {
  $fixture = New-FixtureRepo
  $appRoot = New-TempDirectory -Prefix "repobrdige-app-"

  Ensure-TrackedRepo -Root $appRoot -Id "llm-c" -UpstreamUrl $fixture.Remote -Focus "upstream changes relevant to downstream integrations" | Out-Null
  $result = Sync-TrackedRepo -Root $appRoot -RepoId "llm-c"

  Assert-True ($result.state.status -eq "synced") "state should be synced"
  Assert-True ($result.contextPack.deltaSummary.meaningful -eq $true) "initial sync should be meaningful"
  Assert-True ($result.draft.status -eq "ready") "draft should be ready"
  Assert-True (@($result.drafts).Count -eq 1) "there should be one draft"
}

Run-Test "second sync with no upstream change does not create a duplicate draft" {
  $fixture = New-FixtureRepo
  $appRoot = New-TempDirectory -Prefix "repobrdige-app-"

  Ensure-TrackedRepo -Root $appRoot -Id "llm-c" -UpstreamUrl $fixture.Remote | Out-Null
  Sync-TrackedRepo -Root $appRoot -RepoId "llm-c" | Out-Null
  $second = Sync-TrackedRepo -Root $appRoot -RepoId "llm-c"
  $status = Get-RepoStatus -Root $appRoot -RepoId "llm-c"

  Assert-True ($second.contextPack.deltaSummary.meaningful -eq $false) "no-op sync should not be meaningful"
  Assert-True ($null -eq $second.draft) "no-op sync should not create a draft"
  Assert-True (@($status.drafts).Count -eq 1) "draft count should remain one"
  Assert-True ($status.drafts[0].status -eq "ready") "existing draft should stay ready"
}

Run-Test "new upstream commit supersedes the prior ready draft and creates a fresh one" {
  $fixture = New-FixtureRepo
  $appRoot = New-TempDirectory -Prefix "repobrdige-app-"

  Ensure-TrackedRepo -Root $appRoot -Id "llm-c" -UpstreamUrl $fixture.Remote | Out-Null
  Sync-TrackedRepo -Root $appRoot -RepoId "llm-c" | Out-Null
  Add-Commit -WorkPath $fixture.Work -RelativeFile "main.c" -AppendText "`nputs(""v2"");`n" -Message "Update runtime behavior"

  $second = Sync-TrackedRepo -Root $appRoot -RepoId "llm-c"
  $status = Get-RepoStatus -Root $appRoot -RepoId "llm-c"

  Assert-True ($second.contextPack.deltaSummary.meaningful -eq $true) "new upstream commit should be meaningful"
  Assert-True (@($status.drafts).Count -eq 2) "there should be two draft records"
  Assert-True ($status.drafts[0].status -eq "ready") "newest draft should be ready"
  Assert-True ($status.drafts[1].status -eq "superseded") "older draft should be superseded"
}

Run-Test "watch mode syncs all tracked repos and writes watch state" {
  $fixture = New-FixtureRepo
  $appRoot = New-TempDirectory -Prefix "repobrdige-app-"

  Ensure-TrackedRepo -Root $appRoot -Id "llm-c" -UpstreamUrl $fixture.Remote | Out-Null
  $watch = Start-RepobrdigeWatch -Root $appRoot -IntervalSeconds 5 -Iterations 1
  $watchStatus = Get-WatchStatus -Root $appRoot

  Assert-True ($watch.iteration -eq 1) "watch should run one iteration"
  Assert-True (@($watch.results).Count -eq 1) "watch should process one tracked repo"
  Assert-True ($watch.results[0].status -eq "synced") "watch result should be synced"
  Assert-True ($watchStatus.runId -eq $watch.runId) "watch status should persist latest run"
}

Run-Test "track and sync responses use stable product-shaped fields" {
  $fixture = New-FixtureRepo
  $appRoot = New-TempDirectory -Prefix "repobrdige-app-"

  $track = Ensure-TrackedRepo -Root $appRoot -Id "llm-c" -UpstreamUrl $fixture.Remote -Focus "api drift"
  $sync = Sync-TrackedRepo -Root $appRoot -RepoId "llm-c"

  Assert-True ($track.repo.id -eq "llm-c") "track response should expose repo.id"
  Assert-True ($track.repo.tracked -eq $true) "track response should expose tracked"

  $summary = & {
    Import-Module (Join-Path $repoRoot "Repobrdige.psm1") -Force
    $status = Get-RepoStatus -Root $appRoot -RepoId "llm-c"
    $local:status
  }

  Assert-True ($sync.state.lastSyncedCommit.Length -gt 0) "sync should expose synced commit"
  Assert-True (@($summary.drafts).Count -eq 1) "status should expose drafts array"
}

Run-Test "server exposes health JSON and app HTML" {
  $fixture = New-FixtureRepo
  $appRoot = New-TempDirectory -Prefix "repobrdige-app-"
  Copy-Item -LiteralPath (Join-Path $repoRoot "ui") -Destination (Join-Path $appRoot "ui") -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "Repobrdige.psm1") -Destination (Join-Path $appRoot "Repobrdige.psm1") -Force

  Ensure-TrackedRepo -Root $appRoot -Id "llm-c" -UpstreamUrl $fixture.Remote | Out-Null
  Sync-TrackedRepo -Root $appRoot -RepoId "llm-c" | Out-Null

  $port = 8799
  $job = Start-Job -ScriptBlock {
    param($modulePath, $rootPath, $listenPort)
    Import-Module $modulePath -Force
    Start-RepobrdigeServer -Root $rootPath -Port $listenPort -MaxRequests 2
  } -ArgumentList (Join-Path $appRoot "Repobrdige.psm1"), $appRoot, $port

  Start-Sleep -Milliseconds 500
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health"
    $app = Invoke-WebRequest -Uri "http://127.0.0.1:$port/app" -UseBasicParsing

    Assert-True ($health.ok -eq $true) "health endpoint should report ok"
    Assert-True ($app.Content -match "Sync Selected Repo") "app endpoint should serve the UI shell"
  } finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue
  }
}

Run-Test "server can create a tracked repo through POST /repos" {
  $fixture = New-FixtureRepo
  $appRoot = New-TempDirectory -Prefix "repobrdige-app-"
  Copy-Item -LiteralPath (Join-Path $repoRoot "ui") -Destination (Join-Path $appRoot "ui") -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "Repobrdige.psm1") -Destination (Join-Path $appRoot "Repobrdige.psm1") -Force

  $port = 8800
  $job = Start-Job -ScriptBlock {
    param($modulePath, $rootPath, $listenPort)
    Import-Module $modulePath -Force
    Start-RepobrdigeServer -Root $rootPath -Port $listenPort -MaxRequests 2
  } -ArgumentList (Join-Path $appRoot "Repobrdige.psm1"), $appRoot, $port

  Start-Sleep -Milliseconds 500
  try {
    $body = @{ id = "fixture"; url = $fixture.Remote; focus = "smoke-test" } | ConvertTo-Json
    $created = Invoke-RestMethod -Uri "http://127.0.0.1:$port/repos" -Method POST -Body $body -ContentType "application/json"
    $listed = Invoke-RestMethod -Uri "http://127.0.0.1:$port/repos"

    Assert-True ($created.repo.id -eq "fixture") "POST /repos should create tracked repo"
    Assert-True ($listed.repos[0].id -eq "fixture") "GET /repos should include created repo"
  } finally {
    Wait-Job $job -Timeout 5 | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "All tests passed."
