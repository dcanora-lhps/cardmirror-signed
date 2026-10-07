# CLAUDE.md

This checkout is a **fleet build** of the open-source CardMirror (upstream:
github.com/ant981228/cardmirror). Upstream ships unsigned macOS builds; we
rebuild and sign with our Apple team so the app can be allow-listed in
**Santa by SigningID** across the fleet. Project docs: `README.md`,
`ARCHITECTURE.md`, `PROJECT.md`.

## Fleet signed build

Build with `./build.sh` (repo root). Output: `apps/desktop/release/CardMirror-<version>-universal.dmg`
and `.zip`. The script checks the signing identity, installs deps, fetches the
x64 koffi prebuild, builds + signs (retrying timestamp flakes), and verifies
every Mach-O carries our Team ID and a secure timestamp. When `santactl` is
present it prints the SigningIDs at the end.

- Desktop app = Electron, packaged by electron-builder from `apps/desktop`
  (config in the `build` field of `apps/desktop/package.json`; hardened
  runtime + `build/entitlements.mac.plist`).
- Signing is passed via `CSC_NAME`. electron-builder signs the whole bundle
  (main app, all helpers, frameworks, native modules) with that identity.
- `apps/desktop/scripts/sign-mac.js` (the `afterSign` hook) re-signs with a
  self-signed "CardMirror Local Signing" cert **only if that cert is in the
  keychain**. It isn't on our build machine, so the hook no-ops. Its log line
  "keeping ad-hoc signature" is misleading — ignore it. Never run
  `scripts/setup-signing.sh` on the build machine: that installs the
  self-signed cert, the hook would then overwrite our team signature, and
  Santa rules would stop matching.

### Signing identity

| Identity | Team | Status |
|---|---|---|
| `Apple Development: Dominic Canora (KQ5MTSDMD4)` | `ZF23CE584E` (Lake Highland Preparatory School) | **Current** stopgap (default in `build.sh`) |
| `Developer ID Application: Lake Highland Preparatory School (ZF23CE584E)` | `ZF23CE584E` | **Target**, not yet issued |

- Developer ID Application certs can only be created by the team's **Account
  Holder** (we are not; the portal returns "This operation can only be
  performed by the Account Holder"). Process: generate a CSR in Keychain
  Access on the build Mac (Certificate Assistant → Request a Certificate From
  a Certificate Authority → Saved to disk), send it to the Account Holder,
  they create Developer ID Application (G2 Sub-CA) and return the `.cer`,
  double-click to install, then export cert + private key to a `.p12` backup.
- Switching certs does not change SigningIDs (they are `TeamID:identifier`),
  so Santa rules survive the move. Build with
  `CSC_NAME="Developer ID Application: Lake Highland Preparatory School (ZF23CE584E)" ./build.sh`.
- An Apple Development cert does not pass Gatekeeper (`spctl` rejects it) and
  can't be notarized. Deploy **via Mosyle** (MDM installs aren't quarantined),
  not as a user download. Notarization (needs an App Store Connect API key
  from the Account Holder) becomes possible once on Developer ID.
- The Apple Development cert expires 2027-08-26. Signatures are timestamped,
  so existing builds stay valid after expiry; new builds need a new cert.
- Another identity in the keychain, `Apple Development: dcanoralhps@gmail.com`,
  is on a personal team (`6ADQ55Z7MY`). Do not use it.

### Santa SigningID rules

Verified with `santactl fileinfo` on the 1.14.0 build. Case matters:

```
ZF23CE584E:com.cardmirror.app
ZF23CE584E:com.cardmirror.app.helper
ZF23CE584E:com.cardmirror.app.helper.Renderer
ZF23CE584E:com.cardmirror.app.helper.GPU
ZF23CE584E:com.cardmirror.app.helper.Plugin
ZF23CE584E:chrome_crashpad_handler
```

`ZF23CE584E:ShipIt` (Squirrel's updater) also exists in the bundle but never
runs because auto-update is disabled, so it needs no rule. Everything else
native (koffi, sherpa-onnx, `ax-suppress.dylib`) is a dylib, which is loaded
rather than exec'd, so Santa doesn't evaluate it. Re-check this list if
upstream renames the app, changes `appId`, or adds a spawned binary.

### Local changes vs upstream

- **Auto-update disabled.** `apps/desktop/src/updates-disabled.ts` exports
  `UPDATES_DISABLED = true`. `apps/desktop/src/main.ts` checks it in
  `runUpdateCheck`, `startAutoUpdate`, the Help → "Check for Updates…" menu
  item, and the `host:check-for-updates` IPC (which returns "Updates are
  managed by your organization."). Reason: electron-updater would pull
  upstream's unsigned builds, which Santa blocks (and the mac swap-updater
  would replace our signed bundle). Updates ship as a rebuilt, re-signed
  release pushed through Mosyle. Known cosmetic leftover: the renderer's
  Settings still shows the "check for updates on launch" checkbox. It has no
  effect.
- **Bundle ID** left as upstream's `com.cardmirror.app`. The TeamID prefix in
  the Santa rules already stops upstream-signed copies from matching.

### Build gotchas (all handled in `build.sh`)

- **koffi x64 prebuild.** npm installs only the host's
  `@koromix/koffi-darwin-arm64`. A universal build without
  `@koromix/koffi-darwin-x64` crashes koffi on Intel Macs. `build.sh` fetches
  both at the installed koffi version. A fresh `npm ci` removes the x64 one,
  so always build through the script.
- **Timestamp failures.** electron-builder signs every binary-looking file
  separately (~430 files, mostly `.pak`/`.dat`/fonts), each with a request
  to Apple's timestamp server. It failed twice with "A timestamp was expected
  but was not found". Fix: `-c.mac.signIgnore=...` skips data files, which the
  bundle's `CodeResources` seal still covers. That leaves ~18 Mach-O files to
  sign, and the build succeeds. `build.sh` also retries the build (`ATTEMPTS`,
  default 3).
- Signing is slow because Mosyle's security extension scans each `codesign`
  call. A full build takes ~10–15 min.
- npm 11's install-script allowlist skips some dependency install scripts
  (esbuild, koffi, electron-winstaller). The build works anyway: esbuild's
  platform binary still installs, and koffi uses the `@koromix` prebuilds.
- On first signing, macOS may prompt for `codesign` to use the key. Choose
  "Always Allow".

### Verifying a build manually

```
APP=apps/desktop/release/mac-universal/cardmirror.app
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP"                        # Authority / TeamIdentifier / Timestamp
santactl fileinfo "$APP/Contents/MacOS/cardmirror" --key "Signing ID"
```

To smoke-test a build, launch it with `open -n "$APP"` and confirm the
main, renderer, helper and crashpad processes appear. Only Apple Silicon has
been tested so far, not Intel.

## Updating to a new upstream release

1. `git fetch` upstream and merge or rebase. Keep `updates-disabled.ts` and its
   checks in `main.ts`. If upstream refactors the updater, re-add a check
   at every `autoUpdater.checkForUpdates()` call site and in `startAutoUpdate`.
2. `./build.sh`, then compare the printed SigningIDs with the list above.
3. Push the new `.dmg`/`.zip` through Mosyle.
