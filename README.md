# swui-nvim
A swift UI for neovim

## Release workflow

The project ships with shell-first release automation so you do not need Xcode for the common macOS distribution path.

### Stage a release app bundle

```bash
bash scripts/stage_swuineovimmac_app.sh release
```

By default the staged app uses:

- `CFBundleShortVersionString = 0.1.0`
- `CFBundleVersion = $(git rev-list --count HEAD)` from the current checked out branch history

Optional overrides:

```bash
export SWUINVIM_SHORT_VERSION="0.1.0"
export SWUINVIM_BUILD_VERSION="123"
bash scripts/stage_swuineovimmac_app.sh release
```

This creates:

- `.build/arm64-apple-macosx/release/SWUINeovimMac.app`
- `.build/arm64-apple-macosx/release/SWUINeovimMac.dSYM`

The staged release bundle includes the generated `AppIcon.icns`, and the copied app executable is stripped for distribution size.

### Sign a release app bundle

If you have multiple Apple teams or certificates installed, you can pin the team explicitly:

```bash
export SWUINVIM_DEVELOPMENT_TEAM="YOURTEAMID"
```

Provide a Developer ID Application certificate identity in the environment:

```bash
export SWUINVIM_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
bash scripts/sign_swuineovimmac_app.sh release
```

If `SWUINVIM_CODESIGN_IDENTITY` is not set, the script auto-selects the first matching certificate in this order:

- `Developer ID Application`
- `Apple Development`

If `Apple Development` is selected, the bundle can be signed for local testing, but notarization and external distribution still require `Developer ID Application`.

Optional:

```bash
export SWUINVIM_CODESIGN_ENTITLEMENTS=/absolute/path/to/entitlements.plist
```

If you do not override it, signing uses the baseline entitlements file at `scripts/SWUINeovimMac.entitlements`.

### Store a notarytool keychain profile

```bash
export SWUINVIM_NOTARY_APPLE_ID="name@example.com"
export SWUINVIM_NOTARY_TEAM_ID="TEAMID"
export SWUINVIM_NOTARY_PASSWORD="app-specific-password"
bash scripts/create_notarytool_profile.sh your-notarytool-profile
```

If `SWUINVIM_NOTARY_TEAM_ID` is omitted, the scripts fall back to `SWUINVIM_DEVELOPMENT_TEAM` when set.

### Notarize a release app bundle

Preferred setup uses a `notarytool` keychain profile:

```bash
export SWUINVIM_NOTARY_PROFILE="your-notarytool-profile"
bash scripts/notarize_swuineovimmac_app.sh release
```

Credential fallback is also supported:

```bash
export SWUINVIM_NOTARY_APPLE_ID="name@example.com"
export SWUINVIM_NOTARY_TEAM_ID="TEAMID"
export SWUINVIM_NOTARY_PASSWORD="app-specific-password"
bash scripts/notarize_swuineovimmac_app.sh release
```

After notarization, the script staples the ticket to the app and emits a distributable zip at `.build/arm64-apple-macosx/release/SWUINeovimMac-release.zip`.

### Package release artifacts into dist

Signed package output:

```bash
export SWUINVIM_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
bash scripts/package_swuineovimmac_release.sh signed
```

Notarized package output:

```bash
export SWUINVIM_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export SWUINVIM_NOTARY_PROFILE="your-notarytool-profile"
bash scripts/package_swuineovimmac_release.sh notarized
```

This produces artifacts outside `.build`:

- `dist/release/signed/SWUINeovimMac.app`
- `dist/release/signed/SWUINeovimMac.dSYM`
- `dist/release/signed/SWUINeovimMac-signed.zip`
- `dist/release/notarized/SWUINeovimMac.app`
- `dist/release/notarized/SWUINeovimMac.dSYM`
- `dist/release/notarized/SWUINeovimMac-notarized.zip`

### VS Code tasks

The workspace also exposes these tasks:

- `Swift: Stage Release SWUINeovimMac App Bundle`
- `Swift: Sign Release SWUINeovimMac App Bundle`
- `Swift: Notarize Release SWUINeovimMac App Bundle`
- `Swift: Store Notarytool Profile`
- `Swift: Package Signed Release SWUINeovimMac`
- `Swift: Package Notarized Release SWUINeovimMac`
