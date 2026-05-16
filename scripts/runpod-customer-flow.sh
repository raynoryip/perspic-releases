#!/usr/bin/env bash
# D-335 · Simulate a real customer's "I downloaded the installer + ran it" flow
# on a RunPod pod that already has the GUI desktop set up
# (see runpod-gui-bootstrap.sh).
#
# This script:
#   1. Fetches the latest Linux AppImage from the GitHub Release of
#      raynoryip/Perspic-Ohm-Studio (override via $RELEASE_TAG)
#   2. Makes it executable
#   3. Launches it on the current DISPLAY (which should be the VNC X server)
#
# Run this inside the noVNC desktop's terminal so the GUI appears in noVNC.
# If you run it over plain SSH you won't see anything — DISPLAY must be set.

set -euo pipefail

REPO="${REPO:-raynoryip/perspic-releases}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
DEST_DIR="${DEST_DIR:-$HOME/ohm-installer}"
DISPLAY="${DISPLAY:-:1}"

log() { printf '\n\033[1;36m[customer-flow]\033[0m %s\n' "$*"; }

mkdir -p "$DEST_DIR"
cd "$DEST_DIR"

# ─── 1. Resolve the AppImage download URL ─────────────────────────────────────
log "querying GitHub Release ($REPO @ $RELEASE_TAG) for the Linux AppImage"
if [[ "$RELEASE_TAG" == "latest" ]]; then
    API_URL="https://api.github.com/repos/$REPO/releases/latest"
else
    API_URL="https://api.github.com/repos/$REPO/releases/tags/$RELEASE_TAG"
fi

ASSET_URL=$(curl -sSL "$API_URL" \
    | grep -oE '"browser_download_url": "[^"]+\.AppImage"' \
    | head -n1 \
    | cut -d'"' -f4)

if [[ -z "${ASSET_URL:-}" ]]; then
    cat <<EOF >&2

ERROR: could not find an .AppImage asset in $REPO release $RELEASE_TAG.

Confirm the release has the Linux AppImage attached.
  • Tag exists?           gh release view $RELEASE_TAG --repo $REPO
  • Linux build complete? gh run list --workflow=release.yml --repo $REPO
  • Manual upload OK too: drag *.AppImage to the release page.

If you just kicked off CI: wait 8-15 min for ubuntu-22.04 runner to finish.
EOF
    exit 1
fi

APPIMAGE_NAME=$(basename "$ASSET_URL")
log "found: $APPIMAGE_NAME"
log "URL  : $ASSET_URL"

# ─── 2. Download (resumable) ──────────────────────────────────────────────────
log "downloading to $DEST_DIR/$APPIMAGE_NAME"
curl -L --fail --retry 3 --continue-at - \
    -o "$APPIMAGE_NAME" "$ASSET_URL"
chmod +x "$APPIMAGE_NAME"

size=$(stat -c%s "$APPIMAGE_NAME")
log "downloaded $(printf '%.1f' "$(echo "$size / 1048576" | bc -l)") MB"

# ─── 3. Sanity-check Linux deps for AppImage ──────────────────────────────────
log "checking libfuse2 (AppImages need this)"
if ! ldconfig -p | grep -q libfuse.so.2; then
    echo "WARN: libfuse2 not found. If launch fails, run:"
    echo "      apt-get install -y libfuse2"
fi

# ─── 4. Launch ────────────────────────────────────────────────────────────────
log "launching installer · DISPLAY=$DISPLAY"
log "GUI should appear inside your noVNC desktop in 2-5 seconds."
log "Log output goes to $DEST_DIR/installer.log"

export DISPLAY
nohup "./$APPIMAGE_NAME" > installer.log 2>&1 &
INST_PID=$!

cat <<EOF

══════════════════════════════════════════════════════════════════════════
  Ohm Studio installer launched · PID $INST_PID
  Log file : $DEST_DIR/installer.log
  Switch to your noVNC browser tab → the wizard window should be visible.

  Watch logs live:
     tail -f $DEST_DIR/installer.log

  Kill the installer (if needed):
     kill $INST_PID
══════════════════════════════════════════════════════════════════════════

EOF
