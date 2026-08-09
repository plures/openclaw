[CmdletBinding()]
param(
    [string]$RepoPath = (Get-Location).Path,
    [switch]$CheckOnly,
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

function Invoke-Native {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$packageJson = Join-Path $repo "package.json"
if (-not (Test-Path -LiteralPath $packageJson)) {
    throw "RepoPath is not an OpenClaw checkout: $repo"
}

$package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
if ($package.name -ne "openclaw") {
    throw "RepoPath package name is '$($package.name)', expected 'openclaw'."
}

$patchPath = Join-Path $PSScriptRoot "openclaw-models-list-cache-worker.patch"
if (-not (Test-Path -LiteralPath $patchPath)) {
    throw "Patch file not found beside this script: $patchPath"
}

Push-Location $repo
try {
    $branch = (git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read the current Git branch."
    }
    if ($branch -ne "corporate-install") {
        throw "Expected branch 'corporate-install'; current branch is '$branch'."
    }

    Invoke-Native git apply --check --whitespace=error-all $patchPath
    if ($CheckOnly) {
        Write-Host "Patch preflight passed for $repo"
        return
    }
    Invoke-Native git apply --whitespace=error-all $patchPath

    Write-Host "Stopping the Gateway before replacing dist..."
    Invoke-Native pnpm openclaw gateway stop

    $dist = [IO.Path]::GetFullPath((Join-Path $repo "dist"))
    $expectedDist = [IO.Path]::GetFullPath((Join-Path $repo "dist"))
    if ($dist -ne $expectedDist -or -not $dist.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected dist path: $dist"
    }
    if (Test-Path -LiteralPath $dist) {
        Remove-Item -LiteralPath $dist -Recurse -Force
    }

    Invoke-Native pnpm build

    $workerOutput = Join-Path $dist "gateway/model-catalog.worker.js"
    if (-not (Test-Path -LiteralPath $workerOutput -PathType Leaf)) {
        throw "Build completed without the stable worker output: $workerOutput"
    }

    if (-not $SkipTests) {
        Invoke-Native pnpm exec vitest run src/gateway/model-catalog-cache.test.ts
    }

    Write-Host "Patch applied and verified. Worker output: $workerOutput"
    Write-Host "Persistent OpenClaw state, sessions, transcripts, and databases were not touched."
}
finally {
    Pop-Location
}
