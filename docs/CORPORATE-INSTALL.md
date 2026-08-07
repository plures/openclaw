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
