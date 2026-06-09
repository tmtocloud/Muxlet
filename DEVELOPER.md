# Developer Guide — Muxlet

This guide covers local testing workflow, release promotion, and MPR submission.

---

## Quick Reference

| Task | Command |
|---|---|
| Build package | `muddle` |
| Deploy to Mudlet profile | `./devmode.ps1` |
| Immediate reload in Mudlet | type `mux reload` in-game |
| Test fresh-install path | type `mux reload fresh` in-game |
| Test update dialog UI | call `Mux.showUpdateDialog("0.0.0","9.9.9")` in Lua console |
| Check current version | type `mux version` in-game |

---

## Local Dev Setup (one-time per machine)

### 1. Run the deploy script

```powershell
muddle
./devmode.ps1
```

This builds the package via muddle, then:
- Creates a `mux-dev` Mudlet profile directory if it doesn't exist
- Copies `build/Muxlet.mpackage` into the profile directory
- Writes a rebuild stamp file that the in-package auto-reload timer watches

Pass `-Profile` to use a different profile name:

```powershell
./devmode.ps1 -Profile my-test
```

Pass `-MudletConfigPath` if auto-detection fails (run Mudlet at least once first):

```powershell
./devmode.ps1 -MudletConfigPath "C:\Users\you\AppData\Roaming\Mudlet"
```

### 2. First-time package install (once only)

1. Open Mudlet
2. Select the `mux-dev` profile (no game connection needed — Muxlet is game-agnostic)
3. **Toolbox → Package Manager → Install from file** and select the path printed by the script

After this initial install, you never use the GUI install flow again.

---

## Ongoing Dev Workflow

```powershell
# Edit code, then:
muddle && ./devmode.ps1
```

Within **~30 seconds**, a timer inside the running package detects the new stamp file
and automatically performs `uninstallPackage` + `installPackage` for a clean reload.

For an **immediate** reload without waiting for the timer:

```
mux reload
```

This also does uninstall + install, so UI state is fully torn down and rebuilt.

---

## Testing Modes

### Upgrade path (default)

```
mux reload
```

Simulates an existing user upgrading. Settings are preserved. Use this for most
testing — it mirrors what `mpkg.upgrade("Muxlet")` does.

### Fresh install path

```
mux reload fresh
```

Resets the `update_check_remind_skip` counter before reinstalling. Use this when
testing first-run or onboarding behaviour.

### Update dialog UI

The update dialog is testable without an actual version gap. In Mudlet's Lua console:

```lua
Mux._changelog = {{version="9.9.9", body="- New feature\n- Bug fix"}}
Mux.showUpdateDialog("0.0.0", "9.9.9")
```

Or trigger the full download-changelog-then-show flow:

```lua
Mux._triggerUpdateDialog("0.0.0", "9.9.9")
```

### Check current version

```
mux version
```

Displays the installed version and silently queries MPR for a newer release.

---

## Build Output

`muddle` reads the `mfile` in the project root and generates:

```
build/Muxlet.mpackage    — the installable package
build/Muxlet.xml         — intermediate XML (for inspection)
```

`devmode.ps1` copies `build/Muxlet.mpackage` into the Mudlet profile directory and
writes `Muxlet-rebuild.stamp` alongside it. The stamp file is what the in-package
auto-reload timer (`devmode.lua`) watches for changes.

---

## GitHub Actions: What Happens on Push

### Push to `main` (no tag)

A pre-release is automatically created or updated at the `prerelease` tag.
The version string is `<last-tag>-<short-sha>` (e.g. `1.0.0-a3f91cd`).
**This does NOT submit to MPR.**

Pre-release packages are available for download on the GitHub Releases page.

### Push a `v*` tag

Creates a full production release and opens a PR to the Mudlet Package Repository.
The annotated tag message becomes the release notes.

```bash
git tag -a v1.1.0 -m "- new feature\n- bug fix"
git push origin v1.1.0
```

### Workflow dispatch (promote to production)

Go to **GitHub → Actions → "Build Package" → Run workflow**, enter a version number
and optional release notes (markdown). Leave the version blank for a dev build.

This:
1. Builds the package with that version injected
2. Creates an annotated git tag `v<version>`
3. Publishes a production GitHub release with the mpackage attached
4. Opens a PR to the Mudlet Package Repository

### Required secret

`MUDLET_REPO_PAT` must be set in the repo settings — a GitHub Personal Access Token
with push access to `tmtocloud/mudlet-package-repository` and permission to open PRs
against `Mudlet/mudlet-package-repository`.

---

## Release Checklist

Before promoting to production:

- [ ] All intended changes are merged to `main`
- [ ] Pre-release has been tested in a clean Mudlet profile
- [ ] Upgrade path tested: `mux reload` from the previous production version
- [ ] `mfile` author/description still accurate
- [ ] `README.md` updated for any new user-facing commands or settings

Then go to GitHub → Actions → "Build Package" → Run workflow → enter version.
