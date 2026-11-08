#!/usr/bin/env bash
# Packages the addon as dist/Utu-<version>.zip, ready to unzip into Interface/AddOns,
# plus dist/release.json (BigWigs packager format), which tells WowUp and other
# managers which game flavours the zip is for.
set -euo pipefail
cd "$(dirname "$0")"
version=$(sed -n 's/^## Version: *//p' Utu/Utu.toc | tr -d '\r')
interfaces=$(sed -n 's/^## Interface: *//p' Utu/Utu.toc | tr -d '\r ')
mkdir -p dist
zipname="Utu-${version}.zip"
out="dist/${zipname}"
rm -f "$out"
if command -v zip >/dev/null; then
    zip -qr "$out" Utu
else
    python3 -c 'import shutil,sys; shutil.make_archive(sys.argv[1][:-4], "zip", ".", "Utu")' "$out"
fi
# 1.x.x interfaces 1xxxx: 16xxx is WoW: Forever, 11xxx is Classic Era.
python3 - "$zipname" "$interfaces" > dist/release.json <<'PY'
import json, sys
name, interfaces = sys.argv[1], [int(i) for i in sys.argv[2].split(",") if i]
def flavor(i):
    if 16000 <= i < 17000: return "forever"
    if 11000 <= i < 12000: return "classic"
    if i >= 100000: return "mainline"
    raise SystemExit(f"unknown interface {i}")
print(json.dumps({"releases": [{"filename": name, "nolib": False,
    "metadata": [{"flavor": flavor(i), "interface": i} for i in interfaces]}]}, indent=2))
PY
echo "$out"
