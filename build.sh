#!/usr/bin/env bash
# Packages the addon as dist/KillOnSight-<version>.zip, ready to unzip into Interface/AddOns.
set -euo pipefail
cd "$(dirname "$0")"
version=$(sed -n 's/^## Version: *//p' KillOnSight/KillOnSight.toc | tr -d '\r')
mkdir -p dist
out="dist/KillOnSight-${version}.zip"
rm -f "$out"
if command -v zip >/dev/null; then
    zip -qr "$out" KillOnSight
else
    python3 -c 'import shutil,sys; shutil.make_archive(sys.argv[1][:-4], "zip", ".", "KillOnSight")' "$out"
fi
echo "$out"
