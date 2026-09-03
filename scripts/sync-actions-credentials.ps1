[CmdletBinding()]
param(
  [string]$Repository = $(if ($env:CHATGPT_AUTO_CONFIRM_REPOSITORY) { $env:CHATGPT_AUTO_CONFIRM_REPOSITORY } else { 'bhrumom/fabushi' }),
  [int]$WaitSeconds = 600,
  [switch]$DesktopLogin,
  [switch]$Start
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('fabushi-chatgpt-sync-' + [Guid]::NewGuid().ToString('N'))
$stage = 'preflight'
$result = $null
$exitCode = 0
$failureDetail = $null
$failureLine = $null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Set-GitHubSecretFromFile([string]$name, [string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $encoded = [Convert]::ToBase64String($bytes)
  if ($encoded.Length -ge 47000) { throw "secret $name exceeds the GitHub secret size budget" }
  $encoded | & $script:GitHubCli.Source secret set $name --repo $Repository | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "GitHub CLI failed to update $name" }
}

function Set-GitHubSecretFromValue([string]$name, [string]$value) {
  if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -ge 47000) {
    throw "secret $name is empty or exceeds the GitHub secret size budget"
  }
  $value | & $script:GitHubCli.Source secret set $name --repo $Repository | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "GitHub CLI failed to update $name" }
}

function New-RandomBytes([int]$length) {
  $bytes = New-Object byte[] $length
  $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
  return $bytes
}

function Start-ChatGptDesktopApp {
  $appId = if ($env:CHATGPT_DESKTOP_APP_ID) {
    [string]$env:CHATGPT_DESKTOP_APP_ID
  } else {
    'OpenAI.Codex_2p2nqsd0c76g0!App'
  }
  Start-Process -FilePath ('shell:AppsFolder\' + $appId) | Out-Null
}

function Get-NodeCommand {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $command) { $command = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $command) { throw 'Node.js was not found; it is required for live ChatGPT renderer export' }
  return $command
}

function Get-LiveRendererCookieSummary([string]$authPath, [string]$cookiePath) {
  if (Test-Path -LiteralPath $cookiePath) {
    [IO.File]::Delete($cookiePath)
  }
  $arguments = @(
    $script:HelperPath,
    '--output', $cookiePath,
    '--auth', $authPath,
    '--port', $(if ($env:CHATGPT_CDP_PORT) { [string]$env:CHATGPT_CDP_PORT } else { '9324' })
  )
  $extractOutput = @(& $script:Node.Source @arguments 2>&1)
  $extractExitCode = $LASTEXITCODE
  $summaryLine = ($extractOutput | ForEach-Object { [string]$_ } |
    Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
  if ($extractExitCode -ne 0 -or -not $summaryLine -or
      -not (Test-Path -LiteralPath $cookiePath -PathType Leaf)) {
    return $null
  }
  try { $summary = $summaryLine | ConvertFrom-Json } catch { return $null }
  if (-not $summary.ok -or -not $summary.accountVerified -or [int]$summary.cookieCount -le 0) {
    return $null
  }
  return $summary
}

try {
  New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null

  $script:GitHubCli = Get-Command gh.exe -ErrorAction SilentlyContinue
  if (-not $script:GitHubCli) { $script:GitHubCli = Get-Command gh -ErrorAction SilentlyContinue }
  if (-not $script:GitHubCli) { throw 'GitHub CLI (gh) was not found; install it and run gh auth login first' }
  & $script:GitHubCli.Source auth status *> $null
  if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated; run gh auth login first' }

  $desktopLoginRequested = $DesktopLogin

  $authPath = if ($env:CHATGPT_CODEX_AUTH_PATH) {
    [string]$env:CHATGPT_CODEX_AUTH_PATH
  } else {
    Join-Path $env:USERPROFILE '.codex\auth.json'
  }
  if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
    $stage = 'auth'
    throw 'the local Codex auth.json was not found; sign in to the ChatGPT desktop app first'
  }
  if ((Get-Item -LiteralPath $authPath).Length -eq 0) {
    $stage = 'auth'
    throw 'the local Codex auth.json is empty'
  }

  $stage = 'live_renderer_export'
  $script:HelperPath = Join-Path $scriptDirectory 'export-live-chatgpt-session.mjs'
  if (-not (Test-Path -LiteralPath $script:HelperPath -PathType Leaf)) {
    throw 'the live ChatGPT renderer exporter is missing'
  }
  $script:Node = Get-NodeCommand
  $cookiePath = Join-Path $temporaryDirectory 'session-cookies.json'
  $summary = $null

  if ($desktopLoginRequested) {
    Start-ChatGptDesktopApp
  }

  $deadline = (Get-Date).AddSeconds([Math]::Min(1800, [Math]::Max(30, $WaitSeconds)))
  do {
    $summary = Get-LiveRendererCookieSummary $authPath $cookiePath
    if ($summary) { break }
    if (-not $desktopLoginRequested -or (Get-Date) -ge $deadline) {
      throw 'the live ChatGPT desktop app renderer is unavailable; expose the desktop app CDP port, sign in, and retry'
    }
    Start-Sleep -Seconds 3
  } while ($true)

  $stage = 'upload'
  Set-GitHubSecretFromFile 'CHATGPT_CODEX_AUTH_B64' $authPath
  Set-GitHubSecretFromFile 'CHATGPT_SESSION_COOKIES_B64' $cookiePath
  $uploadedSecrets = @('CHATGPT_CODEX_AUTH_B64', 'CHATGPT_SESSION_COOKIES_B64')

  if ($Start) {
    $stage = 'state_key'
    $secretNames = @(& $script:GitHubCli.Source secret list --repo $Repository --json name --jq '.[].name')
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI could not list repository secrets' }
    if ($secretNames -notcontains 'CHATGPT_AUTO_CONFIRM_STATE_KEY') {
      $keyBytes = New-RandomBytes 48
      Set-GitHubSecretFromValue 'CHATGPT_AUTO_CONFIRM_STATE_KEY' ([Convert]::ToBase64String($keyBytes))
      $uploadedSecrets += 'CHATGPT_AUTO_CONFIRM_STATE_KEY'
    }

    $stage = 'dispatch'
    & $script:GitHubCli.Source workflow run chatgpt-auto-confirm-runner.yml --repo $Repository --ref main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI could not dispatch the Action runner' }
  }

  $result = [ordered]@{
    ok = $true
    credentialsSynchronized = $true
    cookieCount = [int]$summary.cookieCount
    credentialSource = 'live-desktop-renderer'
    accountVerified = [bool]$summary.accountVerified
    repository = $Repository
    secretsUploaded = $uploadedSecrets
    started = [bool]$Start
  }
} catch {
  $exitCode = 1
  $failureDetail = if ($_.Exception -and $_.Exception.Message) { [string]$_.Exception.Message } else { 'unknown failure' }
  $failureLine = [int]$_.InvocationInfo.ScriptLineNumber
  $messages = @{
    preflight = 'Windows desktop credential sync preflight failed'
    auth = 'the local Codex credential file is unavailable'
    live_renderer_export = 'no verified same-account live ChatGPT renderer was found'
    upload = 'GitHub Secrets upload failed'
    state = 'the local Action queue state is unavailable'
    state_key = 'the GitHub Action state key could not be prepared'
    dispatch = 'the GitHub Action runner could not be started'
  }
  $result = [ordered]@{
    ok = $false
    errorCode = "windows_credential_sync_$stage"
    message = if ($messages[$stage]) { $messages[$stage] } else { 'Windows desktop credential sync failed' }
    detail = $failureDetail
    line = $failureLine
  }
} finally {
  if (Test-Path -LiteralPath $temporaryDirectory) {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
  }
}

[Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 5))
exit $exitCode
