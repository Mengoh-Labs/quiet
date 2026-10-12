#!/bin/bash
# The CLI is independently runnable; keep its resource bundles beside it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/build-environment.sh
swift build --cache-path "$PWD/.build/cache" -c release -j 2 --product quiet
quiet_bin_dir="$(swift build --cache-path "$PWD/.build/cache" -c release --show-bin-path)"
quiet_cli="$PWD/dist/quiet-cli"
mkdir -p "$quiet_cli"
cp "$quiet_bin_dir/quiet" "$quiet_cli/quiet"
for bundle in "$quiet_bin_dir"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    cp -R "$bundle" "$quiet_cli/"
done
if [[ -f "$quiet_bin_dir/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
    cp "$quiet_bin_dir/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$quiet_cli/mlx.metallib"
fi
bash scripts/package-licenses.sh "$quiet_cli"
codesign --force --sign - "$quiet_cli/quiet"
codesign --verify --strict "$quiet_cli/quiet"
printf '%s\n' "$quiet_cli/quiet"
