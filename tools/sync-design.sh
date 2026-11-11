#!/usr/bin/env bash
# Copies the Concord design system's Haggler target into the add-on:
#   dist/haggler/Tokens.lua -> Host/Tokens.lua   (sets ns.Tokens; no global, so no clash with Concord)
#   dist/icons/*            -> media/icons/      (atlas PNGs per stroke weight, Icons.lua manifest, LICENSES/)
# The design system itself is never changed. Both copies are checked before anything is replaced.
#
# Usage: tools/sync-design.sh [path/to/design-system/dist]
set -euo pipefail

DEFAULT_DIST="$HOME/Vaults/Personal/_resources/Concord/mockups/design-system/dist"
DIST="${1:-$DEFAULT_DIST}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKENS_SOURCE="$DIST/haggler/Tokens.lua"
ICONS_SOURCE="$DIST/icons"

fail() {
	echo "sync-design: $*" >&2
	exit 1
}

[[ -f "$TOKENS_SOURCE" ]] || fail "tokens not found: $TOKENS_SOURCE"
[[ -f "$ICONS_SOURCE/Icons.lua" ]] || fail "icon manifest not found: $ICONS_SOURCE/Icons.lua"
[[ -d "$ICONS_SOURCE/LICENSES" ]] || fail "icon licences not found: $ICONS_SOURCE/LICENSES"

# Both generated files must write into the add-on namespace and never assign a global.
for file in "$TOKENS_SOURCE" "$ICONS_SOURCE/Icons.lua"; do
	if grep -qE '^(Concord_Tokens|Concord_Icons)[[:space:]]*=' "$file"; then
		fail "$file assigns a global; the Haggler target must not"
	fi
	grep -q '^local _, ns = \.\.\.' "$file" || fail "$file does not read the add-on namespace"
done
if command -v luajit >/dev/null; then
	luajit -e "
		local ns = {}
		assert(loadfile('$TOKENS_SOURCE'))('Haggler', ns)
		assert(type(ns.Tokens) == 'table' and ns.Tokens.version, 'no tokens')
		assert(loadfile('$ICONS_SOURCE/Icons.lua'))('Haggler', ns)
		assert(type(ns.Icons) == 'table' and type(ns.Icons.texcoords) == 'table', 'no icon texcoords')
		assert(ns.Icons.texcoords['alert-triangle'], 'no alert-triangle icon')
		assert(rawget(_G, 'Concord_Tokens') == nil and rawget(_G, 'Concord_Icons') == nil, 'global leaked')
	"
fi

cp "$TOKENS_SOURCE" "$REPO_ROOT/Host/Tokens.lua"
rm -rf "$REPO_ROOT/media/icons"
mkdir -p "$REPO_ROOT/media/icons"
cp -R "$ICONS_SOURCE/." "$REPO_ROOT/media/icons/"
echo "sync-design: wrote Host/Tokens.lua and media/icons/"
