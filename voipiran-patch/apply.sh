#!/bin/bash

# ===============================================================
# VOIPIRAN ContactCenter - Production Apply Script
#
# IMPORTANT:
# Frontend is PRE-BUILT outside the production server.
# This script MUST NOT:
#   - run npm install
#   - run npm run build
#   - modify frontend source files
#
# Production flow:
#   Main OpDesk install.sh
#          ↓
#   apply.sh
#          ↓
#   Deploy pre-built frontend
#          ↓
#   Configure Issabel DB
#          ↓
#   Configure Nginx
#          ↓
#   Enable / start OpDesk
# ===============================================================

set -e

PROJECT_ROOT="/opt/OpDesk"
PATCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PACKAGE_ROOT="$(cd "$PATCH_ROOT/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo
echo -e "${BLUE}===============================================================${NC}"
echo -e "${BLUE}       Applying VOIPIRAN ContactCenter changes                ${NC}"
echo -e "${BLUE}===============================================================${NC}"
echo

# ===============================================================
# 1. Safety checks
# ===============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: apply.sh must be run as root.${NC}"
    exit 1
fi

if [ ! -d "$PROJECT_ROOT" ]; then
    echo -e "${RED}ERROR: OpDesk project not found:${NC}"
    echo "$PROJECT_ROOT"
    exit 1
fi

# ===============================================================
# 2. Stop OpDesk before deployment
# ===============================================================

if systemctl is-active --quiet opdesk.service 2>/dev/null; then
    echo -e "${YELLOW}Stopping OpDesk before applying changes...${NC}"
    systemctl stop opdesk.service
fi

# ===============================================================
# 3. Deploy PRE-BUILT frontend
#
# VOIPIRAN:
# The frontend MUST already be built before installation.
#
# No npm install.
# No npm run build.
# No TypeScript compilation.
# ===============================================================

echo -e "${YELLOW}Installing pre-built ContactCenter frontend...${NC}"

SOURCE_DIST="$PROJECT_PACKAGE_ROOT/frontend/dist"
PROJECT_DIST="$PROJECT_ROOT/frontend/dist"

if [ ! -f "$SOURCE_DIST/index.html" ]; then
    echo -e "${RED}ERROR: Pre-built frontend was not found.${NC}"
    echo
    echo "Expected:"
    echo "$SOURCE_DIST/index.html"
    echo
    echo "The frontend must be built outside the production server"
    echo "and the resulting dist/ must be included in the package."
    exit 1
fi

# Remove old frontend build
rm -rf "$PROJECT_DIST"

# Create destination
mkdir -p "$PROJECT_DIST"

# Copy pre-built frontend
cp -a "$SOURCE_DIST/." "$PROJECT_DIST/"

echo -e "${GREEN}Pre-built frontend installed successfully.${NC}"

# ===============================================================
# 4. Verify frontend deployment
# ===============================================================

if [ ! -f "$PROJECT_DIST/index.html" ]; then
    echo -e "${RED}ERROR: Frontend deployment failed.${NC}"
    exit 1
fi

ASSET_COUNT=$(find "$PROJECT_DIST/assets" -type f 2>/dev/null | wc -l || true)

echo -e "${GREEN}Frontend verification successful.${NC}"
echo "Frontend: $PROJECT_DIST"
echo "Assets:   $ASSET_COUNT files"

# ===============================================================
# 4a. VOIPIRAN safety patch: force LTR dial-pad key order
#
# The Persian/Arabic RTL UI mirrors the .softphone-dialpad CSS grid,
# which reverses the 1-2-3 dial-pad key order (shows 3-2-1). The real
# fix lives in frontend/src/styles/index.css
# (".softphone-dialpad { direction: ltr; }"), but that touches a core
# upstream file, so it can be lost if the source tree is re-fetched
# from the original project before rebuilding.
#
# This step re-applies the same fix directly to the already-deployed
# CSS bundle, so the dial pad keeps the correct key order even if the
# source-level patch was dropped. The number input intentionally inherits
# the application's RTL direction. It is idempotent (safe to run every
# install) and does nothing if the rule already contains the fix or the
# selector can no longer be found (e.g. renamed upstream).
# ===============================================================

echo -e "${YELLOW}Applying VOIPIRAN dialpad LTR safety patch...${NC}"

DIALPAD_CSS_FOUND=0

for css_file in "$PROJECT_DIST"/assets/*.css; do
    [ -f "$css_file" ] || continue

    if grep -q '\.softphone-dialpad{' "$css_file" 2>/dev/null; then
        DIALPAD_CSS_FOUND=1

        python3 - "$css_file" <<'PY'
import re
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    content = f.read()

def append_if_missing(match, required_props):
    body = match.group(1)
    normalized = body.replace(" ", "")
    missing = [prop for prop in required_props if prop.replace(" ", "") not in normalized]
    if not missing:
        return match.group(0)
    if not body.endswith(";"):
        body += ";"
    return match.group(0).split("{", 1)[0] + "{" + body + ";".join(missing) + "}"

new_content, _ = re.subn(
    r"\.softphone-dialpad\{([^}]*)\}",
    lambda m: append_if_missing(m, ["direction:ltr"]),
    content,
    count=1,
)

if new_content != content:
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)
PY
    fi
done

if [ "$DIALPAD_CSS_FOUND" -eq 1 ]; then
    echo -e "${GREEN}Dialpad LTR safety patch verified/applied.${NC}"
else
    echo -e "${YELLOW}Warning: .softphone-dialpad rule not found in deployed CSS (selector may have changed upstream).${NC}"
fi

# ===============================================================
# 5. Issabel database configuration
#
# VOIPIRAN:
# Use the existing Issabel MySQL/MariaDB root password.
# Database:
#   asterisk
# ===============================================================

echo -e "${YELLOW}Configuring Issabel database access...${NC}"

if [ -f /etc/issabel.conf ]; then

    ROOT_PASS=$(grep -E "^mysqlrootpwd[[:space:]]*=" /etc/issabel.conf \
        | head -1 \
        | cut -d'=' -f2- \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$ROOT_PASS" ]; then
        echo -e "${RED}ERROR: mysqlrootpwd not found in /etc/issabel.conf${NC}"
        exit 1
    fi

    ENV_FILE="$PROJECT_ROOT/backend/.env"

    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}ERROR: Backend .env not found:${NC}"
        echo "$ENV_FILE"
        exit 1
    fi

    cp "$ENV_FILE" "$ENV_FILE.voipiran-backup"

    python3 - "$ENV_FILE" "$ROOT_PASS" <<'PY'
import sys

path = sys.argv[1]
password = sys.argv[2]

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

values = {
    "DB_USER": "root",
    "DB_PASSWORD": password,
    "DB_NAME": "asterisk",
}

result = []
found = set()

for line in lines:

    if "=" in line:
        key = line.split("=", 1)[0].strip()

        if key in values:
            result.append(f"{key}={values[key]}\n")
            found.add(key)
            continue

    result.append(line)

for key, value in values.items():

    if key not in found:
        result.append(f"{key}={value}\n")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(result)
PY

    echo -e "${GREEN}Issabel database configuration applied.${NC}"


    # ===============================================================
    # VOIPIRAN WebRTC configuration
    # ===============================================================

    echo -e "${YELLOW}Configuring OpDesk WebRTC WebSocket endpoint...${NC}"

    SERVER_IP=$(hostname -I | awk '{print $1}')

    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}ERROR: Could not determine server IP.${NC}"
        exit 1
    fi

    WEBRTC_URL="wss://${SERVER_IP}:9001/sip-ws"

mysql -u root -p"$ROOT_PASS" -D OpDesk -e \
    "INSERT INTO OpDesk_settings (setting_key, setting_value)
     VALUES ('WEBRTC_PBX_SERVER', '$WEBRTC_URL')
     ON DUPLICATE KEY UPDATE setting_value='$WEBRTC_URL';"

    echo -e "${GREEN}WebRTC endpoint configured:${NC}"
    echo "$WEBRTC_URL"




else

    echo -e "${YELLOW}Warning: /etc/issabel.conf not found.${NC}"
    echo "Issabel database configuration was not modified."

fi

# ===============================================================
# 6. Nginx configuration
#
# VOIPIRAN:
#   HTTP  = 8080
#   HTTPS = 9001
#
# Issabel/Apache owns the standard web ports.
# ===============================================================

echo -e "${YELLOW}Configuring Nginx ports...${NC}"

NGINX_MAIN="/etc/nginx/nginx.conf"
NGINX_DEFAULT="/etc/nginx/conf.d/default.conf"
OPDESK_NGINX="$PROJECT_ROOT/nginx/opdesk.conf"

# ---------------------------------------------------------------
# Default Nginx HTTP port: 80 -> 8080
# ---------------------------------------------------------------

if [ -f "$NGINX_MAIN" ]; then

    sed -i \
        -e 's/listen[[:space:]]\+80 default_server;/listen 8080 default_server;/g' \
        -e 's/listen[[:space:]]\+\[::\]:80 default_server;/listen [::]:8080 default_server;/g' \
        "$NGINX_MAIN"

fi

if [ -f "$NGINX_DEFAULT" ]; then

    sed -i \
        -e 's/listen[[:space:]]\+80;/listen 8080;/g' \
        -e 's/listen[[:space:]]\+\[::\]:80;/listen [::]:8080;/g' \
        "$NGINX_DEFAULT"

fi

# ---------------------------------------------------------------
# ContactCenter Nginx configuration
# ---------------------------------------------------------------

if [ -f "$OPDESK_NGINX" ]; then

    cp "$OPDESK_NGINX" "$OPDESK_NGINX.voipiran-backup"

    sed -i \
        -e 's/listen[[:space:]]\+80[[:space:]]*;/listen 8080;/g' \
        -e 's/listen[[:space:]]\+\[::\]:80[[:space:]]*;/listen [::]:8080;/g' \
        -e 's/listen[[:space:]]\+443[[:space:]]\+ssl[[:space:]]*;/listen 9001 ssl;/g' \
        -e 's/listen[[:space:]]\+\[::\]:443[[:space:]]\+ssl[[:space:]]*;/listen [::]:9001 ssl;/g' \
        "$OPDESK_NGINX"


    # ---------------------------------------------------------------
    # VOIPIRAN WebRTC / Asterisk WebSocket
    #
    # Public:
    #   wss://SERVER_IP:9001/sip-ws
    #
    # Asterisk:
    #   https://127.0.0.1:8089/ws
    # ---------------------------------------------------------------

    # Asterisk HTTPS WebSocket
    sed -i \
        -e 's#proxy_pass http://asterisk_ws/ws;#proxy_pass https://asterisk_ws/ws;#g' \
        -e 's#upstream asterisk_ws { server 127.0.0.1:8088;#upstream asterisk_ws { server 127.0.0.1:8089;#g' \
        "$OPDESK_NGINX"

    # Add proxy_ssl_verify only if it does not already exist
    if ! grep -q 'proxy_ssl_verify off;' "$OPDESK_NGINX"; then
        sed -i \
            '/proxy_pass https:\/\/asterisk_ws\/ws;/a\        proxy_ssl_verify off;' \
            "$OPDESK_NGINX"
    fi

    echo -e "${GREEN}Asterisk WebSocket configured: HTTPS 8089/ws${NC}"

    mkdir -p /etc/nginx/conf.d

    ln -sfn \
        "$OPDESK_NGINX" \
        /etc/nginx/conf.d/opdesk.conf

else

    echo -e "${RED}ERROR: OpDesk Nginx configuration not found:${NC}"
    echo "$OPDESK_NGINX"
    exit 1

fi

# ---------------------------------------------------------------
# Test Nginx before restart
# ---------------------------------------------------------------

nginx -t

systemctl enable nginx
systemctl restart nginx

echo -e "${GREEN}Nginx configured successfully.${NC}"
echo -e "${GREEN}HTTP  = 8080${NC}"
echo -e "${GREEN}HTTPS = 9001${NC}"

# ===============================================================
# 7. Backend ownership
# ===============================================================

if id nginx >/dev/null 2>&1; then

    chown -R nginx:nginx "$PROJECT_ROOT/backend"

    echo -e "${GREEN}Backend ownership set to nginx.${NC}"

fi

# ===============================================================
# 8. OpDesk systemd service
#
# IMPORTANT:
# Do not disable the service here.
# install.sh creates/enables the service.
# apply.sh only makes sure it is enabled and starts it.
# ===============================================================

echo -e "${YELLOW}Configuring OpDesk service...${NC}"

systemctl daemon-reload

if systemctl list-unit-files 2>/dev/null | grep -q '^opdesk.service'; then

    systemctl enable opdesk.service

    echo -e "${GREEN}OpDesk service enabled.${NC}"

else

    echo -e "${RED}ERROR: opdesk.service was not found.${NC}"
    exit 1

fi

# ===============================================================
# 9. Start OpDesk
# ===============================================================

echo -e "${YELLOW}Starting OpDesk...${NC}"

systemctl start opdesk.service

sleep 2

if systemctl is-active --quiet opdesk.service; then

    echo -e "${GREEN}OpDesk service is running.${NC}"

else

    echo -e "${RED}ERROR: OpDesk service failed to start.${NC}"
    echo
    echo "Check:"
    echo "  systemctl status opdesk --no-pager -l"
    echo "  journalctl -u opdesk -n 100 --no-pager"
    exit 1

fi

# ===============================================================
# 10. Final verification
# ===============================================================

echo
echo -e "${BLUE}===============================================================${NC}"
echo -e "${BLUE}       VOIPIRAN ContactCenter deployment completed             ${NC}"
echo -e "${BLUE}===============================================================${NC}"
echo

echo -e "${GREEN}Frontend:${NC} pre-built"
echo -e "${GREEN}Build on server:${NC} NO"
echo -e "${GREEN}npm install:${NC} NO"
echo -e "${GREEN}npm run build:${NC} NO"
echo -e "${GREEN}Language source modification:${NC} NO"
echo -e "${GREEN}Nginx HTTP:${NC} 8080"
echo -e "${GREEN}Nginx HTTPS:${NC} 9001"
echo -e "${GREEN}OpDesk:${NC} running"
echo