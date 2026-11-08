#!/usr/bin/env bash
# Packages the addon as dist/Utu-<version>.zip, ready to unzip into Interface/AddOns,
# plus dist/release.json (BigWigs packager format), which tells WowUp and other
# managers which game flavours the zip is for.
set -euo pipefail
cd "$(dirname "$0")"
version=$(sed -n 's/^## Version: *//p' Utu/Utu.toc | tr -d '\r')
interfaces=$(sed -n 's/^## Interface: *//p' Utu/Utu.toc | tr -d '\r ')
mkdir -p dist

# CHANGELOG.md is the one source for release notes: its top section must be
# this version. It becomes dist/notes.md (the GitHub release body, which WowUp
# shows as the changelog) and Utu/WhatsNew.lua (the in-game "What's new").
python3 - "$version" <<'PY'
import re, sys
version = sys.argv[1]
sections, cur = [], None
for line in open("CHANGELOG.md", encoding="utf-8"):
    m = re.match(r"^## (\d+\.\d+\.\d+)\s*$", line)
    if m:
        cur = (m.group(1), [])
        sections.append(cur)
    elif cur and line.startswith("- "):
        cur[1].append(line[2:].strip())
    elif cur and line.strip() and cur[1]:
        cur[1][-1] += " " + line.strip()  # wrapped bullet
if not sections or sections[0][0] != version:
    sys.exit(f"CHANGELOG.md: the top section is {sections[0][0] if sections else 'missing'}, "
             f"but Utu.toc says {version}; add a '## {version}' section first")
if not sections[0][1]:
    sys.exit(f"CHANGELOG.md: '## {version}' has no bullets")
with open("dist/notes.md", "w", encoding="utf-8") as f:
    f.write("".join(f"- {b}\n" for b in sections[0][1]))
def chat(s):  # markdown -> WoW chat text
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
    s = re.sub(r"\*\*(.+?)\*\*", r"|cffffd100\1|r", s)
    s = re.sub(r"(?<![\w*])\*(.+?)\*(?![\w*])", r"\1", s)
    return s.replace("`", "")
def lua(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
out = ["-- Generated from CHANGELOG.md by build.sh; edit that instead.",
       "local _, ns = ...", "ns.KOS.CHANGES = {"]
for v, bullets in sections:
    out.append(f'    {{ "{v}", {{')
    out += [f"        {lua(chat(b))}," for b in bullets]
    out.append("    } },")
out.append("}")
with open("Utu/WhatsNew.lua", "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(out) + "\n")
PY
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
