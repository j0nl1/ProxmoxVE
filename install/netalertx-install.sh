#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: j0nl1
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://netalertx.com/ | Github: https://github.com/netalertx/NetAlertX

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

INSTALL_DIR="/app"
WEB_UI_DIR="/var/www/html/netalertx"
NGINX_CONF_FILE="netalertx.conf"

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  git \
  sudo \
  gnupg2 \
  lsb-release \
  ca-certificates \
  apt-utils \
  cron \
  zip \
  iproute2 \
  net-tools \
  dnsutils \
  build-essential
msg_ok "Installed Dependencies"

msg_info "Installing Network Scanning Tools"
$STD apt-get install -y \
  nmap \
  fping \
  arp-scan \
  nbtscan \
  traceroute \
  mtr \
  snmp \
  avahi-daemon \
  avahi-utils \
  usbutils \
  libwww-perl
msg_ok "Installed Network Scanning Tools"

msg_info "Installing PHP 8.4"
$STD apt-get install -y \
  php8.4 \
  php8.4-cgi \
  php8.4-fpm \
  php8.4-sqlite3 \
  php8.4-curl
msg_ok "Installed PHP 8.4"

msg_info "Installing Python"
$STD apt-get install -y \
  python3 \
  python3-dev \
  python3-pip \
  python3-venv \
  python3-psutil \
  python3-nmap \
  sqlite3 \
  perl
msg_ok "Installed Python"

msg_info "Installing Nginx"
$STD apt-get install -y nginx
msg_ok "Installed Nginx"

msg_info "Cloning NetAlertX Repository"
git clone -q https://github.com/netalertx/NetAlertX.git "$INSTALL_DIR/"
if [[ ! -f "$INSTALL_DIR/front/buildtimestamp.txt" ]]; then
  date +%s >"$INSTALL_DIR/front/buildtimestamp.txt"
fi
msg_ok "Cloned NetAlertX Repository"

msg_info "Setting up Python Virtual Environment"
$STD python3 -m venv /opt/myenv
source /opt/myenv/bin/activate
$STD pip install --upgrade pip
$STD pip install -r "$INSTALL_DIR/requirements.txt"
msg_ok "Setup Python Virtual Environment"

msg_info "Configuring Nginx"
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  rm /etc/nginx/sites-enabled/default
elif [[ -f /etc/nginx/sites-enabled/default ]]; then
  mv /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default.bkp
fi

mkdir -p /var/www/html
ln -sfn "$INSTALL_DIR/front" "$WEB_UI_DIR"

mkdir -p "$INSTALL_DIR/config"
cp "$INSTALL_DIR/install/proxmox/$NGINX_CONF_FILE" "$INSTALL_DIR/config/$NGINX_CONF_FILE"
ln -sfn "$INSTALL_DIR/config/$NGINX_CONF_FILE" "/etc/nginx/conf.d/$NGINX_CONF_FILE"

$STD nginx -t
systemctl enable -q nginx
systemctl restart -q nginx
msg_ok "Configured Nginx"

msg_info "Updating Hardware Vendors Database"
OUI_FILE="/usr/share/arp-scan/ieee-oui.txt"
if [[ ! -f "$OUI_FILE" ]] && [[ -f "$INSTALL_DIR/back/update_vendors.sh" ]]; then
  $STD bash "$INSTALL_DIR/back/update_vendors.sh"
fi
msg_ok "Updated Hardware Vendors Database"

msg_info "Setting up File Structure"
rm -f "$INSTALL_DIR/api" 2>/dev/null
mkdir -p "$INSTALL_DIR/log/plugins" "$INSTALL_DIR/api" "$INSTALL_DIR/config" "$INSTALL_DIR/db"

touch "$INSTALL_DIR/log/app.log" \
  "$INSTALL_DIR/log/execution_queue.log" \
  "$INSTALL_DIR/log/app_front.log" \
  "$INSTALL_DIR/log/app.php_errors.log" \
  "$INSTALL_DIR/log/stderr.log" \
  "$INSTALL_DIR/log/stdout.log" \
  "$INSTALL_DIR/log/db_is_locked.log"
touch "$INSTALL_DIR/api/user_notifications.json"

cp -u "$INSTALL_DIR/back/app.conf" "$INSTALL_DIR/config/app.conf"
cp -u "$INSTALL_DIR/back/app.db" "$INSTALL_DIR/db/app.db"

mkdir -p /data /tmp/api /tmp/log/plugins
ln -sfn "$INSTALL_DIR/config" /data/config
ln -sfn "$INSTALL_DIR/db" /data/db

chgrp -R www-data "$INSTALL_DIR"
chmod -R ug+rwX,o-rwx "$INSTALL_DIR"
chown -R www-data:www-data "$INSTALL_DIR/log" "$INSTALL_DIR/api" "$INSTALL_DIR/db" /tmp/api /tmp/log
msg_ok "Setup File Structure"

msg_info "Configuring Sudoers"
echo "www-data ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/netalertx
chmod 440 /etc/sudoers.d/netalertx
msg_ok "Configured Sudoers"

msg_info "Starting PHP-FPM"
systemctl enable -q php8.4-fpm
systemctl start -q php8.4-fpm
msg_ok "Started PHP-FPM"

msg_info "Creating Service"
SERVER_IP="$(hostname -I | awk '{print $1}')"
cat <<EOF >"$INSTALL_DIR/start.netalertx.sh"
#!/usr/bin/env bash
source /opt/myenv/bin/activate
export PYTHONPATH=/app
python server/
EOF
chmod +x "$INSTALL_DIR/start.netalertx.sh"

cat <<EOF >/etc/systemd/system/netalertx.service
[Unit]
Description=NetAlertX Service
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/app/start.netalertx.sh
WorkingDirectory=/app
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q --now netalertx
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
