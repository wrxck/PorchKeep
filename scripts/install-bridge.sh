#!/usr/bin/env bash
# install-bridge.sh — installs Node, eufy-security-ws, and ffmpeg into
# Resources/ so they can be bundled inside PorchKeep.app.
#
# Bundles the *official* node tarball from nodejs.org, which ships with its
# dylibs in lib/ and a working @loader_path RPATH — unlike Homebrew's node,
# which links to /usr/local/opt/... at runtime.
#
# Re-runnable: it skips work that's already done.

set -euo pipefail

NODE_VERSION="${NODE_VERSION:-v22.11.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
BRIDGE="$RES/bridge"
NODE_DIR="$BRIDGE/node"

mkdir -p "$BRIDGE"

# 1. Bundle Node from nodejs.org --------------------------------------------
if [[ ! -x "$NODE_DIR/bin/node" ]]; then
    ARCH="$(uname -m)"
    case "$ARCH" in
        arm64|aarch64) NODE_ARCH="arm64" ;;
        x86_64) NODE_ARCH="x64" ;;
        *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
    esac
    TARBALL="node-${NODE_VERSION}-darwin-${NODE_ARCH}.tar.gz"
    URL="https://nodejs.org/dist/${NODE_VERSION}/${TARBALL}"
    TMP="$(mktemp -d)"
    echo "==> Downloading $URL"
    curl -fL "$URL" -o "$TMP/$TARBALL"
    tar -xzf "$TMP/$TARBALL" -C "$TMP"
    EXTRACTED="$TMP/node-${NODE_VERSION}-darwin-${NODE_ARCH}"
    mkdir -p "$NODE_DIR"
    # Keep only the directories we actually need at runtime.
    cp -R "$EXTRACTED/bin" "$NODE_DIR/bin"
    cp -R "$EXTRACTED/lib" "$NODE_DIR/lib"
    # Trim niceties we don't need: npm, npx, corepack, docs, include headers.
    rm -rf "$NODE_DIR/bin/npm" "$NODE_DIR/bin/npx" "$NODE_DIR/bin/corepack" 2>/dev/null || true
    # npm itself lives in lib/node_modules — keep nothing in there at runtime.
    rm -rf "$NODE_DIR/lib/node_modules" 2>/dev/null || true
    rm -rf "$TMP"
else
    echo "==> Bundled node already present at $NODE_DIR/bin/node"
fi

# 2. Install eufy-security-ws -----------------------------------------------
PKG_JSON="$BRIDGE/package.json"
if [[ ! -f "$PKG_JSON" ]]; then
    cat > "$PKG_JSON" <<'JSON'
{
  "name": "porchkeep-bridge",
  "private": true,
  "version": "0.1.0",
  "dependencies": {
    "eufy-security-ws": "^2.1.0"
  }
}
JSON
fi

if [[ ! -d "$BRIDGE/node_modules/eufy-security-ws" ]]; then
    echo "==> Installing eufy-security-ws via npm (this can take a minute)…"
    NPM_CACHE="$BRIDGE/.npm-cache"
    mkdir -p "$NPM_CACHE"
    # npm at install time can be the system one — we only need node at runtime.
    (cd "$BRIDGE" && npm install --cache "$NPM_CACHE" --no-audit --no-fund --prefer-offline --omit=dev)
    rm -rf "$NPM_CACHE"
else
    echo "==> eufy-security-ws already installed"
fi

# 3. Bundle ffmpeg -----------------------------------------------------------
if [[ ! -x "$RES/ffmpeg" ]]; then
    SYS_FFMPEG="$(command -v ffmpeg || true)"
    if [[ -z "$SYS_FFMPEG" ]]; then
        echo "ERROR: ffmpeg not found on PATH. brew install ffmpeg, then re-run." >&2
        exit 1
    fi
    echo "==> Copying ffmpeg from $SYS_FFMPEG"
    cp "$SYS_FFMPEG" "$RES/ffmpeg"
    chmod +x "$RES/ffmpeg"
else
    echo "==> ffmpeg already bundled at $RES/ffmpeg"
fi

echo
echo "Bundle ready."
echo "  node      : $NODE_DIR/bin/node ($($NODE_DIR/bin/node --version 2>/dev/null || echo '?'))"
echo "  bridge    : $BRIDGE/node_modules/eufy-security-ws"
echo "  ffmpeg    : $RES/ffmpeg"
