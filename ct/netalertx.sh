#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/j0nl1/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: j0nl1
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://netalertx.com/ | Github: https://github.com/netalertx/NetAlertX

APP="NetAlertX"
var_tags="${var_tags:-network;monitoring}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /app ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Stopping ${APP}"
  systemctl stop netalertx
  msg_ok "Stopped ${APP}"

  msg_info "Updating ${APP}"
  cd /app
  $STD git pull
  source /opt/myenv/bin/activate
  $STD pip install -r /app/install/proxmox/requirements.txt
  msg_ok "Updated ${APP}"

  msg_info "Starting ${APP}"
  systemctl start netalertx
  msg_ok "Started ${APP}"

  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:20211${CL}"
