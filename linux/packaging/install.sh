#!/usr/bin/env bash
#
# LUVI Docs — Linux installer (Ubuntu / Fedora, GNOME and other freedesktop
# desktops). Run from the unpacked tarball:
#
#   ./install.sh              install for the current user (~/.local)
#   sudo ./install.sh --system   install for all users (/opt + /usr/share)
#   ./install.sh --uninstall  remove a previous install (add --system if it
#                             was a system-wide one)
#
set -euo pipefail

APP_NAME="LUVI Docs"
APP_ID="eu.luvifermente.dms_client"
BIN_NAME="dms_client"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

MODE="user"
ACTION="install"

usage() {
    cat <<EOF
$APP_NAME installer

Usage: $0 [--system|--user] [--uninstall] [--help]

  --user       install into \$HOME/.local (default, no root needed)
  --system     install into /opt and /usr/share (needs root)
  --uninstall  remove a previous install
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --system)    MODE="system" ;;
        --user)      MODE="user" ;;
        --uninstall) ACTION="uninstall" ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$MODE" = "system" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "--system needs root. Re-run with: sudo $0 --system" >&2
        exit 1
    fi
    APP_DIR="/opt/luvi-docs"
    BIN_DIR="/usr/local/bin"
    DESKTOP_DIR="/usr/share/applications"
    ICON_DIR="/usr/share/icons/hicolor"
else
    APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/luvi-docs"
    BIN_DIR="$HOME/.local/bin"
    DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
fi

DESKTOP_FILE="$DESKTOP_DIR/$APP_ID.desktop"

refresh_caches() {
    # Both are best-effort: GNOME picks the entry up either way, just later.
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f -t "$ICON_DIR" >/dev/null 2>&1 || true
    fi
}

remove_app_dir() {
    # Only ever delete a directory that actually looks like our install.
    if [ -d "$APP_DIR" ]; then
        if [ -x "$APP_DIR/$BIN_NAME" ]; then
            rm -rf "$APP_DIR"
        else
            echo "Refusing to delete $APP_DIR — it does not contain $BIN_NAME." >&2
            exit 1
        fi
    fi
}

if [ "$ACTION" = "uninstall" ]; then
    echo "Removing $APP_NAME ($MODE install)…"
    remove_app_dir
    rm -f "$BIN_DIR/$BIN_NAME"
    rm -f "$DESKTOP_FILE"
    rm -f "$ICON_DIR"/*/apps/"$APP_ID".png
    refresh_caches
    echo "Done."
    exit 0
fi

# --- checks ----------------------------------------------------------------

for f in "$BIN_NAME" lib data; do
    if [ ! -e "$SCRIPT_DIR/$f" ]; then
        echo "Missing '$f' next to install.sh — run this script from inside the" >&2
        echo "unpacked tarball, not from a copy of the script alone." >&2
        exit 1
    fi
done

# --- install ---------------------------------------------------------------

echo "Installing $APP_NAME to $APP_DIR…"

remove_app_dir
mkdir -p "$APP_DIR" "$BIN_DIR" "$DESKTOP_DIR"

# The Flutter bundle is position-independent (rpath is $ORIGIN/lib), so the
# binary, lib/ and data/ must stay together in one directory.
cp -a "$SCRIPT_DIR/$BIN_NAME" "$SCRIPT_DIR/lib" "$SCRIPT_DIR/data" "$APP_DIR/"
chmod +x "$APP_DIR/$BIN_NAME"

# $ORIGIN resolves through symlinks, so a plain symlink on PATH is enough.
ln -sfn "$APP_DIR/$BIN_NAME" "$BIN_DIR/$BIN_NAME"

if [ -f "$SCRIPT_DIR/icon.png" ]; then
    install -d "$ICON_DIR/512x512/apps"
    if command -v magick >/dev/null 2>&1; then
        magick "$SCRIPT_DIR/icon.png" -resize 512x512 "$ICON_DIR/512x512/apps/$APP_ID.png"
    elif command -v convert >/dev/null 2>&1; then
        convert "$SCRIPT_DIR/icon.png" -resize 512x512 "$ICON_DIR/512x512/apps/$APP_ID.png"
    else
        cp -f "$SCRIPT_DIR/icon.png" "$ICON_DIR/512x512/apps/$APP_ID.png"
    fi
    ICON_VALUE="$APP_ID"
else
    ICON_VALUE="application-x-executable"
fi

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
GenericName=Document Management
Comment=Client for the LUVI Fermente document management system
Exec=$APP_DIR/$BIN_NAME
Icon=$ICON_VALUE
Terminal=false
Categories=Office;
Keywords=DMS;Documents;Archive;
StartupNotify=true
StartupWMClass=$APP_ID
EOF
chmod 644 "$DESKTOP_FILE"

refresh_caches

echo
echo "$APP_NAME installed."
echo "  app:     $APP_DIR"
echo "  command: $BIN_DIR/$BIN_NAME"
echo "  launcher: $DESKTOP_FILE"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo
       echo "Note: $BIN_DIR is not on your PATH — the GNOME launcher works"
       echo "regardless, but '$BIN_NAME' from a terminal will not." ;;
esac

echo
echo "It may take a few seconds for GNOME to show it in the app grid."
if [ "$MODE" = "system" ]; then
    echo "Uninstall with: sudo $0 --uninstall --system"
else
    echo "Uninstall with: $0 --uninstall"
fi
