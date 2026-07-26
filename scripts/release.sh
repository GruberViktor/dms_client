#!/usr/bin/env bash
#
# LUVI Docs — build, package and publish a GitHub release.
#
#   scripts/release.sh                 release the version from pubspec.yaml
#   scripts/release.sh 1.0.1           release an explicit version
#   scripts/release.sh --draft         publish as a draft to review first
#   scripts/release.sh --skip-build    reuse the existing build/ output
#   scripts/release.sh --retag         move an existing tag to HEAD (force push)
#
# If the release already exists, its assets are replaced in place (--clobber).
# The script refuses to do that once an asset has been downloaded — cut a new
# version instead, so nobody ends up with two different files under one name.
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="LUVI Docs"
DIST_DIR="$REPO_ROOT/dist"

VERSION=""
DO_BUILD=1
DRAFT=0
PRERELEASE=0
UNIVERSAL_APK=0
ALLOW_DIRTY=0
RETAG=0
ASSUME_YES=0
NOTES_FILE=""

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    local reply=""
    if [ ! -r /dev/tty ]; then
        echo "no terminal available for the prompt \"$1\" — re-run with --yes" >&2
        return 1
    fi
    printf '%s [y/N] ' "$1"
    read -r reply < /dev/tty || return 1
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
    cat <<'EOF'
Options:
  --draft          create the release unpublished
  --prerelease     mark the release as a prerelease
  --skip-build     do not run flutter build, reuse build/ output
  --universal-apk  one fat APK instead of per-ABI APKs
  --retag          move an existing tag to HEAD (force pushes the tag)
  --allow-dirty    permit an unclean working tree
  --notes-file F   use F as the release body
  -y, --yes        do not prompt for confirmation
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --draft)         DRAFT=1 ;;
        --prerelease)    PRERELEASE=1 ;;
        --skip-build)    DO_BUILD=0 ;;
        --universal-apk) UNIVERSAL_APK=1 ;;
        --retag)         RETAG=1 ;;
        --allow-dirty)   ALLOW_DIRTY=1 ;;
        --notes-file)    NOTES_FILE="${2:-}"; shift ;;
        -y|--yes)        ASSUME_YES=1 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              die "unknown option: $1" ;;
        *)               [ -n "$VERSION" ] && die "version given twice"; VERSION="$1" ;;
    esac
    shift
done

# --- preflight -------------------------------------------------------------

log "Preflight"

command -v flutter >/dev/null || die "flutter not on PATH"
command -v gh >/dev/null      || die "gh not on PATH"
command -v tar >/dev/null     || die "tar not on PATH"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

PUBSPEC_VERSION="$(sed -n 's/^version: *\([0-9][^+]*\).*/\1/p' pubspec.yaml | head -1)"
[ -n "$PUBSPEC_VERSION" ] || die "could not read version from pubspec.yaml"

if [ -z "$VERSION" ]; then
    VERSION="$PUBSPEC_VERSION"
elif [ "$VERSION" != "$PUBSPEC_VERSION" ]; then
    warn "requested $VERSION but pubspec.yaml says $PUBSPEC_VERSION — bump pubspec first?"
    confirm "Continue anyway?" || exit 1
fi

TAG="v$VERSION"

if [ "$ALLOW_DIRTY" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
    git status --short
    die "working tree is not clean (use --allow-dirty to override)"
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
HEAD_SHA="$(git rev-parse HEAD)"

git fetch --quiet origin "$BRANCH" 2>/dev/null || true
if ! git merge-base --is-ancestor "$HEAD_SHA" "origin/$BRANCH" 2>/dev/null; then
    warn "HEAD is not on origin/$BRANCH yet — the tag would point at an unpushed commit"
    confirm "Push $BRANCH to origin now?" || die "aborted; push $BRANCH first"
    git push origin "$BRANCH"
fi

# What happens to the tag and to an existing release?
TAG_EXISTS=0
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && TAG_EXISTS=1

RELEASE_EXISTS=0
gh release view "$TAG" >/dev/null 2>&1 && RELEASE_EXISTS=1

if [ "$TAG_EXISTS" -eq 1 ]; then
    TAGGED_SHA="$(git rev-parse "$TAG^{}")"
    if [ "$TAGGED_SHA" != "$HEAD_SHA" ]; then
        if [ "$RETAG" -eq 1 ]; then
            warn "$TAG will be moved from ${TAGGED_SHA:0:8} to ${HEAD_SHA:0:8} (force push)"
        else
            die "$TAG exists at ${TAGGED_SHA:0:8} but HEAD is ${HEAD_SHA:0:8};
       use --retag to move it, or release a new version"
        fi
    fi
fi

if [ "$RELEASE_EXISTS" -eq 1 ]; then
    DOWNLOADED="$(gh release view "$TAG" --json assets \
        -q '[.assets[] | select(.downloadCount > 0) | "\(.name) (\(.downloadCount))"] | join(", ")')"
    if [ -n "$DOWNLOADED" ]; then
        die "release $TAG already has downloaded assets: $DOWNLOADED
       replacing them would hand different files to people under the same
       version — bump the version and release that instead"
    fi
    warn "release $TAG exists with no downloads yet; its assets will be replaced"
fi

echo "  app:      $APP_NAME $VERSION"
echo "  tag:      $TAG ($([ "$TAG_EXISTS" -eq 1 ] && echo "exists" || echo "new"))"
echo "  release:  $([ "$RELEASE_EXISTS" -eq 1 ] && echo "update existing" || echo "create new")"
echo "  commit:   ${HEAD_SHA:0:8} on $BRANCH"
echo "  repo:     $(gh repo view --json nameWithOwner -q .nameWithOwner)"
[ "$DRAFT" -eq 1 ] && echo "  draft:    yes"
confirm "Proceed?" || exit 1

# --- build -----------------------------------------------------------------

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

if [ "$DO_BUILD" -eq 1 ]; then
    log "Building Linux (x64 release)"
    flutter build linux --release

    log "Building Android APK"
    if [ "$UNIVERSAL_APK" -eq 1 ]; then
        flutter build apk --release
    else
        flutter build apk --release --split-per-abi
    fi
else
    warn "skipping build, using existing build/ output"
fi

# --- package linux ---------------------------------------------------------

log "Packaging Linux tarball"

BUNDLE="build/linux/x64/release/bundle"
[ -x "$BUNDLE/dms_client" ] || die "$BUNDLE/dms_client not found — run without --skip-build"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -a "$BUNDLE/." "$STAGE/"
cp linux/packaging/install.sh "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
cp assets/icon/icon.png "$STAGE/icon.png"

TARBALL="$DIST_DIR/dms_client-$VERSION-linux-x64.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" .
rm -rf "$STAGE"
trap - EXIT

# --- collect apks ----------------------------------------------------------

log "Collecting APKs"

APK_DIR="build/app/outputs/flutter-apk"
found_apk=0
if [ "$UNIVERSAL_APK" -eq 1 ]; then
    [ -f "$APK_DIR/app-release.apk" ] || die "$APK_DIR/app-release.apk not found"
    cp "$APK_DIR/app-release.apk" "$DIST_DIR/dms_client-$VERSION-android.apk"
    found_apk=1
else
    for abi in arm64-v8a armeabi-v7a x86_64; do
        src="$APK_DIR/app-$abi-release.apk"
        if [ -f "$src" ]; then
            cp "$src" "$DIST_DIR/dms_client-$VERSION-android-$abi.apk"
            found_apk=1
        else
            warn "missing $src"
        fi
    done
fi
[ "$found_apk" -eq 1 ] || die "no APKs found — run without --skip-build"

ls -lh "$DIST_DIR" | tail -n +2

# --- release notes ---------------------------------------------------------

if [ -n "$NOTES_FILE" ]; then
    [ -f "$NOTES_FILE" ] || die "notes file not found: $NOTES_FILE"
    NOTES_PATH="$NOTES_FILE"
else
    NOTES_PATH="$DIST_DIR/notes.md"
    cat > "$NOTES_PATH" <<EOF
$APP_NAME $VERSION

**Linux (x64)**

\`\`\`sh
tar -xzf dms_client-$VERSION-linux-x64.tar.gz
./install.sh            # installs into ~/.local, adds a GNOME launcher
sudo ./install.sh --system   # or system-wide into /opt
\`\`\`

Uninstall with \`./install.sh --uninstall\`.

**Android**

Install the APK matching your device — \`arm64-v8a\` for essentially every
phone from the last several years. Sideloading requires allowing installs
from unknown sources.
EOF
fi

# --- tag -------------------------------------------------------------------

log "Tagging $TAG"

if [ "$TAG_EXISTS" -eq 1 ] && [ "$RETAG" -eq 1 ]; then
    git tag -f -a "$TAG" -m "$APP_NAME $VERSION"
    git push --force origin "$TAG"
elif [ "$TAG_EXISTS" -eq 0 ]; then
    git tag -a "$TAG" -m "$APP_NAME $VERSION"
    git push origin "$TAG"
else
    echo "  tag already at HEAD, nothing to do"
fi

# --- publish ---------------------------------------------------------------

if [ "$RELEASE_EXISTS" -eq 1 ]; then
    log "Updating release $TAG"
    gh release upload "$TAG" "$DIST_DIR"/*.tar.gz "$DIST_DIR"/*.apk --clobber
    [ -n "$NOTES_FILE" ] && gh release edit "$TAG" --notes-file "$NOTES_PATH"
else
    log "Creating release $TAG"
    args=(--title "$APP_NAME $VERSION" --notes-file "$NOTES_PATH")
    [ "$DRAFT" -eq 1 ]      && args+=(--draft)
    [ "$PRERELEASE" -eq 1 ] && args+=(--prerelease)
    gh release create "$TAG" "${args[@]}" "$DIST_DIR"/*.tar.gz "$DIST_DIR"/*.apk
fi

log "Done"
gh release view "$TAG" --json url -q .url
