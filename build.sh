#!/bin/bash
# Fleet build: universal macOS CardMirror signed with our Apple team, for
# allow-listing in Santa by SigningID. See CLAUDE.md ("Fleet signed build")
# for the why behind each step.
#
# Usage:
#   ./build.sh                       # sign with the default identity below
#   CSC_NAME="Developer ID Application: Lake Highland Preparatory School (ZF23CE584E)" ./build.sh
#
# Env:
#   CSC_NAME       signing identity (must be in the login keychain)
#   EXPECTED_TEAM  Team ID every Mach-O must carry (default ZF23CE584E)
#   SKIP_INSTALL=1 skip `npm ci` (reuse existing node_modules)
#   ATTEMPTS       electron-builder attempts, for Apple timestamp flakes (default 3)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DESKTOP="$ROOT/apps/desktop"
APP="$DESKTOP/release/mac-universal/cardmirror.app"

export CSC_NAME="${CSC_NAME:-Apple Development: Dominic Canora (KQ5MTSDMD4)}"
EXPECTED_TEAM="${EXPECTED_TEAM:-ZF23CE584E}"
ATTEMPTS="${ATTEMPTS:-3}"

# electron-builder's signer signs every "binary-looking" file individually,
# each with its own timestamp request. ~380 of them are data (.pak locales,
# icudtl.dat, fonts, the bundled win/linux koffi builds) that the bundle
# seal already covers; signing them makes the build fail on transient
# timestamp-server errors. Only Mach-O needs its own signature.
SIGN_IGNORE='(\.pak|\.dat|\.bin|\.woff2|\.png|\.icns)$|/koffi-(win32|linux)-'

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ─── Preflight ───────────────────────────────────────────────────────
[ "$(uname -s)" = Darwin ] || die "macOS only"
security find-identity -v -p codesigning | grep -qF "\"$CSC_NAME\"" \
  || die "signing identity not in keychain: $CSC_NAME"
grep -q 'UPDATES_DISABLED = true' "$DESKTOP/src/updates-disabled.ts" \
  || die "apps/desktop/src/updates-disabled.ts must set UPDATES_DISABLED = true"
log "Signing as: $CSC_NAME (expect team $EXPECTED_TEAM)"

# ─── Dependencies ────────────────────────────────────────────────────
if [ "${SKIP_INSTALL:-0}" != 1 ]; then
  log "Installing dependencies"
  (cd "$ROOT" && npm ci)
  (cd "$DESKTOP" && npm ci)
fi

# npm installs only the host's koffi prebuild (@koromix/koffi-darwin-arm64
# on Apple Silicon). The universal app also needs the x64 one, or koffi
# fails to load on Intel Macs. Same approach as scripts/fetch-koffi-cross.sh.
KOFFI_VERSION=$(node -p "require('$DESKTOP/node_modules/koffi/package.json').version")
for pkg in koffi-darwin-arm64 koffi-darwin-x64; do
  dest="$DESKTOP/node_modules/@koromix/$pkg"
  have=$(node -p "require('$dest/package.json').version" 2>/dev/null || echo none)
  if [ "$have" = "$KOFFI_VERSION" ]; then
    echo "koffi: $pkg@$have present"
    continue
  fi
  echo "koffi: fetching @koromix/$pkg@$KOFFI_VERSION"
  tmp=$(mktemp -d)
  (cd "$tmp" && npm pack --silent "@koromix/$pkg@$KOFFI_VERSION" >/dev/null \
    && mkdir pkg && tar -xzf ./*.tgz -C pkg --strip-components=1)
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$tmp/pkg" "$dest"
  rm -rf "$tmp"
done

# ─── Build + sign ────────────────────────────────────────────────────
attempt=1
until
  log "Building (attempt $attempt/$ATTEMPTS)"
  rm -rf "$DESKTOP/release"
  (cd "$DESKTOP" && npm run dist -- --mac "-c.mac.signIgnore=$SIGN_IGNORE")
do
  [ "$attempt" -ge "$ATTEMPTS" ] && die "build failed after $ATTEMPTS attempts"
  attempt=$((attempt + 1))
  echo "build failed (often an Apple timestamp-server flake); retrying…"
done

# ─── Verify ──────────────────────────────────────────────────────────
log "Verifying signature"
codesign --verify --deep --strict "$APP"

bad=0; n=0
while IFS= read -r f; do
  n=$((n + 1))
  info=$(codesign -dv "$f" 2>&1)
  team=$(sed -n 's/^TeamIdentifier=//p' <<<"$info")
  if [ "$team" != "$EXPECTED_TEAM" ] || ! grep -q '^Timestamp=' <<<"$info"; then
    echo "BAD (team=${team:-none}, timestamp missing?): $f"
    bad=$((bad + 1))
  fi
done < <(find "$APP" -type f -exec file {} + | grep -v 'for architecture' | grep 'Mach-O' | cut -d: -f1)
[ "$bad" -eq 0 ] || die "$bad of $n Mach-O files not signed+timestamped by $EXPECTED_TEAM"
echo "$n Mach-O files signed by $EXPECTED_TEAM with secure timestamps"

if command -v santactl >/dev/null; then
  log "Santa SigningIDs (executables)"
  find "$APP" -type f -perm -111 -exec file {} + | grep -v 'for architecture' \
    | grep 'Mach-O.*executable' | cut -d: -f1 \
    | while IFS= read -r f; do santactl fileinfo "$f" --key "Signing ID"; done | sort -u
fi

log "Done"
ls -lh "$DESKTOP"/release/*.dmg "$DESKTOP"/release/*.zip
