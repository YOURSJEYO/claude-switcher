#!/bin/bash
# Install a fully built app without deleting the previous version first.
set -euo pipefail
SOURCE="$1"
TARGET="${2:-/Applications/Claude切换器.app}"
PARENT="$(dirname "$TARGET")"
[[ -d "$SOURCE" && ! -L "$SOURCE" && -d "$PARENT" && ! -L "$TARGET" ]] || exit 1
codesign --verify --deep --strict "$SOURCE"
PRIV=(command)
if [ ! -w "$PARENT" ] || { [ -e "$TARGET" ] && [ ! -w "$TARGET" ]; }; then
    PRIV=(sudo)
fi
STAGED="$("${PRIV[@]}" mktemp -d "$PARENT/.claude-switcher-install.XXXXXX")"
cleanup() { "${PRIV[@]}" rm -rf "$STAGED"; }
trap cleanup EXIT
"${PRIV[@]}" ditto "$SOURCE" "$STAGED/app"
"${PRIV[@]}" codesign --verify --deep --strict "$STAGED/app"
BACKUP=""
if [ -e "$TARGET" ]; then
    BACKUP="$STAGED/previous"
    "${PRIV[@]}" mv "$TARGET" "$BACKUP"
fi
if ! "${PRIV[@]}" mv "$STAGED/app" "$TARGET"; then
    if [ -n "$BACKUP" ]; then
        "${PRIV[@]}" mv "$BACKUP" "$TARGET" || { trap - EXIT; echo "旧版保留在 $BACKUP，请手动恢复" >&2; exit 1; }
    fi
    exit 1
fi
if [ -n "$BACKUP" ]; then
    # Keep the previous bundle hidden, without .app suffix, for recovery.
    trap - EXIT
    "${PRIV[@]}" mv "$BACKUP" "$STAGED/previous-app"
    echo "旧版备份: $STAGED/previous-app"
else
    cleanup
    trap - EXIT
fi
