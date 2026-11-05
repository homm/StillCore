#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/compiled"

xcrun actool StillCore/Assets.xcassets StillCore/AppIcon.icon \
    --compile "$work_dir/compiled" \
    --output-format human-readable-text \
    --platform macosx --minimum-deployment-target 14.0 \
    --target-device mac --app-icon AppIcon --accent-color AccentColor \
    --output-partial-info-plist "$work_dir/icon-info.plist"

scripts/external/bin/scar decompile "$work_dir/compiled/Assets.car" --out "$work_dir/extracted"
xcrun swift scripts/compact-assets.swift "$work_dir/extracted/manifest.json"
scripts/external/bin/scar compile "$work_dir/extracted" --out "$work_dir/Assets.car"
xcrun assetutil --update-bitmap "$work_dir/Assets.car"
xcrun assetutil --validate-file "$work_dir/Assets.car"

mkdir -p assets
cp "$work_dir/Assets.car" assets/Assets.car
cp "$work_dir/compiled/AppIcon.icns" assets/AppIcon.icns
