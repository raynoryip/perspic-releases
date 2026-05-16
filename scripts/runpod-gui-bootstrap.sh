#!/usr/bin/env bash
# D-335 · RunPod A6000 GUI bootstrap
#
# Turns a fresh `runpod/pytorch:*-cuda*-ubuntu22.04` (or similar) into a
# noVNC-accessible XFCE desktop in ~2-3 minutes. After this finishes you open
# the RunPod proxy URL on port 6080 in your laptop browser and you see a real
# Ubuntu desktop with terminal — exactly what a customer would see.
#
# Then you can:
#   - Open Firefox / xterm
#   - wget the Ohm Studio AppImage from GitHub Release
#   - Double-click → see the actual installer GUI live
#
# Run inside the RunPod pod (via Web Terminal or SSH):
#   curl -sSL https://raw.githubusercontent.com/raynoryip/perspic-releases/main/scripts/runpod-gui-bootstrap.sh | bash
# OR:
#   bash runpod-gui-bootstrap.sh

set -euo pipefail

VNC_PASS="${VNC_PASS:-perspic}"  # NOT for production; this pod is ephemeral
VNC_PORT=5901
NOVNC_PORT=6080
DISPLAY_NUM=1
SCREEN_GEOM="${SCREEN_GEOM:-1600x1000x24}"

log() { printf '\n\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }

# ─── 1. apt deps ──────────────────────────────────────────────────────────────
log "installing xfce4 + tigervnc + websockify + noVNC + tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    xfce4 xfce4-terminal dbus-x11 \
    tigervnc-standalone-server tigervnc-common \
    websockify novnc \
    fonts-dejavu-core fonts-noto-cjk \
    curl wget ca-certificates \
    libfuse2 file desktop-file-utils \
    libwebkit2gtk-4.1-0 libjavascriptcoregtk-4.1-0 libsoup-3.0-0 \
    libayatana-appindicator3-1 libgtk-3-0 \
    nano less procps \
    >/dev/null

# Optional: install firefox via apt if needed for testing
apt-get install -y -qq --no-install-recommends firefox-esr 2>/dev/null \
  || apt-get install -y -qq --no-install-recommends firefox 2>/dev/null \
  || log "firefox not in default repos — skip (you can install via snap if needed)"

# ─── 2. VNC password (best-effort; fall back to -SecurityTypes None) ─────────
log "configuring VNC auth"
mkdir -p ~/.vnc
VNC_AUTH_TYPE="VncAuth"
if command -v vncpasswd >/dev/null 2>&1; then
    echo "$VNC_PASS" | vncpasswd -f > ~/.vnc/passwd 2>/dev/null
    chmod 600 ~/.vnc/passwd 2>/dev/null
    log "  vncpasswd OK · auth=VncAuth · password=${VNC_PASS}"
else
    log "  vncpasswd binary not found in PATH; falling back to -SecurityTypes None (ok for ephemeral RunPod test pods · do NOT use this in customer machines)"
    VNC_AUTH_TYPE="None"
fi

# ─── 3. xstartup — launch XFCE on VNC display :1 ─────────────────────────────
cat > ~/.vnc/xstartup <<'XEOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
xrdb $HOME/.Xresources 2>/dev/null || true
xsetroot -solid grey 2>/dev/null || true
startxfce4 &
XEOF
chmod +x ~/.vnc/xstartup

# ─── 4. start TigerVNC ────────────────────────────────────────────────────────
log "killing any old VNC session"
vncserver -kill ":${DISPLAY_NUM}" 2>/dev/null || true
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM}

log "starting TigerVNC on :${DISPLAY_NUM} (port ${VNC_PORT}, geometry ${SCREEN_GEOM}, auth ${VNC_AUTH_TYPE})"
USER=${USER:-root} vncserver ":${DISPLAY_NUM}" \
    -geometry "${SCREEN_GEOM%x*}" \
    -depth "${SCREEN_GEOM##*x}" \
    -localhost no \
    -SecurityTypes "${VNC_AUTH_TYPE}" \
    -rfbport "${VNC_PORT}"

# ─── 5. start websockify (browser → VNC bridge) ──────────────────────────────
log "starting websockify on port ${NOVNC_PORT} (browser entrypoint)"
pkill -f "websockify.*${NOVNC_PORT}" 2>/dev/null || true
mkdir -p /var/log
nohup websockify --web=/usr/share/novnc/ \
    "${NOVNC_PORT}" "localhost:${VNC_PORT}" \
    > /var/log/websockify.log 2>&1 &
sleep 1

# ─── 6. summary ───────────────────────────────────────────────────────────────
cat <<EOF

══════════════════════════════════════════════════════════════════════════
  RunPod GUI ready.

  In the RunPod web UI, look at your pod's "Connect" panel and find the
  proxied URL for port ${NOVNC_PORT}. It will look like:

     https://<pod-id>-${NOVNC_PORT}.proxy.runpod.net/

  Open it in your laptop browser. You'll see a TigerVNC login screen —
  paste the password below.

  VNC password : ${VNC_PASS}
  VNC display  : :${DISPLAY_NUM}  (raw port ${VNC_PORT}, noVNC HTTP ${NOVNC_PORT})
  Geometry     : ${SCREEN_GEOM}

  Once you're in the desktop, open a terminal (Applications → Terminal)
  and run:
     bash <(curl -sSL https://raw.githubusercontent.com/raynoryip/perspic-releases/main/scripts/runpod-customer-flow.sh)

  That will download the Ohm Studio AppImage from the GitHub Release and
  launch the installer GUI inside this desktop — exactly what a customer
  would do.
══════════════════════════════════════════════════════════════════════════

EOF
