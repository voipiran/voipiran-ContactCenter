#!/bin/bash

# ===============================================================
# VOIPIRAN ContactCenter Customizations
#
# This script runs AFTER the upstream install.sh.
#
# It applies only VOIPIRAN-specific changes.
# ===============================================================

set -e

PROJECT_ROOT="/opt/OpDesk"
PATCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ---------------------------------------------------------------
# Safety
# ---------------------------------------------------------------

if [ ! -d "$PROJECT_ROOT" ]; then
    echo -e "${RED}ERROR: $PROJECT_ROOT not found.${NC}"
    exit 1
fi

# ---------------------------------------------------------------
# Stop OpDesk if it happens to be running
# ---------------------------------------------------------------

if systemctl is-active --quiet opdesk.service 2>/dev/null; then
    echo -e "${YELLOW}Stopping OpDesk before applying changes...${NC}"
    systemctl stop opdesk.service
fi

# ===============================================================
# 1. Persian translation
# ===============================================================

echo -e "${YELLOW}Installing Persian translation...${NC}"

mkdir -p "$PROJECT_ROOT/frontend/src/i18n/locales/fa"

cp "$PATCH_ROOT/frontend/fa/translation.json" \
   "$PROJECT_ROOT/frontend/src/i18n/locales/fa/translation.json"

echo -e "${GREEN}Persian translation installed.${NC}"

# ===============================================================
# 2. English translation
# ===============================================================

echo -e "${YELLOW}Installing English translation...${NC}"

if [ -f "$PATCH_ROOT/frontend/en/translation.json" ]; then

    cp "$PATCH_ROOT/frontend/en/translation.json" \
       "$PROJECT_ROOT/frontend/src/i18n/locales/en/translation.json"

fi

echo -e "${GREEN}English translation installed.${NC}"

# ===============================================================
# 3. Configure i18n
# ===============================================================

I18N_FILE="$PROJECT_ROOT/frontend/src/i18n/index.ts"

if [ ! -f "$I18N_FILE" ]; then
    echo -e "${RED}ERROR: $I18N_FILE not found.${NC}"
    exit 1
fi

cp "$I18N_FILE" "$I18N_FILE.voipiran-backup"

python3 - "$I18N_FILE" <<'PY'
import sys
import re

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

# VOIPIRAN: Only English and Persian are supported.
text = re.sub(
    r"^\s*import\s+(ar|es|pt)\s+from\s+['\"]\.\/locales\/\1\/translation\.json['\"];\s*$",
    "",
    text,
    flags=re.MULTILINE
)

# VOIPIRAN: Supported languages.
text = re.sub(
    r"const\s+SUPPORTED_LANGUAGES\s*=\s*\[[^\]]*\]\s+as\s+const;",
    "const SUPPORTED_LANGUAGES = ['en', 'fa'] as const;",
    text
)

# VOIPIRAN: Persian is RTL.
if re.search(r"const\s+RTL_LANGUAGES", text):
    text = re.sub(
        r"const\s+RTL_LANGUAGES\s*=\s*\[[^\]]*\];",
        "const RTL_LANGUAGES = ['fa'];",
        text
    )
else:
    marker = "const SUPPORTED_LANGUAGES = ['en', 'fa'] as const;"

    text = text.replace(
        marker,
        "const RTL_LANGUAGES = ['fa'];\n" + marker
    )

# VOIPIRAN: Persian is the default language.
text = re.sub(
    r"(:\s*)'en';",
    r"\1'fa';",
    text,
    count=1
)

# VOIPIRAN: Use RTL list.
text = text.replace(
    "document.documentElement.dir = lang === 'ar' ? 'rtl' : 'ltr';",
    "document.documentElement.dir = RTL_LANGUAGES.includes(lang) ? 'rtl' : 'ltr';"
)

text = text.replace(
    "document.documentElement.dir = savedLang === 'ar' ? 'rtl' : 'ltr';",
    "document.documentElement.dir = RTL_LANGUAGES.includes(savedLang) ? 'rtl' : 'ltr';"
)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

echo -e "${GREEN}i18n configured.${NC}"

# ===============================================================
# 4. Language Menu
# ===============================================================

APP_FILE="$PROJECT_ROOT/frontend/src/App.tsx"

if [ ! -f "$APP_FILE" ]; then
    echo -e "${RED}ERROR: $APP_FILE not found.${NC}"
    exit 1
fi

cp "$APP_FILE" "$APP_FILE.voipiran-backup"

python3 - "$APP_FILE" <<'PY'
import sys
import re

path = sys.argv[1]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

pattern = r"const\s+LANGUAGE_OPTIONS\s*=\s*\[[^\]]*\]\s+as\s+const;"

if not re.search(pattern, text):
    print("ERROR: LANGUAGE_OPTIONS was not found.")
    sys.exit(1)

text = re.sub(
    pattern,
    "const LANGUAGE_OPTIONS = ['en', 'fa'] as const;",
    text
)

with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

echo -e "${GREEN}Language menu configured: English + Persian.${NC}"

# ===============================================================
# 5. ContactCenter title
# ===============================================================

INDEX_FILE="$PROJECT_ROOT/frontend/index.html"

if [ -f "$INDEX_FILE" ]; then

    cp "$INDEX_FILE" "$INDEX_FILE.voipiran-backup"

    sed -i \
        's/<title>OpDesk<\/title>/<title>ContactCenter<\/title>/g' \
        "$INDEX_FILE"

    echo -e "${GREEN}ContactCenter branding applied.${NC}"

fi




# ---------------------------------------------------------------
# VOIPIRAN: Install pre-built frontend
# The frontend is built on the development machine.
# The production server must NOT run npm build.
# ---------------------------------------------------------------

echo -e "${YELLOW}Installing pre-built frontend...${NC}"

PATCH_DIST="$PATCH_ROOT/frontend/dist"
PROJECT_DIST="$PROJECT_ROOT/frontend/dist"

if [ ! -f "$PATCH_DIST/index.html" ]; then
    echo -e "${RED}ERROR: Pre-built frontend not found in patch.${NC}"
    echo -e "${YELLOW}Expected:${NC} $PATCH_DIST/index.html"
    exit 1
fi

rm -rf "$PROJECT_DIST"
mkdir -p "$PROJECT_DIST"

cp -a "$PATCH_DIST/." "$PROJECT_DIST/"

echo -e "${GREEN}Pre-built frontend installed.${NC}"

# ===============================================================
# 7. Issabel database configuration
# ===============================================================

if [ -f /etc/issabel.conf ]; then

    echo -e "${YELLOW}Configuring Issabel database access...${NC}"

    ROOT_PASS=$(grep -E "^mysqlrootpwd[[:space:]]*=" /etc/issabel.conf \
        | head -1 \
        | cut -d'=' -f2- \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$ROOT_PASS" ]; then
        echo -e "${RED}ERROR: mysqlrootpwd not found in /etc/issabel.conf${NC}"
        exit 1
    fi

    ENV_FILE="$PROJECT_ROOT/backend/.env"

    if [ -f "$ENV_FILE" ]; then

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
        key = line.split("=", 1)[0]

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

    fi

fi

# ===============================================================
# 8. Nginx ports for Issabel
#
# VOIPIRAN:
#   HTTP  = 8080
#   HTTPS = 9001
#
# Issabel/Apache already owns standard web ports.
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

    mkdir -p /etc/nginx/conf.d

    ln -sfn \
        "$OPDESK_NGINX" \
        /etc/nginx/conf.d/opdesk.conf

fi

# ---------------------------------------------------------------
# Test Nginx before restarting
# ---------------------------------------------------------------

nginx -t

systemctl enable nginx
systemctl restart nginx

echo -e "${GREEN}Nginx configured.${NC}"
echo -e "${GREEN}HTTP  = 8080${NC}"
echo -e "${GREEN}HTTPS = 9001${NC}"

# ===============================================================
# 9. Backend ownership
# ===============================================================

if id nginx >/dev/null 2>&1; then

    chown -R nginx:nginx "$PROJECT_ROOT/backend"

    echo -e "${GREEN}Backend ownership set to nginx.${NC}"

fi

# ===============================================================
# 10. Do NOT start OpDesk
# ===============================================================

# ===============================================================
# 10. Do NOT start or enable OpDesk
# VOIPIRAN: OpDesk must not be started automatically by the installer.
# ===============================================================

systemctl daemon-reload

if systemctl list-unit-files 2>/dev/null | grep -q '^opdesk.service'; then
    systemctl disable opdesk.service 2>/dev/null || true
    systemctl stop opdesk.service 2>/dev/null || true
fi

echo
echo -e "${GREEN}===============================================================${NC}"
echo -e "${GREEN}VOIPIRAN customizations completed.${NC}"
echo -e "${GREEN}===============================================================${NC}"
echo
echo -e "${YELLOW}Frontend was NOT built.${NC}"
echo