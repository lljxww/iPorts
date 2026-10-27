#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
release_tag="${1:?Usage: bash scripts/create-release.sh v1.2.3}"
release_version="$(python3 scripts/release.py validate-tag "$release_tag")"
release_repository="${GITHUB_REPOSITORY:-lljxww/iPorts}"
if [[ ! "$release_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf 'Invalid GitHub repository: %s\n' "$release_repository" >&2
    exit 1
fi

IPORTS_VERSION="$release_version" bash scripts/build-app.sh release universal
release_dir="$repo_dir/build/release-$release_tag"
mkdir -p "$release_dir"
archive_name="iPorts-$release_version-macos-universal.zip"
cp build/iPorts-macos-universal.zip "$release_dir/$archive_name"
release_url="https://github.com/$release_repository/releases/tag/$release_tag"
printf 'iPorts %s\n\n版本更新内容：%s\n' "$release_version" "$release_url" > "$release_dir/${archive_name%.zip}.txt"

sparkle_tools="$repo_dir/.build/artifacts/sparkle/Sparkle/bin"
appcast_arguments=(
    --download-url-prefix "https://github.com/$release_repository/releases/download/$release_tag/"
    --full-release-notes-url "$release_url"
    --link "https://github.com/$release_repository"
    --embed-release-notes
    --maximum-deltas 0
    --maximum-versions 1
)
# Always regenerate the signed feed so retries never reuse signatures for an earlier ZIP.
python3 - "$release_dir/appcast.xml" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).unlink(missing_ok=True)
PY
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_tools/generate_appcast" --ed-key-file - "${appcast_arguments[@]}" "$release_dir"
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_tools/sign_update" --ed-key-file - --verify "$release_dir/appcast.xml"
else
    "$sparkle_tools/generate_appcast" --account lljxww.iPorts "${appcast_arguments[@]}" "$release_dir"
    "$sparkle_tools/sign_update" --account lljxww.iPorts --verify "$release_dir/appcast.xml"
fi

(
    cd "$release_dir"
    shasum -a 256 "$archive_name" appcast.xml > SHA256SUMS
)
printf 'Verified release artifacts: %s\n' "$release_dir"
