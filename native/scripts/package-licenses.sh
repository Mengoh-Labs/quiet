#!/bin/bash
# Copy notices verbatim into an already-created app Resources or CLI directory.
set -euo pipefail
quiet_license_root="$(cd "$(dirname "$0")/../.." && pwd)"
quiet_license_output="${1:?resource destination required}"
mkdir -p "$quiet_license_output"
for quiet_license_name in LICENSE LICENSE-ASSETS.md LICENSE-ARTWORK THIRD_PARTY_NOTICES.md; do
    cp "$quiet_license_root/$quiet_license_name" "$quiet_license_output/"
done
if [[ ! -d "$quiet_license_root/LICENSES" ]]; then
    echo 'Missing LICENSES dependency notices directory' >&2
    exit 1
fi
mkdir -p "$quiet_license_output/LICENSES"
cp -R "$quiet_license_root/LICENSES/." "$quiet_license_output/LICENSES/"
