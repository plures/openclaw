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

function Test-SupportedNodeVersion {
    param([Parameter(Mandatory)][version]$Version)
    return (
        ($Version.Major -eq 22 -and $Version -ge [version]"22.22.3") -or
        ($Version.Major -eq 24 -and $Version -ge [version]"24.15.0") -or
        ($Version.Major -eq 25 -and $Version -ge [version]"25.9.0") -or
        $Version.Major -gt 25
    )
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

$doctorPatch = Join-Path $PSScriptRoot "openclaw-doctor-no-live-provider-discovery.patch"
$fsSafePatch = Join-Path $PSScriptRoot "fs-safe-0.5.2-reclaim-guards-compat.patch"
foreach ($requiredPatch in @($doctorPatch, $fsSafePatch)) {
    if (-not (Test-Path -LiteralPath $requiredPatch -PathType Leaf)) {
        throw "Patch file not found beside this script: $requiredPatch"
    }
}

$fsSafeRoot = Join-Path $repo "node_modules/@openclaw/fs-safe"
if (-not (Test-Path -LiteralPath (Join-Path $fsSafeRoot "dist/sidecar-lock.js") -PathType Leaf)) {
    throw "@openclaw/fs-safe 0.5.2 is not installed under this checkout. Run pnpm install first."
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

    & git apply --check --whitespace=error-all $doctorPatch
    $applyDoctorPatch = $LASTEXITCODE -eq 0
    if (-not $applyDoctorPatch) {
        & git apply --reverse --check $doctorPatch
        if ($LASTEXITCODE -ne 0) {
            throw "The doctor patch does not match this checkout and is not already applied."
        }
    }

    Push-Location $fsSafeRoot
    try {
        & git apply --check --whitespace=error-all $fsSafePatch
        $applyFsSafePatch = $LASTEXITCODE -eq 0
        if (-not $applyFsSafePatch) {
            & git apply --reverse --check $fsSafePatch
            if ($LASTEXITCODE -ne 0) {
                throw "The fs-safe patch does not match installed @openclaw/fs-safe 0.5.2."
            }
        }
    }
    finally {
        Pop-Location
    }

    if ($CheckOnly) {
        Write-Host "Doctor runtime fix preflight passed for $repo"
        return
    }

    $nodeText = (& node --version).Trim().TrimStart("v")
    $nodeVersion = [version]$nodeText
    if (-not (Test-SupportedNodeVersion -Version $nodeVersion)) {
        throw "Node $nodeVersion is unsupported. Install Node 24.15.0 or newer, then rerun this script."
    }

    if ($applyDoctorPatch) {
        Invoke-Native git apply --whitespace=error-all $doctorPatch
    }
    if ($applyFsSafePatch) {
        Push-Location $fsSafeRoot
        try {
            Invoke-Native git apply --whitespace=error-all $fsSafePatch
        }
        finally {
            Pop-Location
        }
    }

    Invoke-Native pnpm openclaw gateway stop
    $dist = [IO.Path]::GetFullPath((Join-Path $repo "dist"))
    if (-not $dist.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected dist path: $dist"
    }
    if (Test-Path -LiteralPath $dist) {
        Remove-Item -LiteralPath $dist -Recurse -Force
    }
    Invoke-Native pnpm build

    if (-not $SkipTests) {
        Invoke-Native pnpm exec vitest run src/commands/doctor/shared/active-tool-schema-warnings.test.ts
    }

    Write-Host "Doctor runtime fix applied and verified."
    Write-Host "The fs-safe node_modules hotfix must be reapplied after dependency reinstalls until upstream publishes the fix."
    Write-Host "Persistent OpenClaw state, sessions, transcripts, automations, and databases were not modified."
}
finally {
    Pop-Location
}
