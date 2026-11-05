#!/bin/sh
set -eu

if ! git diff --cached --quiet -- StillCore/Assets.xcassets StillCore/AppIcon.icon; then
    if git diff --cached --quiet -- assets/Assets.car; then
        echo 'Asset sources changed without assets/Assets.car. Run make assets and stage the generated resources.' >&2
        exit 1
    fi
    if ! git cat-file -e :assets/Assets.car; then
        echo 'assets/Assets.car must be present in the commit.' >&2
        exit 1
    fi
fi
