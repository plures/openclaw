[CmdletBinding()]
param(
    [string]$Repo = "$HOME\openclaw",
    [string]$ForkUrl = "https://github.com/plures/openclaw.git",
    [string]$UpstreamUrl = "https://github.com/openclaw/openclaw.git",
    [string]$Branch = "corporate-install",
    [switch]$Push,
    [switch]$RunInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @()
    )

    Write-Host "`n> $FilePath $($ArgumentList -join ' ')" -ForegroundColor Cyan
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Test-GitRef {
    param([Parameter(Mandatory)][string]$Ref)

    & git rev-parse --verify --quiet $Ref *> $null
    return ($LASTEXITCODE -eq 0)
}

function Ensure-Remote {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url
    )

    $existing = (& git remote) -contains $Name
    if ($existing) {
        Invoke-Checked git @("remote", "set-url", $Name, $Url)
    } else {
        Invoke-Checked git @("remote", "add", $Name, $Url)
    }
}

foreach ($cmd in @("git", "node", "pnpm")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command not found on PATH: $cmd"
    }
}

if (-not (Test-Path $Repo)) {
    throw "OpenClaw checkout not found: $Repo"
}

$Repo = (Resolve-Path $Repo).Path
Push-Location $Repo

try {
    Invoke-Checked git @("rev-parse", "--is-inside-work-tree")

    # The earlier corporate-feed workaround may have dirtied these files.
    # Preserve a patch, then restore them before creating the maintained branch.
    $managedFiles = @(
        "package.json",
        "pnpm-workspace.yaml",
        "pnpm-lock.yaml"
    )

    $changed = @(& git diff --name-only HEAD)
    if ($LASTEXITCODE -ne 0) { throw "git diff failed" }

    $unexpected = @($changed | Where-Object { $_ -and ($_ -notin $managedFiles) })
    if ($unexpected.Count -gt 0) {
        throw "Unrelated tracked changes detected. Commit/stash these first:`n  $($unexpected -join "`n  ")"
    }

    $backupRoot = Join-Path $HOME ".openclaw-update-backups"
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

    $diff = & git diff -- $managedFiles
    if ($LASTEXITCODE -ne 0) { throw "Could not back up local workaround diff" }

    if ($diff) {
        $backup = Join-Path $backupRoot ("pre-corporate-branch-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".patch")
        $diff | Set-Content -Encoding utf8 $backup
        Write-Host "Saved existing workaround diff: $backup" -ForegroundColor DarkGray
        Invoke-Checked git (@("restore", "--") + $managedFiles)
    }

    # Make the fork the normal push target and upstream OpenClaw the sync source.
    Ensure-Remote -Name "origin" -Url $ForkUrl
    Ensure-Remote -Name "upstream" -Url $UpstreamUrl

    Invoke-Checked git @("fetch", "upstream", "--prune")
    Invoke-Checked git @("fetch", "origin", "--prune")

    $localBranch = Test-GitRef "refs/heads/$Branch"
    $remoteBranch = Test-GitRef "refs/remotes/origin/$Branch"

    if ($localBranch) {
        Invoke-Checked git @("switch", $Branch)
        Invoke-Checked git @("merge", "--no-edit", "upstream/main")
    }
    elseif ($remoteBranch) {
        Invoke-Checked git @("switch", "--track", "-c", $Branch, "origin/$Branch")
        Invoke-Checked git @("merge", "--no-edit", "upstream/main")
    }
    else {
        # Deliberately branch from current upstream, NOT plures/openclaw:main.
        Invoke-Checked git @("switch", "-c", $Branch, "upstream/main")
    }

    $scriptsDir = Join-Path $Repo "scripts"
    $docsDir = Join-Path $Repo "docs"
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    New-Item -ItemType Directory -Force -Path $docsDir | Out-Null

    $updater = @'
[CmdletBinding()]
param(
    [switch]$SkipUpstreamMerge,
    [switch]$ReinstallGateway,
    [switch]$PushFork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repo = Split-Path $PSScriptRoot -Parent
$Vendor = Join-Path $Repo ".vendor"
$WorkspaceFile = Join-Path $Repo "pnpm-workspace.yaml"
$LockFile = Join-Path $Repo "pnpm-lock.yaml"

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [string]$WorkingDirectory
    )

    if ($WorkingDirectory) { Push-Location $WorkingDirectory }
    try {
        Write-Host "`n> $FilePath $($ArgumentList -join ' ')" -ForegroundColor Cyan
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
}

function Ensure-Remote {
    param([string]$Name, [string]$Url)

    if ((& git remote) -contains $Name) {
        Invoke-Checked git @("remote", "set-url", $Name, $Url)
    } else {
        Invoke-Checked git @("remote", "add", $Name, $Url)
    }
}

function Get-JsonVersion {
    param([string]$Directory)

    $path = Join-Path $Directory "package.json"
    if (-not (Test-Path $path)) { throw "package.json not found: $path" }
    return (Get-Content $path -Raw | ConvertFrom-Json).version
}

function Find-FsSafeVersion {
    # Prefer an actual package.json declaration if one exists.
    $lines = @(& git grep -h '"@openclaw/fs-safe"' -- '*package.json' 2>$null)
    foreach ($line in $lines) {
        if ($line -match '"@openclaw/fs-safe"\s*:\s*"[^0-9]*([0-9]+\.[0-9]+\.[0-9]+(?:[-+][^"]+)?)"') {
            return $Matches[1]
        }
    }

    # Current OpenClaw also records the exact version in pnpm policy.
    $workspace = Get-Content $WorkspaceFile -Raw
    if ($workspace -match '"@openclaw/fs-safe@([0-9]+\.[0-9]+\.[0-9]+(?:[-+][^"]+)?)"') {
        return $Matches[1]
    }

    throw "Could not determine required @openclaw/fs-safe version."
}

function Checkout-FsSafe {
    param([string]$Version, [string]$Destination)

    if (-not (Test-Path (Join-Path $Destination ".git"))) {
        if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
        Invoke-Checked git @("clone", "--filter=blob:none", "https://github.com/openclaw/fs-safe.git", $Destination)
    }

    Invoke-Checked git @("fetch", "--tags", "--prune", "origin") $Destination

    $candidates = @("v$Version", $Version, "fs-safe-v$Version")
    $checkedOut = $false

    foreach ($candidate in $candidates) {
        & git -C $Destination rev-parse --verify --quiet "$candidate^{commit}" *> $null
        if ($LASTEXITCODE -eq 0) {
            Invoke-Checked git @("checkout", "--force", $candidate) $Destination
            $checkedOut = $true
            break
        }
    }

    if (-not $checkedOut) {
        # Some fs-safe versions are present on the default branch before/without
        # a convenient release tag. Use origin/main only if its package version
        # exactly matches what OpenClaw requires.
        Invoke-Checked git @("checkout", "--force", "origin/main") $Destination
    }

    Invoke-Checked git @("clean", "-fdx") $Destination

    $actual = Get-JsonVersion $Destination
    if ($actual -ne $Version) {
        throw "fs-safe checkout is $actual but OpenClaw requires $Version. A matching Git ref was not found."
    }

    Invoke-Checked pnpm @("install", "--force") $Destination
    Invoke-Checked pnpm @("build") $Destination
}

function Checkout-Codex {
    param([string]$Version, [string]$Destination)

    $expectedTag = "rust-v$Version"
    $needClone = $true

    if (Test-Path (Join-Path $Destination ".git")) {
        $tag = (& git -C $Destination describe --tags --exact-match 2>$null)
        if ($LASTEXITCODE -eq 0 -and $tag -eq $expectedTag) {
            $needClone = $false
        }
    }

    if ($needClone) {
        if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
        Invoke-Checked git @(
            "clone", "--depth", "1",
            "--branch", $expectedTag,
            "https://github.com/openai/codex.git",
            $Destination
        )
    }

    $cli = Join-Path $Destination "codex-cli"
    $pkgPath = Join-Path $cli "package.json"
    if (-not (Test-Path $pkgPath)) {
        throw "Codex npm package directory not found: $cli"
    }

    # Release source can carry a generated/dev package version. Force the local
    # package identity to the exact version OpenClaw requests.
    $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
    $pkg.version = $Version
    $pkg | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8 $pkgPath

    $binDir = Join-Path $cli "vendor\x86_64-pc-windows-msvc\bin"
    $bin = Join-Path $binDir "codex.exe"

    if (-not (Test-Path $bin)) {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null

        $headers = @{
            "User-Agent" = "OpenClaw-Corporate-Installer"
            "Accept" = "application/vnd.github+json"
        }

        $releaseUrl = "https://api.github.com/repos/openai/codex/releases/tags/$expectedTag"
        Write-Host "`nResolving Codex Windows release asset..." -ForegroundColor Cyan
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers

        $asset = @($release.assets) |
            Where-Object {
                $_.name -match '^codex-x86_64-pc-windows-msvc.*\.zip$'
            } |
            Select-Object -First 1

        if (-not $asset) {
            throw "No Windows x64 Codex ZIP asset found for $expectedTag."
        }

        $tempRoot = Join-Path $env:TEMP "openclaw-corporate-codex-$Version"
        $zip = "$tempRoot.zip"
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -Force -ErrorAction SilentlyContinue

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $headers
        Expand-Archive -Path $zip -DestinationPath $tempRoot -Force

        $exe = Get-ChildItem $tempRoot -Recurse -File -Filter "*.exe" |
            Where-Object { $_.Name -match '^codex.*\.exe$' } |
            Select-Object -First 1

        if (-not $exe) {
            throw "Downloaded Codex release did not contain codex.exe."
        }

        Copy-Item $exe.FullName $bin -Force
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }

    & $bin --version
    if ($LASTEXITCODE -ne 0) {
        throw "Local Codex binary failed to run: $bin"
    }
}

function Set-YamlOverride {
    param(
        [string]$Text,
        [string]$Key,
        [string]$Value
    )

    $escapedKey = [regex]::Escape($Key)
    $pattern = "(?m)^(\s*)`"$escapedKey`":\s*.+$"
    $match = [regex]::Match($Text, $pattern)

    if ($match.Success) {
        $indent = $match.Groups[1].Value
        $replacement = "${indent}`"$Key`": `"$Value`""
        return $Text.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
    }

    $overrides = [regex]::Match($Text, "(?m)^overrides:\s*$")
    if (-not $overrides.Success) {
        # Add a new root section if upstream does not currently have one.
        return $Text.TrimEnd() + "`n`noverrides:`n  `"$Key`": `"$Value`"`n"
    }

    return $Text.Insert(
        $overrides.Index + $overrides.Length,
        "`n  `"$Key`": `"$Value`""
    )
}

foreach ($cmd in @("git", "node", "pnpm")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command not found on PATH: $cmd"
    }
}

Push-Location $Repo
try {
    Ensure-Remote "origin" "https://github.com/plures/openclaw.git"
    Ensure-Remote "upstream" "https://github.com/openclaw/openclaw.git"

    $branch = (& git branch --show-current).Trim()
    if ($branch -ne "corporate-install") {
        throw "Run this from the corporate-install branch; current branch is '$branch'."
    }

    # Only these generated dependency files may be dirty between runs.
    $managedFiles = @("pnpm-workspace.yaml", "pnpm-lock.yaml")
    $changed = @(& git diff --name-only HEAD)
    $unexpected = @($changed | Where-Object { $_ -and ($_ -notin $managedFiles) })
    if ($unexpected.Count -gt 0) {
        throw "Unrelated tracked changes detected. Commit/stash first:`n  $($unexpected -join "`n  ")"
    }

    $backupRoot = Join-Path $HOME ".openclaw-update-backups"
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $diff = & git diff -- $managedFiles
    if ($diff) {
        $backup = Join-Path $backupRoot ("corporate-generated-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".patch")
        $diff | Set-Content -Encoding utf8 $backup
        Write-Host "Saved generated dependency diff: $backup" -ForegroundColor DarkGray
    }

    # Restore pristine corporate branch copies before merging upstream.
    Invoke-Checked git (@("restore", "--") + $managedFiles)

    if (-not $SkipUpstreamMerge) {
        Invoke-Checked git @("fetch", "upstream", "--prune")
        Invoke-Checked git @("merge", "--no-edit", "upstream/main")
    }

    $codexPkg = Get-Content (Join-Path $Repo "extensions\codex\package.json") -Raw |
        ConvertFrom-Json
    $requiredCodex = $codexPkg.dependencies.'@openai/codex'
    if (-not $requiredCodex) {
        throw "Could not determine required @openai/codex version."
    }

    $requiredFsSafe = Find-FsSafeVersion

    Write-Host "`nRequired local packages:" -ForegroundColor Green
    Write-Host "  @openai/codex      $requiredCodex"
    Write-Host "  @openclaw/fs-safe  $requiredFsSafe"

    New-Item -ItemType Directory -Force -Path $Vendor | Out-Null

    $fsSafeDir = Join-Path $Vendor "fs-safe"
    $codexDir = Join-Path $Vendor "codex"

    Checkout-FsSafe -Version $requiredFsSafe -Destination $fsSafeDir
    Checkout-Codex -Version $requiredCodex -Destination $codexDir

    $fsRel = [IO.Path]::GetRelativePath($Repo, $fsSafeDir).Replace('\', '/')
    $codexCli = Join-Path $codexDir "codex-cli"
    $codexRel = [IO.Path]::GetRelativePath($Repo, $codexCli).Replace('\', '/')

    $workspace = Get-Content $WorkspaceFile -Raw
    $workspace = Set-YamlOverride $workspace "@openclaw/fs-safe" "file:$fsRel"
    $workspace = Set-YamlOverride $workspace "@openai/codex" "file:$codexRel"

    # A specific codex-acp override currently exists upstream and has higher
    # specificity than the generic @openai/codex override.
    $specificPattern = '(?m)^(\s*)("@agentclientprotocol/codex-acp@[^"]+>@openai/codex"):\s*.+$'
    $specific = [regex]::Match($workspace, $specificPattern)
    if ($specific.Success) {
        $indent = $specific.Groups[1].Value
        $key = $specific.Groups[2].Value
        $replacement = "${indent}${key}: `"file:$codexRel`""
        $workspace = $workspace.Remove($specific.Index, $specific.Length).
            Insert($specific.Index, $replacement)
    }

    [IO.File]::WriteAllText(
        $WorkspaceFile,
        $workspace,
        [Text.UTF8Encoding]::new($false)
    )

    Invoke-Checked pnpm @("install", "--force")
    Invoke-Checked pnpm @("build")
    Invoke-Checked pnpm @("ui:build")
    Invoke-Checked pnpm @("link", "--global")

    Write-Host "`nGit checkout version:" -ForegroundColor Green
    Invoke-Checked node @("openclaw.mjs", "--version")

    if ($ReinstallGateway) {
        Invoke-Checked node @("openclaw.mjs", "gateway", "install", "--force")
    } else {
        Invoke-Checked node @("openclaw.mjs", "gateway", "restart")
    }

    Invoke-Checked node @("openclaw.mjs", "gateway", "status")

    if ($PushFork) {
        Invoke-Checked git @("push", "origin", "corporate-install")
    }

    Write-Host "`nCorporate OpenClaw update complete." -ForegroundColor Green
    Write-Host "Generated local dependency changes intentionally remain uncommitted:"
    Invoke-Checked git @("status", "--short")
}
finally {
    Pop-Location
}
'@

    $updaterPath = Join-Path $scriptsDir "Update-OpenClawCorporate.ps1"
    [IO.File]::WriteAllText(
        $updaterPath,
        $updater,
        [Text.UTF8Encoding]::new($false)
    )

    $gitignore = Join-Path $Repo ".gitignore"
    $ignoreText = if (Test-Path $gitignore) { Get-Content $gitignore -Raw } else { "" }
    if ($ignoreText -notmatch '(?m)^\.vendor/$') {
        $ignoreText = $ignoreText.TrimEnd() + @"

# Corporate OpenClaw installer: GitHub-sourced local npm substitutions
.vendor/
"@
        [IO.File]::WriteAllText(
            $gitignore,
            $ignoreText + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }

    $doc = @'
# Corporate-network OpenClaw installation

This branch tracks upstream `openclaw/openclaw:main` while keeping the
workstation installation independent of npm packages that are unavailable
through the Microsoft corporate npm proxy.

## Fresh install

```powershell
git clone -b corporate-install https://github.com/plures/openclaw.git
cd openclaw
.\scripts\Update-OpenClawCorporate.ps1 -ReinstallGateway
```

## Update

```powershell
cd $HOME\openclaw
.\scripts\Update-OpenClawCorporate.ps1
```

The updater:

1. restores generated `pnpm-workspace.yaml` / lockfile changes;
2. merges current `upstream/main`;
3. detects the exact OpenClaw-required versions of `@openclaw/fs-safe`
   and `@openai/codex`;
4. retrieves those packages from their GitHub source/release repos into
   the ignored `.vendor/` directory;
5. applies local pnpm overrides, including the more-specific
   `codex-acp -> @openai/codex` override when present;
6. installs, builds, globally links, and restarts the Gateway.

`~/.openclaw` is not modified by the source synchronization step.
'@

    $docPath = Join-Path $docsDir "CORPORATE-INSTALL.md"
    [IO.File]::WriteAllText(
        $docPath,
        $doc,
        [Text.UTF8Encoding]::new($false)
    )

    Invoke-Checked git @(
        "add",
        ".gitignore",
        "scripts/Update-OpenClawCorporate.ps1",
        "docs/CORPORATE-INSTALL.md"
    )

    $staged = & git diff --cached --name-only
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect staged changes" }

    if ($staged) {
        Invoke-Checked git @(
            "commit",
            "-m",
            "chore: add corporate-network OpenClaw installer"
        )
    } else {
        Write-Host "`nCorporate installer files already match the branch." -ForegroundColor DarkGray
    }

    if ($Push) {
        Invoke-Checked git @("push", "-u", "origin", $Branch)
    }

    Write-Host "`nCorporate fork setup complete." -ForegroundColor Green
    Write-Host "Branch: $Branch"
    Write-Host "origin:   $ForkUrl"
    Write-Host "upstream: $UpstreamUrl"

    if (-not $Push) {
        Write-Host "`nPush when ready:"
        Write-Host "  git push -u origin $Branch"
    }

    if ($RunInstall) {
        & (Join-Path $scriptsDir "Update-OpenClawCorporate.ps1") -ReinstallGateway
        if ($LASTEXITCODE -ne 0) {
            throw "Corporate install script failed."
        }
    } else {
        Write-Host "`nInstall/build from the new branch:"
        Write-Host "  .\scripts\Update-OpenClawCorporate.ps1 -ReinstallGateway"
    }
}
finally {
    Pop-Location
}
