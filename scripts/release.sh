#!/bin/bash
# MioIsland Release Script
# Usage: ./scripts/release.sh v2.0.2
#
# Ships unsigned builds with Sparkle EdDSA signing for auto-updates.
# Users must right-click → Open or run
# `xattr -dr com.apple.quarantine` on first launch. Gatekeeper + the
# Homebrew cask's postflight handle this transparently.
#
# Signing / notarization were removed after Apple's statusCode 7000
# server-side issue kept recurring and blocking releases.

set -e
set -o pipefail  # without this, `xcodebuild ... | tail -1` swallows build
                 # failures and ships a stale cached binary. v2.2.5 burned
                 # on exactly this: an unresolved merge conflict caused
                 # xcodebuild to fail, but `| tail -1` masked the exit
                 # code so the DMG was built from a 2.2.4 DerivedData cache.

VERSION="${1:?Usage: $0 <version>}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"
RELEASE_DIR="$PROJECT_DIR/releases"

# Auto-detect DerivedData path. Pick the MOST RECENTLY MODIFIED ClaudeIsland-*
# dir, not an arbitrary one — a machine can accumulate several (project moved,
# second clone, the ClaudeIsland→"Mio Island" rename kept the old DD key).
# `find | head -1` returned filesystem order, which could be a stale dir. The
# post-build CFBundleVersion assertion (step 2b) is the hard guarantee that we
# packaged the freshly-built binary regardless of which dir is chosen.
DD_BASE="$HOME/Library/Developer/Xcode/DerivedData"
DD_ROOT=$(find "$DD_BASE" -maxdepth 1 -name "ClaudeIsland-*" -type d 2>/dev/null \
  -exec stat -f '%m %N' {} \; | sort -rn | head -1 | cut -d' ' -f2-)
if [ -z "$DD_ROOT" ]; then
  echo "ERROR: No ClaudeIsland DerivedData found. Build the project in Xcode once first."
  exit 1
fi
BUILD_DIR="$DD_ROOT/Build/Products/Release"
APP_PATH="$BUILD_DIR/Mio Island.app"
ZIP_PATH="$PROJECT_DIR/MioIsland-${VERSION}.zip"
DMG_PATH="$PROJECT_DIR/MioIsland-${VERSION}.dmg"

echo "=== MioIsland Release $VERSION ==="

# 0. Pre-flight: must run from main, and local main must not be behind
# origin/main. Both guards fail fast (before the ~8-min build) and loudly.
# Without them: running from a feature branch silently tags+pushes the wrong
# branch (main's version never bumps → next release's build number collides);
# a behind/diverged main produces a tag that disagrees with shipped history.
PREFLIGHT_BRANCH=$(git -C "$PROJECT_DIR" branch --show-current)
if [ "$PREFLIGHT_BRANCH" != "main" ]; then
  echo "ERROR: release.sh must run from 'main', but you are on '$PREFLIGHT_BRANCH'."
  echo "Fix:   git checkout main && git pull"
  exit 1
fi
git -C "$PROJECT_DIR" fetch origin main --quiet 2>/dev/null || true
if git -C "$PROJECT_DIR" rev-parse origin/main >/dev/null 2>&1; then
  if ! git -C "$PROJECT_DIR" merge-base --is-ancestor origin/main HEAD; then
    echo "ERROR: local main is behind or diverged from origin/main."
    echo "Fix:   git pull --ff-only  (or rebase), then re-run."
    exit 1
  fi
fi

# 1. Update version in Xcode project
CLEAN_VERSION="${VERSION#v}"  # v2.0.2 -> 2.0.2
echo ">>> Setting version to $CLEAN_VERSION..."
sed -i '' "s/MARKETING_VERSION = [0-9.]*/MARKETING_VERSION = $CLEAN_VERSION/g" \
  "$PROJECT_DIR/ClaudeIsland.xcodeproj/project.pbxproj"

# Auto-increment build number
OLD_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT_DIR/ClaudeIsland.xcodeproj/project.pbxproj" | grep -oE '[0-9]+')
NEW_BUILD=$((OLD_BUILD + 1))
echo ">>> Bumping build number $OLD_BUILD → $NEW_BUILD..."
sed -i '' "s/CURRENT_PROJECT_VERSION = $OLD_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" \
  "$PROJECT_DIR/ClaudeIsland.xcodeproj/project.pbxproj"

# 2. Build (unsigned, universal)
#
# ARCHS + ONLY_ACTIVE_ARCH are critical: xcodebuild defaults to building
# only the current machine's architecture, which would ship an arm64-only
# binary to Intel Mac users — who then see "Mio Island can't be opened"
# with no recoverable error (xattr won't help, it's a pure architecture
# mismatch). Force a universal build so the same zip works on both archs.
echo ">>> Building Release (unsigned, universal arm64+x86_64)..."
cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build"
BUILD_LOG="$PROJECT_DIR/.build/build-${VERSION}.log"
xcodebuild -scheme ClaudeIsland -configuration Release build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" 2>&1 | tee "$BUILD_LOG" | tail -1

# 2b. Verify the build produced the bundle we expect, with the version we just
# stamped. Catches: stale DerivedData dir, xcodebuild reusing a cached product
# (the v2.2.5 class), or a silent no-op. Without this, steps 3-8 happily
# package and sign whatever old .app sits at APP_PATH.
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: build did not produce \"$APP_PATH\"."
  echo "Last 40 lines of $BUILD_LOG:"
  tail -40 "$BUILD_LOG" | sed 's/^/    /'
  exit 1
fi
BUILT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")
if [ "$BUILT_BUILD" != "$NEW_BUILD" ]; then
  echo "ERROR: built CFBundleVersion ($BUILT_BUILD) != expected ($NEW_BUILD)."
  echo "The packaged binary would be STALE (cached or wrong DerivedData dir)."
  echo "Fix:   Xcode → Product → Clean Build Folder, then re-run."
  exit 1
fi
echo "    Built CFBundleVersion $BUILT_BUILD ✓"

# 3. Bundle built-in plugins into the .app.
BUNDLED_PLUGINS_SRC="$PROJECT_DIR/ClaudeIsland/Resources/Plugins"
BUNDLED_PLUGINS_DST="$APP_PATH/Contents/Resources/Plugins"
if [ -d "$BUNDLED_PLUGINS_SRC" ]; then
  echo ">>> Copying bundled plugins..."
  rm -rf "$BUNDLED_PLUGINS_DST"
  mkdir -p "$BUNDLED_PLUGINS_DST"
  for b in "$BUNDLED_PLUGINS_SRC"/*.bundle; do
    [ -d "$b" ] || continue
    cp -R "$b" "$BUNDLED_PLUGINS_DST/"
    echo "    $(basename "$b")"
  done
fi

# 4. Ad-hoc sign.
echo ">>> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_PATH"

# 5. Package ZIP (ALWAYS ditto, never zip — regular zip adds ._* AppleDouble files)
echo ">>> Packaging ZIP..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "    ZIP: $(du -h "$ZIP_PATH" | cut -f1)"

# 6. Create DMG with Applications link
echo ">>> Creating DMG..."
rm -f "$DMG_PATH"
if command -v create-dmg &> /dev/null; then
  create-dmg \
    --volname "Mio Island" \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Mio Island.app" 150 200 \
    --app-drop-link 450 200 \
    --hide-extension "Mio Island.app" \
    "$DMG_PATH" \
    "$APP_PATH" 2>&1 | tail -3
else
  DMG_STAGING=$(mktemp -d)
  cp -R "$APP_PATH" "$DMG_STAGING/"
  ln -s /Applications "$DMG_STAGING/Applications"
  hdiutil create -volname "Mio Island" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"
  rm -rf "$DMG_STAGING"
fi
echo "    DMG: $(du -h "$DMG_PATH" | cut -f1)"

# 7. Sparkle EdDSA signing
#    Signs the DMG so Sparkle can verify update integrity.
#    Requires .sparkle-keys/eddsa_private_key — run generate-keys.sh first.
SPARKLE_SIGN=""
POSSIBLE_SIGN_PATHS=(
  "$DD_ROOT/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  "$HOME/Library/Developer/Xcode/DerivedData/ClaudeIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  "/usr/local/bin/sign_update"
)
for path_pattern in "${POSSIBLE_SIGN_PATHS[@]}"; do
  for path in $path_pattern; do
    if [ -x "$path" ]; then
      SPARKLE_SIGN="$path"
      break 2
    fi
  done
done

SPARKLE_SIG=""
if [ -n "$SPARKLE_SIGN" ] && [ -f "$KEYS_DIR/eddsa_private_key" ]; then
  echo ">>> Signing DMG with Sparkle EdDSA..."
  # `|| true`: a non-zero sign_update exit (corrupt key, perm error, Sparkle
  # version mismatch) must NOT trip set -e here — it has to flow into the
  # ED_SIG-empty HARD STOP below so the operator sees the friendly diagnostic.
  SPARKLE_SIG=$("$SPARKLE_SIGN" "$DMG_PATH" --ed-key-file "$KEYS_DIR/eddsa_private_key" 2>&1 || true)
  echo "    Signature: ${SPARKLE_SIG:0:40}..."
fi

# 8. Generate appcast.xml
mkdir -p "$RELEASE_DIR"
DMG_SIZE=$(stat -f%z "$DMG_PATH")
APPCAST_PATH="$RELEASE_DIR/appcast.xml"
DOWNLOAD_URL="https://github.com/MioMioOS/MioIsland/releases/download/${VERSION}/MioIsland-${VERSION}.dmg"

# Parse sparkleEdSignature and sparkleLength from sign_update output
ED_SIG=$(echo "$SPARKLE_SIG" | grep -oE 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//' || true)
SIG_LENGTH=$(echo "$SPARKLE_SIG" | grep -oE 'length="[^"]*"' | sed 's/length="//;s/"//' || true)
[ -z "$SIG_LENGTH" ] && SIG_LENGTH="$DMG_SIZE"

# HARD STOP: Sparkle auto-update breaks silently with empty signatures.
# v2.1.6 shipped a bare appcast (no key on the release machine) and every
# user saw "此更新未正确签名". We would rather abort now than push that.
if [ -z "$ED_SIG" ]; then
  echo ""
  echo "ERROR: Sparkle EdDSA signing did not produce a signature."
  echo "Refusing to publish an unsigned appcast — every Sparkle auto-update"
  echo "would fail with '此更新未正确签名'."
  echo ""
  if [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
    echo "Cause: .sparkle-keys/eddsa_private_key is missing."
    echo "Fix:   ask the project admin for the canonical private key."
    echo "       See docs/RELEASE-GUIDE.md §3 for details."
  elif [ -z "$SPARKLE_SIGN" ]; then
    echo "Cause: sign_update tool not found."
    echo "Fix:   build the project in Xcode once to download the Sparkle"
    echo "       SPM package, then re-run this script."
  else
    echo "Cause: sign_update ran but returned unexpected output:"
    echo "$SPARKLE_SIG" | sed 's/^/       /'
  fi
  exit 1
fi

echo ">>> Generating appcast.xml..."
# Derive minimumSystemVersion from the project's actual deployment target so a
# bumped MACOSX_DEPLOYMENT_TARGET never silently disagrees with the appcast.
MIN_OS=$(grep -m1 'MACOSX_DEPLOYMENT_TARGET = ' "$PROJECT_DIR/ClaudeIsland.xcodeproj/project.pbxproj" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
[ -z "$MIN_OS" ] && MIN_OS="15.0"
cat > "$APPCAST_PATH" << APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mio Island Updates</title>
    <link>https://miomioos.github.io/MioIsland/appcast.xml</link>
    <description>Mio Island update feed</description>
    <language>en</language>
    <item>
      <title>Mio Island $CLEAN_VERSION</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$CLEAN_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <enclosure
        url="$DOWNLOAD_URL"
        length="$SIG_LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="$ED_SIG"
      />
    </item>
  </channel>
</rss>
APPCAST_EOF
echo "    Appcast: $APPCAST_PATH"

# Order matters from here. Sparkle clients poll appcast.xml every few hours; if
# appcast advertises $VERSION before the DMG is uploaded to GitHub Releases,
# every poller in that window hits a 404 on the download URL. v3.0.1 burned on
# a related issue (step 9's stash + checkout silently aborted, skipping the
# tag) so the new order is:
#   9.  commit pbxproj + tag main
#   10. push main + tags
#   11. gh release create (upload DMG + ZIP) — DMG is live on GitHub
#   12. push appcast to landing-page — Sparkle can now resolve the URL
# The race window from appcast-published to DMG-uploaded is now closed.

GH_BIN="$(command -v gh || true)"
if [ -z "$GH_BIN" ]; then
  echo "ERROR: gh CLI not found. Install it with: brew install gh"
  echo "       (release.sh now uploads the GitHub release directly to close"
  echo "        the Sparkle 'appcast advertises before DMG exists' race window.)"
  exit 1
fi

# 9. Commit version bump and tag
echo ">>> Tagging $VERSION on main..."
git add "$PROJECT_DIR/ClaudeIsland.xcodeproj/project.pbxproj"
# Commit only if the bump actually staged something. Re-running for the same
# version (after a later-step failure) finds nothing staged and skips the
# commit, instead of the old `--allow-empty` which stacked an empty commit on
# every retry — pushing HEAD past the tag each time.
if ! git diff --cached --quiet; then
  git commit -m "$VERSION: Release"
else
  echo "    (pbxproj already committed for $VERSION — reusing HEAD)"
fi
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "    (tag $VERSION already exists — reusing)"
else
  git tag "$VERSION"
fi

# 10. Push main + tag (explicit refs — never `HEAD`, which would push whatever
# branch you happen to be on). The preflight guaranteed we are on main and not
# behind origin, so this is a fast-forward.
echo ">>> Pushing main + tag $VERSION..."
git push origin main
git push origin "$VERSION"

# 11. Create GitHub release with DMG + ZIP (must be PUBLISHED before appcast goes live)
echo ">>> Creating GitHub release with DMG + ZIP..."
if gh release view "$VERSION" >/dev/null 2>&1; then
  echo "    (release $VERSION already exists — uploading assets idempotently)"
  gh release upload "$VERSION" "$DMG_PATH" "$ZIP_PATH" --clobber
else
  # DO NOT use --draft. v3.0.2 burned on exactly this: --draft was added
  # to "protect hand-written release notes" but draft state means
  # https://github.com/.../releases/download/v$VERSION/... returns 404,
  # while step 12 below pushes appcast.xml advertising that 404 URL to
  # GitHub Pages, causing every Sparkle client to fail "update download"
  # until the user manually clicks Publish in the GitHub UI.
  #
  # Publish immediately with a placeholder note. The user is free to
  # edit the release notes after the fact via the GitHub UI; published
  # releases remain editable. The appcast then points at a real,
  # downloadable DMG from the moment it goes live.
  gh release create "$VERSION" "$DMG_PATH" "$ZIP_PATH" \
    --title "$VERSION — Mio Island" \
    --notes "Release $VERSION. Detailed notes to follow — edit via GitHub UI."
fi

# 11b. Smoke test: verify the public DMG URL is actually reachable before
# advertising it in appcast.xml. GitHub returns 302 → CDN 200 for valid
# releases; any 4xx means something is wrong (draft state regression,
# wrong tag, broken upload). Refuse to push the appcast in that case so
# we don't ship a 404 advertisement again.
DMG_PUBLIC_URL="https://github.com/MioMioOS/MioIsland/releases/download/${VERSION}/MioIsland-${VERSION}.dmg"
echo ">>> Smoke testing DMG URL: $DMG_PUBLIC_URL"
# Distinguish transient failures (000 timeout / 5xx) from definitive ones
# (403/404 = draft or missing asset). Retry transient up to 5x — a network
# blip must NOT abort here, because by now the release is already public and
# aborting would leave the appcast un-pushed. Fail fast on 403/404 (retrying
# can't fix a draft/missing asset).
SMOKE_OK=0
SMOKE_STATUS="000"
for attempt in 1 2 3 4 5; do
  SMOKE_STATUS=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 10 "$DMG_PUBLIC_URL" 2>/dev/null || echo "000")
  if [[ "$SMOKE_STATUS" =~ ^(200|302)$ ]]; then
    SMOKE_OK=1; break
  fi
  if [[ "$SMOKE_STATUS" =~ ^(403|404)$ ]]; then
    echo "    HTTP $SMOKE_STATUS — asset not public (draft? wrong tag?). Not retrying."
    break
  fi
  echo "    attempt $attempt/5: HTTP $SMOKE_STATUS (transient), retrying in 5s..."
  sleep 5
done
if [ "$SMOKE_OK" = 1 ]; then
  echo "    DMG reachable (HTTP $SMOKE_STATUS)"
else
  echo ""
  echo "ERROR: DMG public URL not reachable (last HTTP $SMOKE_STATUS). Refusing to"
  echo "push appcast.xml — Sparkle clients would see the new version but fail to"
  echo "download. The GitHub release IS published (DMG uploaded); to finish:"
  echo "  1) verify: gh release view $VERSION"
  echo "  2) re-run: ./scripts/release.sh $VERSION  (idempotent — re-checks, then pushes appcast)"
  exit 1
fi

# 12. Deploy appcast.xml to landing-page (race window closed: DMG is now on GitHub)
echo ">>> Deploying appcast.xml to landing-page..."

ORIGINAL_BRANCH=$(git branch --show-current)
STASH_MSG="release-sh-tmp-$VERSION-$$"
RELEASE_STASHED=0

# Defensive cleanup: if any step below fails (or set -e fires), get the user
# back to their original branch and restore the stash. v3.0.1 release burned
# here: stash was missing --include-untracked, landing/.vite/ blocked the
# checkout, the error was swallowed by 2>/dev/null, and the script silently
# died leaving step 10 (tag) unrun.
restore_state() {
  local cur
  cur=$(git branch --show-current 2>/dev/null || echo "")
  if [ -n "$ORIGINAL_BRANCH" ] && [ "$cur" != "$ORIGINAL_BRANCH" ]; then
    if ! git checkout "$ORIGINAL_BRANCH" 2>/dev/null; then
      # CRITICAL: if we cannot get back to the original branch, do NOT pop the
      # stash — that would restore the operator's WIP onto landing-page (the
      # wrong branch). Bail out of cleanup and tell them how to recover.
      echo "    WARN: could not return to $ORIGINAL_BRANCH (still on '$cur')."
      echo "    NOT popping stash — it would land your work on the wrong branch."
      echo "    Recover manually: git checkout $ORIGINAL_BRANCH && git stash pop"
      return
    fi
  fi
  if [ "$RELEASE_STASHED" -eq 1 ]; then
    local stash_ref
    stash_ref=$(git stash list 2>/dev/null | grep -F "$STASH_MSG" | head -1 | cut -d: -f1)
    if [ -n "$stash_ref" ]; then
      # No 2>/dev/null: a pop conflict must be visible, not swallowed.
      git stash pop "$stash_ref" || \
        echo "    WARN: stash pop failed/conflicted — resolve manually (stash msg: $STASH_MSG)"
    fi
    RELEASE_STASHED=0
  fi
}
trap restore_state EXIT

# Stash everything (including untracked + ignored) so checkout cannot fail
# on dirty working tree. --include-untracked alone misses .gitignored files,
# but landing-page's .gitignore may differ from main's, so use --all.
if ! git diff --quiet || \
   ! git diff --cached --quiet || \
   [ -n "$(git ls-files --others --exclude-standard)" ]; then
  git stash push --include-untracked --message "$STASH_MSG"
  RELEASE_STASHED=1
fi

git checkout landing-page
cp "$APPCAST_PATH" "$PROJECT_DIR/landing/public/appcast.xml"
git add "$PROJECT_DIR/landing/public/appcast.xml"
if ! git diff --cached --quiet; then
  git commit -m "chore: update appcast.xml for $VERSION"
  git push origin landing-page
  echo "    Pushed appcast.xml to landing-page"
else
  echo "    (no appcast changes — already up to date on landing-page)"
fi

# Explicitly run cleanup now and disarm the trap so a clean exit doesn't
# re-trigger it.
restore_state
trap - EXIT

echo ""
echo "=== Done! ==="
echo "DMG:     $DMG_PATH"
echo "ZIP:     $ZIP_PATH"
echo "Appcast: $APPCAST_PATH (deployed to GitHub Pages)"
echo ""
echo "Release is LIVE. Polish release notes via:"
echo "  gh release view $VERSION --web"
echo "  (then edit body — Sparkle clients already have download access)"
