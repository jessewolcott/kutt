#!/usr/bin/env bash
# =============================================================================
# Kutt - OIDC (OpenID Connect) Configuration Script
# =============================================================================
# Configures Kutt to authenticate users via an OIDC provider such as:
#   - Keycloak, Authentik, Authelia
#   - Google, Microsoft Entra ID (Azure AD), Okta
#   - Any standard OIDC-compliant identity provider
#
# Usage: sudo bash configure-oidc.sh
# =============================================================================

set -euo pipefail

# ---------- Colors & helpers -------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
die()   { err "$*"; exit 1; }

# ---------- Pre-flight checks -----------------------------------------------
[[ $EUID -ne 0 ]] && die "This script must be run as root (use sudo)."

INSTALL_DIR="/opt/kutt"
ENV_FILE="${INSTALL_DIR}/.env"

[[ ! -d "$INSTALL_DIR" ]] && die "Kutt installation not found at ${INSTALL_DIR}. Run install.sh first."
[[ ! -f "$ENV_FILE" ]] && die ".env file not found at ${ENV_FILE}."

# ---------- Gather OIDC configuration ----------------------------------------
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Kutt - OIDC Configuration             ${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Detect if OIDC is already configured
if grep -q "^OIDC_ENABLED=true" "$ENV_FILE" 2>/dev/null; then
    warn "OIDC is already enabled in ${ENV_FILE}."
    read -rp "Reconfigure? [y/N]: " RECONF
    [[ "${RECONF,,}" != "y" ]] && { info "Exiting."; exit 0; }
fi

# Provider hints
echo "Common OIDC issuer URLs:"
echo "  Keycloak:    https://keycloak.example.com/realms/your-realm"
echo "  Authentik:   https://auth.example.com/application/o/your-app/"
echo "  Authelia:    https://auth.example.com"
echo "  Google:      https://accounts.google.com"
echo "  Microsoft:   https://login.microsoftonline.com/{tenant-id}/v2.0"
echo "  Okta:        https://your-org.okta.com"
echo ""

read -rp "OIDC Issuer URL: " OIDC_ISSUER
[[ -z "$OIDC_ISSUER" ]] && die "Issuer URL is required."

# Strip trailing slash
OIDC_ISSUER="${OIDC_ISSUER%/}"

read -rp "OIDC Client ID: " OIDC_CLIENT_ID
[[ -z "$OIDC_CLIENT_ID" ]] && die "Client ID is required."

read -rsp "OIDC Client Secret: " OIDC_CLIENT_SECRET
echo ""
[[ -z "$OIDC_CLIENT_SECRET" ]] && die "Client Secret is required."

read -rp "OIDC Scopes (default: openid profile email): " OIDC_SCOPE
OIDC_SCOPE="${OIDC_SCOPE:-openid profile email}"

read -rp "Email claim field name (default: email): " OIDC_EMAIL_CLAIM
OIDC_EMAIL_CLAIM="${OIDC_EMAIL_CLAIM:-email}"

echo ""
echo "Login form options:"
echo "  1) Keep email/password login alongside OIDC"
echo "  2) Disable email/password login (OIDC only)"
read -rp "Choose [1/2] (default: 1): " LOGIN_FORM_CHOICE
LOGIN_FORM_CHOICE="${LOGIN_FORM_CHOICE:-1}"

DISALLOW_LOGIN_FORM="false"
[[ "$LOGIN_FORM_CHOICE" == "2" ]] && DISALLOW_LOGIN_FORM="true"

# ---------- Summary ----------------------------------------------------------
echo ""
info "Configuration summary:"
echo "  Issuer:        $OIDC_ISSUER"
echo "  Client ID:     $OIDC_CLIENT_ID"
echo "  Client Secret: ********"
echo "  Scopes:        $OIDC_SCOPE"
echo "  Email claim:   $OIDC_EMAIL_CLAIM"
echo "  Login form:    $([ "$DISALLOW_LOGIN_FORM" == "true" ] && echo "Disabled (OIDC only)" || echo "Enabled")"
echo ""
read -rp "Apply this configuration? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
[[ "${CONFIRM,,}" != "y" ]] && die "Configuration cancelled."

# ---------- Update .env file -------------------------------------------------
info "Updating ${ENV_FILE}..."

# Remove any existing OIDC and DISALLOW_LOGIN_FORM lines
sed -i '/^# OIDC/d' "$ENV_FILE"
sed -i '/^OIDC_/d' "$ENV_FILE"
sed -i '/^DISALLOW_LOGIN_FORM/d' "$ENV_FILE"

# Append new OIDC configuration
cat >> "$ENV_FILE" <<ENVEOF

# OIDC - configured on $(date)
OIDC_ENABLED=true
OIDC_ISSUER=${OIDC_ISSUER}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
OIDC_SCOPE=${OIDC_SCOPE}
OIDC_EMAIL_CLAIM=${OIDC_EMAIL_CLAIM}
DISALLOW_LOGIN_FORM=${DISALLOW_LOGIN_FORM}
ENVEOF

chmod 600 "$ENV_FILE"
ok ".env updated."

# ---------- Restart Kutt -----------------------------------------------------
info "Restarting Kutt..."
if systemctl is-active --quiet kutt 2>/dev/null; then
    systemctl restart kutt
    ok "Kutt service restarted."
else
    warn "Kutt systemd service not found or not running."
    echo "  If using Docker manually, restart with:"
    echo "    cd ${INSTALL_DIR} && docker compose down && docker compose up -d"
    echo "  If using native Node.js manually, restart the process."
fi

# ---------- Provider setup hints ---------------------------------------------
# Read the domain from .env for the callback URL
DOMAIN=$(grep "^DEFAULT_DOMAIN=" "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')
CALLBACK_URL="https://${DOMAIN}/api/auth/callback/oidc"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  OIDC configured successfully!         ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Make sure your OIDC provider is configured with:"
echo ""
echo -e "  Redirect / Callback URL:"
echo -e "    ${CYAN}${CALLBACK_URL}${NC}"
echo ""
echo "  If the callback URL above doesn't work, check Kutt's"
echo "  documentation or logs for the exact callback path."
echo ""
echo -e "${YELLOW}  Provider-specific notes:${NC}"
echo "  - Keycloak: Create a client with 'confidential' access type"
echo "  - Authentik: Create an OAuth2/OIDC provider and application"
echo "  - Google: Set up in Google Cloud Console > APIs & Services > Credentials"
echo "  - Microsoft: Register in Azure Portal > App registrations"
echo ""
echo "  View logs:  journalctl -u kutt -f"
echo "              cd ${INSTALL_DIR} && docker compose logs -f"
echo ""
