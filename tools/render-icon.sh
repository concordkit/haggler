#!/bin/sh
# Renders the AddOns-list icon from tools/icons/lucide-handshake.svg:
# gold on transparent, since the list can't tint. Safe to run again.
# Needs rsvg-convert (brew install librsvg).
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ICON_COLOUR='#e8c25a'
ICON_SIZE=128
SOURCE_SVG="$REPO_ROOT/tools/icons/lucide-handshake.svg"
TARGET_PNG="$REPO_ROOT/media/icon.png"

mkdir -p "$(dirname "$TARGET_PNG")"
sed "s/currentColor/$ICON_COLOUR/g" "$SOURCE_SVG" |
	rsvg-convert --width "$ICON_SIZE" --height "$ICON_SIZE" --output "$TARGET_PNG"
echo "lucide-handshake -> media/icon.png"
