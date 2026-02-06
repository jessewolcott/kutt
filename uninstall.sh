#!/usr/bin/env bash
# =============================================================================
# Kutt URL Shortener - Uninstaller
# =============================================================================
# Reverses everything done by install.sh:
#   - Stops and removes the Kutt systemd service
#   - Tears down Docker containers, images, and volumes (if Docker mode)
#   - Removes the kutt system user (if native mode)
#   - Removes the Nginx site configuration
#   - Revokes and deletes the Let's Encrypt certificate
#   - Removes the Certbot renewal hook
#   - Removes the /opt/kutt installation directory
#   - Optionally removes Docker, Node.js, Nginx, and Certbot packages
#
# Usage: sudo bash uninstall.sh
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

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local reply
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " reply
        reply="${reply:-y}"
    else
        read -rp "$prompt [y/N]: " reply
        reply="${reply:-n}"
    fi
    [[ "${reply,,}" == "y" ]]
}

# ---------- Pre-flight checks -----------------------------------------------
[[ $EUID -ne 0 ]] && die "This script must be run as root (use sudo)."

INSTALL_DIR="/opt/kutt"

echo ""
echo -e "${RED}========================================${NC}"
echo -e "${RED}  Kutt URL Shortener - Uninstaller      ${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo "This will remove Kutt and its configuration from this server."
echo "Each step will ask for confirmation before proceeding."
echo ""

# Try to detect the domain from the .env or nginx config
DOMAIN=""
if [[ -f "${INSTALL_DIR}/.env" ]]; then
    DOMAIN=$(grep "^DEFAULT_DOMAIN=" "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]') || true
fi
if [[ -z "$DOMAIN" && -f /etc/nginx/sites-available/kutt ]]; then
    DOMAIN=$(grep "server_name" /etc/nginx/sites-available/kutt 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';') || true
fi

if [[ -n "$DOMAIN" ]]; then
    info "Detected domain: ${DOMAIN}"
else
    read -rp "Enter the domain used during install (for cert cleanup): " DOMAIN
fi

echo ""
if ! confirm "Proceed with uninstallation?" "n"; then
    die "Uninstallation cancelled."
fi

# ---------- 1. Stop and remove Kutt systemd service -------------------------
echo ""
if systemctl list-unit-files kutt.service &>/dev/null && [[ -f /etc/systemd/system/kutt.service ]]; then
    info "Found Kutt systemd service."
    if confirm "  Stop and remove the kutt systemd service?" "y"; then
        systemctl stop kutt.service 2>/dev/null || true
        systemctl disable kutt.service 2>/dev/null || true
        rm -f /etc/systemd/system/kutt.service
        systemctl daemon-reload
        ok "Kutt systemd service removed."
    fi
else
    info "No Kutt systemd service found, skipping."
fi

# ---------- 2. Docker cleanup -----------------------------------------------
echo ""
if command -v docker &>/dev/null && [[ -d "$INSTALL_DIR" ]]; then
    # Check if there are kutt-related containers
    KUTT_CONTAINERS=$(docker ps -a --filter "label=com.docker.compose.project.working_dir=${INSTALL_DIR}" -q 2>/dev/null || true)
    # Also check by name pattern
    KUTT_CONTAINERS_BY_NAME=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i kutt || true)

    if [[ -n "$KUTT_CONTAINERS" || -n "$KUTT_CONTAINERS_BY_NAME" ]]; then
        info "Found Kutt Docker containers."
        if confirm "  Stop and remove Docker containers, networks, and volumes?" "y"; then
            cd "$INSTALL_DIR" 2>/dev/null || true

            # Try each compose file that might have been used
            for cf in docker-compose.yml docker-compose.postgres.yml docker-compose.sqlite-redis.yml docker-compose.mariadb.yml; do
                if [[ -f "${INSTALL_DIR}/${cf}" ]]; then
                    docker compose -f "${INSTALL_DIR}/${cf}" down -v --remove-orphans 2>/dev/null || true
                fi
            done

            # Clean up any remaining containers by name
            if [[ -n "$KUTT_CONTAINERS_BY_NAME" ]]; then
                echo "$KUTT_CONTAINERS_BY_NAME" | xargs -r docker rm -f 2>/dev/null || true
            fi

            ok "Docker containers and volumes removed."

            # Remove built images
            KUTT_IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null | grep -i kutt || true)
            if [[ -n "$KUTT_IMAGES" ]]; then
                if confirm "  Remove Kutt Docker images?" "y"; then
                    docker images --format '{{.ID}}' 2>/dev/null | while read -r img; do
                        docker rmi "$img" 2>/dev/null || true
                    done
                    # More targeted removal
                    docker images '*kutt*' -q 2>/dev/null | xargs -r docker rmi 2>/dev/null || true
                    ok "Kutt Docker images removed."
                fi
            fi
        fi
    else
        info "No Kutt Docker containers found, skipping."
    fi
fi

# ---------- 3. Remove kutt system user (native mode) ------------------------
echo ""
if id kutt &>/dev/null; then
    info "Found 'kutt' system user."
    if confirm "  Remove the 'kutt' system user?" "y"; then
        userdel kutt 2>/dev/null || true
        ok "System user 'kutt' removed."
    fi
else
    info "No 'kutt' system user found, skipping."
fi

# ---------- 4. Remove Nginx site configuration -------------------------------
echo ""
if [[ -f /etc/nginx/sites-available/kutt || -L /etc/nginx/sites-enabled/kutt ]]; then
    info "Found Kutt Nginx configuration."
    if confirm "  Remove Nginx site config and restore default?" "y"; then
        rm -f /etc/nginx/sites-enabled/kutt
        rm -f /etc/nginx/sites-available/kutt

        # Restore the default site if it exists but isn't linked
        if [[ -f /etc/nginx/sites-available/default && ! -L /etc/nginx/sites-enabled/default ]]; then
            ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
        fi

        # Test and reload nginx
        if nginx -t 2>/dev/null; then
            systemctl reload nginx 2>/dev/null || true
            ok "Nginx configuration removed and reloaded."
        else
            warn "Nginx config test failed. You may need to fix /etc/nginx/ manually."
        fi
    fi
else
    info "No Kutt Nginx configuration found, skipping."
fi

# ---------- 5. Revoke and delete Let's Encrypt certificate -------------------
echo ""
if [[ -n "$DOMAIN" && -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    info "Found Let's Encrypt certificate for ${DOMAIN}."
    if confirm "  Revoke and delete the SSL certificate for ${DOMAIN}?" "y"; then
        certbot revoke \
            --cert-path "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" \
            --non-interactive \
            --no-delete-after-revoke 2>/dev/null || warn "Certificate revocation failed (may already be revoked)."

        certbot delete \
            --cert-name "$DOMAIN" \
            --non-interactive 2>/dev/null || warn "Certificate deletion failed."

        ok "SSL certificate revoked and deleted."
    fi
elif [[ -n "$DOMAIN" ]]; then
    info "No Let's Encrypt certificate found for ${DOMAIN}, skipping."
fi

# ---------- 6. Remove Certbot renewal hook -----------------------------------
echo ""
if [[ -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh ]]; then
    info "Found Certbot renewal hook."
    if confirm "  Remove the Certbot Nginx reload hook?" "y"; then
        rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
        ok "Certbot renewal hook removed."
    fi
fi

# ---------- 7. Remove firewall rules ----------------------------------------
echo ""
if command -v ufw &>/dev/null && ufw status | grep -q "Nginx Full" 2>/dev/null; then
    info "Found UFW rule for 'Nginx Full'."
    if confirm "  Remove the 'Nginx Full' firewall rule?" "n"; then
        ufw delete allow 'Nginx Full' 2>/dev/null || true
        ok "Firewall rule removed."
        warn "SSH rule was left in place. HTTP/HTTPS ports are now closed."
    fi
else
    info "No Kutt-specific firewall rules found, skipping."
fi

# ---------- 8. Remove Kutt installation directory ----------------------------
echo ""
if [[ -d "$INSTALL_DIR" ]]; then
    info "Found Kutt installation at ${INSTALL_DIR}."
    echo -e "  ${YELLOW}WARNING: This will permanently delete all Kutt data including the database.${NC}"
    if confirm "  Delete ${INSTALL_DIR} and all its contents?" "n"; then
        rm -rf "$INSTALL_DIR"
        ok "${INSTALL_DIR} removed."
    else
        info "Kept ${INSTALL_DIR} intact."
    fi
fi

# Also clean up any backups made by the installer
BACKUPS=$(ls -d ${INSTALL_DIR}.bak.* 2>/dev/null || true)
if [[ -n "$BACKUPS" ]]; then
    info "Found installer backup(s):"
    echo "$BACKUPS" | while read -r bak; do echo "    $bak"; done
    if confirm "  Delete these backups too?" "n"; then
        echo "$BACKUPS" | while read -r bak; do rm -rf "$bak"; done
        ok "Backups removed."
    fi
fi

# ---------- 9. Optionally remove system packages ----------------------------
echo ""
echo -e "${YELLOW}The installer added these system packages. They may be used by other services.${NC}"
echo ""

# Docker
if command -v docker &>/dev/null; then
    if confirm "  Remove Docker? (skip if other services use it)" "n"; then
        systemctl stop docker 2>/dev/null || true
        systemctl disable docker 2>/dev/null || true
        apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt-get autoremove -y -qq 2>/dev/null || true
        rm -rf /var/lib/docker /var/lib/containerd 2>/dev/null || true
        ok "Docker removed."
    fi
fi

# Node.js
if command -v node &>/dev/null; then
    if confirm "  Remove Node.js? (skip if other services use it)" "n"; then
        apt-get purge -y -qq nodejs 2>/dev/null || true
        apt-get autoremove -y -qq 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
        ok "Node.js removed."
    fi
fi

# Nginx
if command -v nginx &>/dev/null; then
    if confirm "  Remove Nginx? (skip if other sites use it)" "n"; then
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        apt-get purge -y -qq nginx nginx-common 2>/dev/null || true
        apt-get autoremove -y -qq 2>/dev/null || true
        ok "Nginx removed."
    fi
fi

# Certbot
if command -v certbot &>/dev/null; then
    if confirm "  Remove Certbot? (skip if other certs use it)" "n"; then
        systemctl stop certbot.timer 2>/dev/null || true
        systemctl disable certbot.timer 2>/dev/null || true
        apt-get purge -y -qq certbot python3-certbot-nginx 2>/dev/null || true
        apt-get autoremove -y -qq 2>/dev/null || true
        ok "Certbot removed."
    fi
fi

# ---------- Done! ------------------------------------------------------------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Uninstallation complete!              ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Summary of what was cleaned up:"
echo "    - Kutt service, containers, and application files"
echo "    - Nginx site configuration"
echo "    - Let's Encrypt certificate"
echo ""
echo "  If anything was skipped, you can re-run this script"
echo "  or clean up manually."
echo ""
