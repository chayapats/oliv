#!/usr/bin/env bash
#
# release.sh — cut a OLIV release (W5-T1). Turns a version number into a
# distributable, Sparkle-ready artifact set:
#
#   dist/OLIV-X.Y.Z.dmg   the compressed, code-signed disk image users download
#   dist/appcast.xml        the Sparkle feed (EdDSA-signed) that points at it
#
# Pipeline: stamp version -> rebuild the self-contained bundle (build_app.sh) ->
# make + sign the dmg -> notarize+staple IF a notary profile exists (else print
# the one-time setup and continue local-only) -> sign the dmg with Sparkle +
# (re)generate the appcast -> print the `gh release create --repo "$OWNER/oliv" ...` command.
#
# Everything EXCEPT notarization + the GitHub push works today under the machine's
# Apple Development identity. The two things gated on the paid Apple Developer
# Program (W5-T2) are called out loudly and degrade to instructions, never a hard
# failure — so the day the cert + notary profile + GitHub repo exist, the same
# command produces a fully-notarized, publishable release with no code change.
#
# Usage:  bash scripts/release.sh X.Y.Z
# Signing identity: OLIV_SIGN_IDENTITY (same knob as build_app.sh); defaults to
# "Apple Development", ad-hoc "-" fallback (ad-hoc can't be notarized).

set -euo pipefail

# --------------------------------------------------------------------------- #
# Paths + helpers (repo layout mirrors build_app.sh).
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$ROOT/build"
CACHE="$BUILD/cache"
DIST="$ROOT/dist"
APP="$BUILD/OLIV.app"
PROJECT_YML="$ROOT/macos/project.yml"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mBLOCKED: %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Config. Pin Sparkle to the SAME release the app embeds (project.yml) so the
# framework and the CLI tools (generate_keys / sign_update / generate_appcast)
# are one matched set. OLIV_GITHUB_OWNER is a PLACEHOLDER until the repo exists
# (W5-T2) — the feed URL in Info.plist and the enclosure URLs here both reference
# it, and this script WARNS while it is still the placeholder.
# --------------------------------------------------------------------------- #
SPARKLE_VER="2.9.4"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz"
SPARKLE_DIR="$CACHE/sparkle-${SPARKLE_VER}"
SPARKLE_TARBALL="$CACHE/Sparkle-${SPARKLE_VER}.tar.xz"
# The signing key's Keychain account (Sparkle's default; set by bin/generate_keys).
ED_ACCOUNT="ed25519"

GITHUB_OWNER="chayapats"
NOTARY_PROFILE="oliv-notary"

# --------------------------------------------------------------------------- #
# 0. Args + preconditions.
# --------------------------------------------------------------------------- #
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "usage: bash scripts/release.sh X.Y.Z   (got: '${VERSION:-<none>}')"

[ "$(uname -m)" = "arm64" ] || die "packages an aarch64 runtime; run on Apple Silicon."
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)."
command -v hdiutil  >/dev/null || die "hdiutil not found (should ship with macOS)."

if grep -q "$GITHUB_OWNER" "$PROJECT_YML"; then
  warn "SUFeedURL / release URLs still use the placeholder '$GITHUB_OWNER'."
  warn "Sparkle updates will 404 until you create the GitHub repo and replace it"
  warn "in macos/project.yml (SUFeedURL). Continuing;"
  warn "the artifacts are still valid for local testing / manual install."
fi

# --------------------------------------------------------------------------- #
# Resolve the signing identity EXACTLY as build_app.sh does, so the dmg is signed
# with the same authority as the app inside it.
# --------------------------------------------------------------------------- #
IDENTITY="${OLIV_SIGN_IDENTITY:-Apple Development}"
if ! security find-identity -p codesigning -v | grep -q "$IDENTITY"; then
  warn "signing identity '$IDENTITY' not found — falling back to ad-hoc (NOT notarizable)."
  IDENTITY="-"
fi

# ONLY a "Developer ID Application" cert can be notarized. An "Apple Development"
# cert — which is this script's DEFAULT, and which `security find-identity` happily
# reports as present — signs a bundle that Apple then rejects with "not signed with
# a valid Developer ID certificate" + "no secure timestamp" (a Developer ID signature
# carries a secure timestamp; a development one does not). That failure is knowable
# HERE, for free. It cost a full round-trip to Apple's notary service and an
# unstaplable dmg before this check existed, so: if we hold notary credentials, we
# are cutting a real release, and a non-Developer-ID identity is a hard stop.
if [[ "$IDENTITY" != "Developer ID Application"* ]] \
   && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  die "identity '$IDENTITY' cannot be notarized, but notary credentials exist.
    Apple only notarizes a 'Developer ID Application' certificate.
    Re-run as:
      OLIV_SIGN_IDENTITY=\"$(security find-identity -v -p codesigning \
        | sed -n 's/.*\"\(Developer ID Application: [^\"]*\)\".*/\1/p' | head -1)\" \\
        bash scripts/release.sh $VERSION"
fi

# --------------------------------------------------------------------------- #
# 1. Stamp the version into project.yml (single source of truth), regenerate.
#    MARKETING_VERSION  -> the arg (CFBundleShortVersionString, display).
#    CURRENT_PROJECT_VERSION -> previous + 1 (CFBundleVersion, Sparkle's monotonic
#    update comparator — must strictly increase for Sparkle to offer the update).
#    Both flow into Info.plist via the $(...) mapping in project.yml.
# --------------------------------------------------------------------------- #
log "1. Stamp version $VERSION into macos/project.yml"
CUR_BUILD="$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | grep -oE '[0-9]+' | head -1)"
[ -n "$CUR_BUILD" ] || die "could not read CURRENT_PROJECT_VERSION from $PROJECT_YML"
NEXT_BUILD=$((CUR_BUILD + 1))
# BSD sed (macOS): -i '' for in-place; anchor on the key so we never touch the
# $(CURRENT_PROJECT_VERSION) reference inside the info block.
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:).*/\1 $VERSION/"        "$PROJECT_YML"
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:)[[:space:]]*[0-9]+.*/\1 $NEXT_BUILD/" "$PROJECT_YML"
echo "    MARKETING_VERSION=$VERSION  CURRENT_PROJECT_VERSION=$CUR_BUILD -> $NEXT_BUILD"
( cd "$ROOT/macos" && xcodegen generate >/dev/null )
echo "    regenerated OLIV.xcodeproj"

# --------------------------------------------------------------------------- #
# 2. Rebuild the self-contained, hardened, signed bundle. build_app.sh owns the
#    embedded runtime + per-binary-class entitlements + code signing; we just
#    forward the identity. This is the artifact that goes into the dmg.
# --------------------------------------------------------------------------- #
log "2. Rebuild build/OLIV.app via build_app.sh"
OLIV_SIGN_IDENTITY="$IDENTITY" bash "$SCRIPT_DIR/build_app.sh"
[ -d "$APP" ] || die "build_app.sh produced no $APP"
BUILT_SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "    built app version: $BUILT_SHORT ($BUILT_BUILD)"
[ "$BUILT_SHORT" = "$VERSION" ] || die "built app version '$BUILT_SHORT' != requested '$VERSION' (Info.plist mapping broken)."

# --------------------------------------------------------------------------- #
# 3. Build the DMG. Preferred path: dmgbuild (via uvx) — a styled, standard
#    drag-to-install window: custom background + arrow (assets/dmg/bg.tiff,
#    regenerate with scripts/make_dmg_background.py), OLIV.app and the
#    /Applications symlink pinned to icon slots, volume icon = the app icon;
#    all Finder view options written programmatically (no Finder scripting, no
#    TCC prompts). Fallback: the original bare hdiutil staging-dir dmg (works,
#    ugly) so a machine without uv can still cut a release.
# --------------------------------------------------------------------------- #
log "3. Create + sign dist/OLIV-$VERSION.dmg"
mkdir -p "$DIST"
DMG="$DIST/OLIV-$VERSION.dmg"
DMG_BG="$ROOT/assets/dmg/bg.tiff"
DMG_ICNS="$APP/Contents/Resources/AppIcon.icns"
# Created unconditionally (even though only the fallback path fills it): the
# later traps reference "$STAGING", and under `set -u` an unset var would blow
# up the EXIT trap itself.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
rm -f "$DMG"
if command -v uvx >/dev/null && [ -f "$DMG_BG" ] && [ -f "$DMG_ICNS" ]; then
  echo "    dmgbuild (styled installer window)..."
  uvx dmgbuild==1.6.5 -s "$SCRIPT_DIR/dmg_settings.py" \
    -D app="$APP" -D background="$DMG_BG" -D icon="$DMG_ICNS" \
    "OLIV $VERSION" "$DMG" >/dev/null
else
  warn "dmgbuild unavailable (need uvx + assets/dmg/bg.tiff + AppIcon.icns) — plain hdiutil dmg (unstyled)."
  cp -R "$APP" "$STAGING/OLIV.app"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "OLIV $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
fi
[ -f "$DMG" ] || die "dmg creation produced no $DMG"
# A dmg is a container, not executable code: sign it (no --options runtime).
codesign --force -s "$IDENTITY" "$DMG"
codesign --verify --verbose=1 "$DMG" 2>&1 | sed 's/^/    /' || true
echo "    $(du -sh "$DMG" | cut -f1)   $DMG"

# --------------------------------------------------------------------------- #
# 4. Notarization — GATED on a stored notary profile. `notarytool history`
#    succeeds only if `xcrun notarytool store-credentials oliv-notary ...` has
#    been run (W5-T2). If so: submit the dmg, wait, staple the ticket to BOTH the
#    dmg and the app, re-verify with Gatekeeper. If not: print the exact one-time
#    setup and continue — the release is still a valid local/manual install.
# --------------------------------------------------------------------------- #
log "4. Notarize + staple (gated on notary credentials)"
# Credential resolution, in order:
#   1. OLIV_NOTARY_APPLE_ID + OLIV_NOTARY_TEAM_ID + OLIV_NOTARY_PASSWORD env vars
#      (direct per-call creds — added after the keychain profile stored by
#      `notarytool store-credentials` was observed to VANISH from the login
#      keychain twice within an hour on this machine, silently un-gating this
#      step; cause unidentified — suspected iCloud-Keychain/data-protection
#      sync. Env creds have no such failure mode.)
#   2. the '$NOTARY_PROFILE' keychain profile (the documented notarytool flow)
NOTARY_ARGS=()
if [ -n "${OLIV_NOTARY_APPLE_ID:-}" ] && [ -n "${OLIV_NOTARY_TEAM_ID:-}" ] && [ -n "${OLIV_NOTARY_PASSWORD:-}" ]; then
  NOTARY_ARGS=(--apple-id "$OLIV_NOTARY_APPLE_ID" --team-id "$OLIV_NOTARY_TEAM_ID" --password "$OLIV_NOTARY_PASSWORD")
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi
if [ "$IDENTITY" = "-" ]; then
  warn "ad-hoc signed — cannot notarize. Skipping (local-only release)."
elif [ "${#NOTARY_ARGS[@]}" -gt 0 ]; then
  echo "    notary credentials found — submitting (this waits on Apple's service)..."
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  echo "    stapling ticket to the dmg and the app..."
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  echo "    re-verifying with Gatekeeper (should now be ACCEPTED):"
  spctl -a -vv -t install "$DMG" 2>&1 | sed 's/^/    /' || true
  codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /' || true
else
  warn "no notary credentials (env OLIV_NOTARY_* or profile '$NOTARY_PROFILE') — dmg signed but NOT notarized."
  warn "Gatekeeper will refuse it on other Macs until you do this ONCE (W5-T2):"
  cat >&2 <<EOF

    ---- one-time notarization setup (needs a paid Apple Developer account) ----
    1. Enroll in the Apple Developer Program:      https://developer.apple.com/programs/
    2. Create a "Developer ID Application" certificate in Certificates, IDs &
       Profiles, download + double-click it into your login Keychain, then point
       OLIV_SIGN_IDENTITY at it (e.g. "Developer ID Application: You (TEAMID)").
    3. Make an app-specific password at https://appleid.apple.com (Sign-In & Security).
    4. Store the notary credentials under the profile this script looks for:
         xcrun notarytool store-credentials $NOTARY_PROFILE \\
           --apple-id "you@example.com" \\
           --team-id  "SRAQ34JPLS" \\
           --password "xxxx-xxxx-xxxx-xxxx"   # the app-specific password
    Re-run this script afterwards — step 4 will notarize + staple automatically.
    ---------------------------------------------------------------------------
EOF
fi

# --------------------------------------------------------------------------- #
# 5. Sparkle appcast. Ensure the pinned Sparkle CLI tools are present (download +
#    extract the release tarball, cached like the CPython one), export the private
#    EdDSA key from the Keychain WITHOUT a GUI prompt (only generate_keys — the
#    tool that created it — can read it silently; sign_update/generate_appcast
#    would otherwise pop a Keychain dialog and hang), then sign the dmg and
#    (re)generate dist/appcast.xml. The key file is a mktemp, shredded on exit;
#    the master key stays in the Keychain untouched.
# --------------------------------------------------------------------------- #
log "5. Sparkle: sign the dmg + (re)generate dist/appcast.xml"

ensure_sparkle_tools() {
  if [ -x "$SPARKLE_DIR/bin/generate_appcast" ] && [ -x "$SPARKLE_DIR/bin/sign_update" ]; then
    return 0
  fi
  echo "    fetching Sparkle $SPARKLE_VER tools (cached under build/cache/)..."
  mkdir -p "$CACHE"
  [ -f "$SPARKLE_TARBALL" ] || curl -fSL --retry 3 -o "$SPARKLE_TARBALL" "$SPARKLE_URL"
  rm -rf "$SPARKLE_DIR"; mkdir -p "$SPARKLE_DIR"
  tar -xJf "$SPARKLE_TARBALL" -C "$SPARKLE_DIR"
}
ensure_sparkle_tools
GEN_KEYS="$SPARKLE_DIR/bin/generate_keys"
SIGN_UPDATE="$SPARKLE_DIR/bin/sign_update"
GEN_APPCAST="$SPARKLE_DIR/bin/generate_appcast"

# Export the private key silently (same-binary Keychain ACL). generate_keys -x
# REFUSES to overwrite an existing file, so the target must NOT pre-exist — hence
# a temp DIR + a filename inside it (not `mktemp`, which creates the file). If no
# key exists at all, the developer hasn't run generate_keys yet — hard stop, since
# Sparkle updates are unusable without a signature.
KEYDIR="$(mktemp -d)"
KEYFILE="$KEYDIR/ed25519.key"
cleanup_key() { rm -rf "$KEYDIR" 2>/dev/null || true; }
trap 'cleanup_key; rm -rf "$STAGING"' EXIT
if ! "$GEN_KEYS" -x "$KEYFILE" >/dev/null 2>&1 || [ ! -s "$KEYFILE" ]; then
  die "no Sparkle EdDSA signing key in the Keychain. Generate one:
       $GEN_KEYS
     then put the printed SUPublicEDKey into macos/project.yml (info properties)."
fi

# Print the enclosure signature (satisfies 'sign the dmg with Sparkle').
EDSIG="$("$SIGN_UPDATE" "$DMG" --ed-key-file "$KEYFILE")"
echo "    sign_update: $EDSIG"

# Release-notes stub for THIS version, pulled from CHANGELOG.md (falls back to
# the Unreleased section), rendered to the .html file generate_appcast embeds
# (it looks for <archive-basename>.html next to the archive).
notes_body() {
  awk -v ver="$VERSION" '
    $0 ~ ("^## \\[" ver "\\]") {g=1; next}
    g && /^## \[/ {exit}
    g {print}
  ' "$ROOT/CHANGELOG.md"
  # fall back to Unreleased if the version section was empty
}
NOTES="$(notes_body)"
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
  NOTES="$(awk '/^## \[Unreleased\]/{g=1;next} g&&/^## \[/{exit} g{print}' "$ROOT/CHANGELOG.md")"
fi
APPCAST_STAGE="$(mktemp -d)"
trap 'cleanup_key; rm -rf "$STAGING" "$APPCAST_STAGE"' EXIT
cp "$DMG" "$APPCAST_STAGE/"
# Render the CHANGELOG bullets to a simple <ul>. awk accumulates each bullet with
# its wrapped continuation lines and flushes on the next bullet / at EOF, so the
# multi-line entries in CHANGELOG.md don't produce stray tags.
{
  echo "<h2>OLIV $VERSION</h2>"
  printf '%s\n' "$NOTES" | awk '
    BEGIN { print "<ul>"; item="" }
    /^[[:space:]]*[-*][[:space:]]+/ {
      if (item != "") printf "  <li>%s</li>\n", item
      line=$0; sub(/^[[:space:]]*[-*][[:space:]]+/,"",line); item=line; next
    }
    /[^[:space:]]/ { cont=$0; sub(/^[[:space:]]+/," ",cont); item=item cont; next }
    END { if (item != "") printf "  <li>%s</li>\n", item; print "</ul>" }
  '
} > "$APPCAST_STAGE/OLIV-$VERSION.html"

# Generate the appcast for JUST this release. Enclosure URLs use the versioned
# GitHub tag path (stable per release); the FEED itself is served from the
# latest release via SUFeedURL (…/releases/latest/download/appcast.xml).
"$GEN_APPCAST" "$APPCAST_STAGE" \
  --ed-key-file "$KEYFILE" \
  --download-url-prefix "https://github.com/$GITHUB_OWNER/oliv/releases/download/v$VERSION/" \
  --link "https://github.com/$GITHUB_OWNER/oliv" >/dev/null
[ -f "$APPCAST_STAGE/appcast.xml" ] || die "generate_appcast produced no appcast.xml"
cp "$APPCAST_STAGE/appcast.xml" "$DIST/appcast.xml"
# Validate it's well-formed XML and carries the EdDSA signature.
xmllint --noout "$DIST/appcast.xml" 2>/dev/null || die "generated appcast.xml is not well-formed XML."
grep -q 'edSignature' "$DIST/appcast.xml" || die "appcast.xml is missing the EdDSA signature."
echo "    wrote $DIST/appcast.xml (well-formed, EdDSA-signed)"

# --------------------------------------------------------------------------- #
# 6. Hand-off. Print (do NOT run) the GitHub release command — no remote exists
#    yet (W5-T2). Sparkle needs BOTH assets publicly downloadable at the tag.
# --------------------------------------------------------------------------- #
NOTES_FILE="$DIST/RELEASE_NOTES_$VERSION.md"
{ echo "# OLIV $VERSION"; echo; printf '%s\n' "$NOTES"; } > "$NOTES_FILE"

log "DONE — release $VERSION staged"
cp "$DMG" "$DIST/OLIV.dmg"   # stable-name alias -> latest/download/OLIV.dmg stays valid forever
echo "    dist/OLIV-$VERSION.dmg (+ OLIV.dmg alias)"
echo "    dist/appcast.xml"
echo "    dist/RELEASE_NOTES_$VERSION.md"
echo
echo "    Publish (only once the GitHub repo exists + OLIV_GITHUB_OWNER is set):"
echo
echo "      gh release create --repo $GITHUB_OWNER/oliv v$VERSION \\"
echo "        \"$DIST/OLIV-$VERSION.dmg\" \\"
echo "        \"$DIST/OLIV.dmg\" \\"
echo "        \"$DIST/appcast.xml\" \\"
echo "        --title \"OLIV $VERSION\" \\"
echo "        --notes-file \"$NOTES_FILE\""
echo
echo "    (NOT run automatically — no git remote yet. The appcast's enclosure URL"
echo "     points at the v$VERSION tag assets, so publish the dmg under that tag.)"
