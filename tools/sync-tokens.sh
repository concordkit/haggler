#!/usr/bin/env bash
# Copies the Concord design system's Lua tokens into Host/Tokens.lua under Haggler's addon
# namespace (ns.Tokens), so Haggler never writes or reads the Concord_Tokens global and cannot
# clash with Concord. The design system itself is never changed.
#
# Usage: tools/sync-tokens.sh [path/to/Concord_Tokens.lua]
set -euo pipefail

DEFAULT_SOURCE="$HOME/Vaults/Personal/_resources/Concord/mockups/design-system/dist/Concord_Tokens.lua"
SOURCE="${1:-$DEFAULT_SOURCE}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/Host/Tokens.lua"

if [[ ! -f "$SOURCE" ]]; then
	echo "sync-tokens: source not found: $SOURCE" >&2
	exit 1
fi

# The source must assign the global exactly once, at the start of a line.
assignments="$(grep -c '^Concord_Tokens = {' "$SOURCE" || true)"
references="$(grep -c 'Concord_Tokens' "$SOURCE" || true)"
if [[ "$assignments" != "1" || "$references" != "1" ]]; then
	echo "sync-tokens: expected one 'Concord_Tokens = {' and no other use of the global;" \
		"found $assignments assignment(s), $references reference(s). Update this script." >&2
	exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
{
	echo '-- GENERATED FILE, DO NOT EDIT. Run tools/sync-tokens.sh to refresh it.'
	echo '-- Source: the Concord design system (_resources/Concord/mockups/design-system/dist/Concord_Tokens.lua),'
	echo '-- with the Concord_Tokens global moved into the addon namespace as ns.Tokens.'
	echo 'local _, ns = ...'
	echo
	sed -E -e 's/^Concord_Tokens = \{/ns.Tokens = {/' "$SOURCE"
} >"$tmp"

if grep -q 'Concord_Tokens\s*=' "$tmp"; then
	echo 'sync-tokens: the global assignment survived the rewrite' >&2
	exit 1
fi
if command -v luajit >/dev/null; then
	luajit -e "local chunk = assert(loadfile('$tmp')); local ns = {}; chunk('Haggler', ns); assert(type(ns.Tokens) == 'table' and ns.Tokens.version, 'no tokens'); assert(rawget(_G, 'Concord_Tokens') == nil, 'global leaked')"
fi

mv "$tmp" "$TARGET"
trap - EXIT
echo "sync-tokens: wrote $TARGET"
