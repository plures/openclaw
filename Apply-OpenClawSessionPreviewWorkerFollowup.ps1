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
if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) {
    throw "RepoPath is not an OpenClaw checkout: $repo"
}
$package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
if ($package.name -ne "openclaw") {
    throw "RepoPath package name is '$($package.name)', expected 'openclaw'."
}

$patchPath = Join-Path $PSScriptRoot "openclaw-session-preview-worker-followup.patch"
if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
    throw "Patch file not found beside this script: $patchPath"
}

Push-Location $repo
try {
    $branchOutput = git branch --show-current
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read the current Git branch."
    }
    $branch = ($branchOutput | Out-String).Trim()
    if ($branch -ne "corporate-install") {
        throw "Expected branch 'corporate-install'; current branch is '$branch'."
    }

    & git apply --check --whitespace=error-all $patchPath
    $canApply = $LASTEXITCODE -eq 0
    if (-not $canApply) {
        & git apply --reverse --check $patchPath
        if ($LASTEXITCODE -ne 0) {
            throw "The follow-up patch does not match this checkout and is not already applied."
        }
        Write-Host "The session preview worker follow-up is already applied."
    }

    if ($CheckOnly) {
        Write-Host "Session preview worker follow-up preflight passed for $repo"
        return
    }
    if ($canApply) {
        Invoke-Native git apply --whitespace=error-all $patchPath
    }

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

    $workerOutput = Join-Path $dist "gateway/session-transcript-read.worker.js"
    if (-not (Test-Path -LiteralPath $workerOutput -PathType Leaf)) {
        throw "Build completed without the stable transcript worker output: $workerOutput"
    }

    if (-not $SkipTests) {
        Invoke-Native pnpm exec vitest run src/gateway/server-methods/sessions-read.test.ts -t sessions.preview
    }

    Write-Host "Session preview worker follow-up applied and verified."
    Write-Host "Persistent OpenClaw state, sessions, transcripts, and databases were not modified."
}
finally {
    Pop-Location
}
