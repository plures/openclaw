[CmdletBinding()]
param(
  [Parameter()]
  [string]$RepoRoot = "C:\Users\kbristol\openclaw",

  [Parameter()]
  [string]$PatchPath = (Join-Path $PSScriptRoot "openclaw-chat-history-single-flight.patch"),

  [Parameter()]
  [switch]$Apply,

  [Parameter()]
  [switch]$Rebuild
)

$ErrorActionPreference = "Stop"
$resolvedRepo = (Resolve-Path -LiteralPath $RepoRoot).Path
$resolvedPatch = (Resolve-Path -LiteralPath $PatchPath).Path
$packageJson = Join-Path $resolvedRepo "package.json"
$gitDir = Join-Path $resolvedRepo ".git"

if (-not (Test-Path -LiteralPath $packageJson)) {
  throw "Not an OpenClaw checkout: package.json is missing from $resolvedRepo"
}
if (-not (Test-Path -LiteralPath $gitDir)) {
  throw "Not a Git checkout: .git is missing from $resolvedRepo"
}
$package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
if ($package.name -ne "openclaw") {
  throw "Unexpected package '$($package.name)' in $resolvedRepo"
}

Push-Location $resolvedRepo
try {
  & git apply --check -- $resolvedPatch
  if ($LASTEXITCODE -ne 0) {
    throw "Patch preflight failed. No files were changed."
  }

  if (-not $Apply) {
    Write-Host "Preflight passed. No files were changed."
    Write-Host "Run again with -Apply to install the patch."
    return
  }

  & git apply -- $resolvedPatch
  if ($LASTEXITCODE -ne 0) {
    throw "git apply failed."
  }
  Write-Host "Applied chat.history single-flight patch."

  if (-not $Rebuild) {
    Write-Host "Patch applied. Run again with both -Apply and -Rebuild only from an unpatched checkout,"
    Write-Host "or perform the rebuild commands printed in the accompanying handoff."
    return
  }

  & openclaw gateway stop
  $distPath = Join-Path $resolvedRepo "dist"
  $expectedDistPath = [IO.Path]::GetFullPath((Join-Path $resolvedRepo "dist"))
  if ([IO.Path]::GetFullPath($distPath) -ne $expectedDistPath) {
    throw "Refusing to clean unexpected dist path: $distPath"
  }
  if (Test-Path -LiteralPath $distPath) {
    Remove-Item -LiteralPath $distPath -Recurse -Force
  }
  & pnpm build
  if ($LASTEXITCODE -ne 0) {
    throw "OpenClaw build failed; Gateway remains stopped."
  }
  $workerOutputs = @(
    (Join-Path $distPath "gateway\model-catalog.worker.js"),
    (Join-Path $distPath "gateway\session-transcript-read.worker.js")
  )
  $missingWorkerOutputs = @($workerOutputs | Where-Object { -not (Test-Path -LiteralPath $_) })
  if ($missingWorkerOutputs.Count -gt 0) {
    throw "Build completed without expected worker output(s): $($missingWorkerOutputs -join ', ')"
  }
  Write-Host "Verified model catalog and transcript worker outputs."
  & openclaw gateway start
  & openclaw gateway status --deep
} finally {
  Pop-Location
}
