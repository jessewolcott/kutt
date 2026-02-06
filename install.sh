#!/usr/bin/env bash
# =============================================================================
# Kutt URL Shortener - Ubuntu Server Installer
# =============================================================================
# This script installs Kutt on an Ubuntu server with:
#   - Docker (or native Node.js) deployment
#   - Nginx reverse proxy
#   - Let's Encrypt SSL via Certbot
#   - systemd service management
#
# Usage: sudo bash install.sh
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
source /etc/os-release 2>/dev/null || true
if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"ubuntu"* && "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
    warn "This script is designed for Ubuntu/Debian. Proceed at your own risk."
fi

# ---------- Gather configuration ---------------------------------------------
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Kutt URL Shortener - Server Installer ${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Domain
read -rp "Enter your domain name (e.g. s.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && die "Domain is required."

# Email for Let's Encrypt
read -rp "Enter your email (for Let's Encrypt notifications): " LE_EMAIL
[[ -z "$LE_EMAIL" ]] && die "Email is required for Let's Encrypt."

# Deployment mode
echo ""
echo "Deployment mode:"
echo "  1) Docker (recommended)"
echo "  2) Native Node.js"
read -rp "Choose [1/2] (default: 1): " DEPLOY_MODE
DEPLOY_MODE="${DEPLOY_MODE:-1}"

# Database backend (for Docker mode)
if [[ "$DEPLOY_MODE" == "1" ]]; then
    echo ""
    echo "Database backend:"
    echo "  1) SQLite (simplest, good for small-medium usage)"
    echo "  2) PostgreSQL (recommended for production)"
    read -rp "Choose [1/2] (default: 1): " DB_BACKEND
    DB_BACKEND="${DB_BACKEND:-1}"
else
    DB_BACKEND="1"  # Native mode defaults to SQLite
    echo ""
    echo "Database backend: SQLite (default for native mode)"
    echo "  (Edit .env after install to switch to PostgreSQL/MySQL)"
fi

# Optional: mail setup
echo ""
read -rp "Enable email (for signup, password reset)? [y/N]: " ENABLE_MAIL
ENABLE_MAIL="${ENABLE_MAIL,,}"

if [[ "$ENABLE_MAIL" == "y" ]]; then
    read -rp "  SMTP host: " MAIL_HOST
    read -rp "  SMTP port (default 587): " MAIL_PORT
    MAIL_PORT="${MAIL_PORT:-587}"
    read -rp "  SMTP user: " MAIL_USER
    read -rsp "  SMTP password: " MAIL_PASSWORD
    echo ""
    read -rp "  From address (e.g. noreply@${DOMAIN}): " MAIL_FROM
    MAIL_FROM="${MAIL_FROM:-noreply@${DOMAIN}}"
fi

# Optional: allow registration
echo ""
read -rp "Allow public registration? [y/N]: " ALLOW_REG
ALLOW_REG="${ALLOW_REG,,}"

# Optional: allow anonymous links
read -rp "Allow anonymous link creation? [y/N]: " ALLOW_ANON
ALLOW_ANON="${ALLOW_ANON,,}"

# Generate secrets
JWT_SECRET=$(openssl rand -base64 48)
DB_PASSWORD=$(openssl rand -base64 24)

INSTALL_DIR="/opt/kutt"

echo ""
info "Configuration summary:"
echo "  Domain:       $DOMAIN"
echo "  Email:        $LE_EMAIL"
echo "  Deploy mode:  $([ "$DEPLOY_MODE" == "1" ] && echo "Docker" || echo "Native Node.js")"
echo "  Database:     $([ "$DB_BACKEND" == "2" ] && echo "PostgreSQL" || echo "SQLite")"
echo "  Mail:         $([ "$ENABLE_MAIL" == "y" ] && echo "Enabled" || echo "Disabled")"
echo "  Registration: $([ "$ALLOW_REG" == "y" ] && echo "Allowed" || echo "Disabled")"
echo "  Install dir:  $INSTALL_DIR"
echo ""
read -rp "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
[[ "${CONFIRM,,}" != "y" ]] && die "Installation cancelled."

# ---------- Install system packages ------------------------------------------
info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

info "Installing base dependencies..."
apt-get install -y -qq \
    curl \
    wget \
    git \
    ufw \
    nginx \
    certbot \
    python3-certbot-nginx \
    openssl

# ---------- Install Docker (if Docker mode) ----------------------------------
if [[ "$DEPLOY_MODE" == "1" ]]; then
    if ! command -v docker &>/dev/null; then
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
        ok "Docker installed."
    else
        ok "Docker already installed."
    fi

    # Ensure docker compose plugin is available
    if ! docker compose version &>/dev/null; then
        info "Installing Docker Compose plugin..."
        apt-get install -y -qq docker-compose-plugin
    fi
    ok "Docker Compose available."
fi

# ---------- Install Node.js (if native mode) ---------------------------------
if [[ "$DEPLOY_MODE" == "2" ]]; then
    if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 20 ]]; then
        info "Installing Node.js 20 LTS..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y -qq nodejs
        ok "Node.js $(node -v) installed."
    else
        ok "Node.js $(node -v) already installed."
    fi
fi

# ---------- Clone / copy Kutt ------------------------------------------------
info "Setting up Kutt in ${INSTALL_DIR}..."
if [[ -d "$INSTALL_DIR" ]]; then
    warn "$INSTALL_DIR already exists. Backing up to ${INSTALL_DIR}.bak.$(date +%s)"
    mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
fi

# If running from the repo directory, copy it; otherwise clone from GitHub
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/package.json" ]] && grep -q '"name"' "$SCRIPT_DIR/package.json" 2>/dev/null; then
    info "Copying local repository to ${INSTALL_DIR}..."
    cp -a "$SCRIPT_DIR" "$INSTALL_DIR"
else
    info "Cloning Kutt from GitHub..."
    git clone https://github.com/thedevs-network/kutt.git "$INSTALL_DIR"
fi
ok "Kutt source ready."

# ---------- Create .env file ------------------------------------------------
info "Writing .env configuration..."

DISALLOW_REG="true"
[[ "$ALLOW_REG" == "y" ]] && DISALLOW_REG="false"

DISALLOW_ANON="true"
[[ "$ALLOW_ANON" == "y" ]] && DISALLOW_ANON="false"

cat > "${INSTALL_DIR}/.env" <<ENVEOF
# Kutt configuration - generated by installer on $(date)
PORT=3000
SITE_NAME=Kutt
DEFAULT_DOMAIN=${DOMAIN}
JWT_SECRET=${JWT_SECRET}

# Trust the Nginx reverse proxy
TRUST_PROXY=true

# Registration & anonymous links
DISALLOW_REGISTRATION=${DISALLOW_REG}
DISALLOW_ANONYMOUS_LINKS=${DISALLOW_ANON}

# Rate limiting
ENABLE_RATE_LIMIT=true
ENVEOF

# Database config
if [[ "$DB_BACKEND" == "2" ]]; then
    cat >> "${INSTALL_DIR}/.env" <<ENVEOF

# PostgreSQL
DB_CLIENT=pg
DB_HOST=$([ "$DEPLOY_MODE" == "1" ] && echo "postgres" || echo "localhost")
DB_PORT=5432
DB_NAME=kutt
DB_USER=kutt
DB_PASSWORD=${DB_PASSWORD}
DB_SSL=false
DB_POOL_MIN=2
DB_POOL_MAX=10

# Redis
REDIS_ENABLED=true
REDIS_HOST=$([ "$DEPLOY_MODE" == "1" ] && echo "redis" || echo "127.0.0.1")
REDIS_PORT=6379
ENVEOF
else
    cat >> "${INSTALL_DIR}/.env" <<ENVEOF

# SQLite
DB_CLIENT=better-sqlite3
DB_FILENAME=$([ "$DEPLOY_MODE" == "1" ] && echo "/var/lib/kutt/data.sqlite" || echo "db/data")
ENVEOF
fi

# Mail config
if [[ "$ENABLE_MAIL" == "y" ]]; then
    cat >> "${INSTALL_DIR}/.env" <<ENVEOF

# Mail
MAIL_ENABLED=true
MAIL_HOST=${MAIL_HOST}
MAIL_PORT=${MAIL_PORT}
MAIL_SECURE=$([ "${MAIL_PORT}" == "465" ] && echo "true" || echo "false")
MAIL_USER=${MAIL_USER}
MAIL_PASSWORD=${MAIL_PASSWORD}
MAIL_FROM=${MAIL_FROM}
ENVEOF
else
    echo -e "\n# Mail disabled\nMAIL_ENABLED=false" >> "${INSTALL_DIR}/.env"
fi

chmod 600 "${INSTALL_DIR}/.env"
ok ".env created."

# ---------- Firewall ---------------------------------------------------------
info "Configuring firewall..."
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 'Nginx Full' >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
ok "Firewall configured (SSH + HTTP/HTTPS)."

# ---------- Nginx (initial HTTP config for Certbot) -------------------------
info "Configuring Nginx..."

cat > /etc/nginx/sites-available/kutt <<'NGINXEOF'
server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
NGINXEOF

sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" /etc/nginx/sites-available/kutt

ln -sf /etc/nginx/sites-available/kutt /etc/nginx/sites-enabled/kutt
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
ok "Nginx configured for initial HTTP."

# ---------- Let's Encrypt SSL ------------------------------------------------
info "Obtaining Let's Encrypt SSL certificate..."
certbot certonly \
    --nginx \
    --non-interactive \
    --agree-tos \
    --email "$LE_EMAIL" \
    -d "$DOMAIN"

ok "SSL certificate obtained."

# ---------- Nginx (full HTTPS config) ----------------------------------------
info "Updating Nginx with full HTTPS configuration..."

cat > /etc/nginx/sites-available/kutt <<NGINXEOF
# Kutt - Nginx reverse proxy with SSL
# Generated by installer on $(date)

# Redirect HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # SSL certificates (managed by Certbot)
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # SSL hardening
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # Proxy to Kutt
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 90s;
        proxy_buffering off;
    }
}
NGINXEOF

nginx -t && systemctl reload nginx
ok "Nginx HTTPS configuration active."

# ---------- Certbot auto-renewal --------------------------------------------
info "Setting up certificate auto-renewal..."
systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

# Add a post-renewal hook to reload nginx
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOKEOF'
#!/bin/bash
systemctl reload nginx
HOOKEOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
ok "Certbot auto-renewal configured."

# ---------- Start Kutt (Docker mode) -----------------------------------------
if [[ "$DEPLOY_MODE" == "1" ]]; then
    info "Starting Kutt with Docker Compose..."
    cd "$INSTALL_DIR"

    if [[ "$DB_BACKEND" == "2" ]]; then
        COMPOSE_FILE="docker-compose.postgres.yml"
    else
        COMPOSE_FILE="docker-compose.yml"
    fi

    docker compose -f "$COMPOSE_FILE" --env-file .env up -d --build
    ok "Kutt is running via Docker."

    # Create a systemd unit so Kutt starts on boot
    cat > /etc/systemd/system/kutt.service <<SVCEOF
[Unit]
Description=Kutt URL Shortener (Docker)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose -f ${COMPOSE_FILE} --env-file .env up -d
ExecStop=/usr/bin/docker compose -f ${COMPOSE_FILE} --env-file .env down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable kutt.service
    ok "Kutt systemd service created and enabled."
fi

# ---------- Start Kutt (Native mode) -----------------------------------------
if [[ "$DEPLOY_MODE" == "2" ]]; then
    info "Installing Node.js dependencies..."
    cd "$INSTALL_DIR"
    npm install --production

    info "Running database migration..."
    npm run migrate

    # Create a dedicated user
    if ! id kutt &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin kutt
    fi
    chown -R kutt:kutt "$INSTALL_DIR"

    # Create systemd service
    cat > /etc/systemd/system/kutt.service <<SVCEOF
[Unit]
Description=Kutt URL Shortener
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=kutt
Group=kutt
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node server/index.js
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable kutt.service
    systemctl start kutt.service
    ok "Kutt is running as a systemd service."
fi

# ---------- Done! ------------------------------------------------------------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation complete!                ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  URL:          ${CYAN}https://${DOMAIN}${NC}"
echo -e "  Install dir:  ${INSTALL_DIR}"
echo -e "  Config file:  ${INSTALL_DIR}/.env"
echo ""
echo "  On first visit, you'll be prompted to create an admin account."
echo ""
echo "  Useful commands:"
if [[ "$DEPLOY_MODE" == "1" ]]; then
echo "    View logs:     cd ${INSTALL_DIR} && docker compose logs -f"
echo "    Restart:       systemctl restart kutt"
echo "    Stop:          systemctl stop kutt"
else
echo "    View logs:     journalctl -u kutt -f"
echo "    Restart:       systemctl restart kutt"
echo "    Stop:          systemctl stop kutt"
fi
echo "    SSL renewal:   certbot renew --dry-run"
echo "    Edit config:   nano ${INSTALL_DIR}/.env"
echo ""
echo -e "${YELLOW}  IMPORTANT: After creating your admin account, consider setting${NC}"
echo -e "${YELLOW}  DISALLOW_REGISTRATION=true in .env if you haven't already.${NC}"
echo ""
