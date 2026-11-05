#!/bin/sh
# Render web/icon.svg to the PNGs iOS/Android want. iOS rounds corners itself,
# so the PNGs are drawn full-bleed (corner radius removed).
set -e
cd "$(dirname "$0")/../web"
sed -E 's/rx="11[46](\.5)?"/rx="0"/g' icon.svg > /tmp/pocketpi-icon-square.svg
for s in 180 512; do rsvg-convert -w $s -h $s /tmp/pocketpi-icon-square.svg -o icon-$s.png; done
rm /tmp/pocketpi-icon-square.svg
