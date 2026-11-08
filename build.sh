#!/usr/bin/env bash
# Packages the addon as dist/Utu-<version>.zip, ready to unzip into Interface/AddOns.
set -euo pipefail
cd "$(dirname "$0")"
version=$(sed -n 's/^## Version: *//p' Utu/Utu.toc | tr -d '\r')
mkdir -p dist
out="dist/Utu-${version}.zip"
rm -f "$out"
if command -v zip >/dev/null; then
    zip -qr "$out" Utu
else
    python3 -c 'import shutil,sys; shutil.make_archive(sys.argv[1][:-4], "zip", ".", "Utu")' "$out"
fi
echo "$out"
