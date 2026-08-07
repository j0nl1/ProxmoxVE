#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: j0nl1
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://openclaw.ai/ | Github: https://github.com/openclaw/openclaw

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  ca-certificates \
  chromium \
  chromium-sandbox \
  curl \
  dbus-user-session \
  fonts-liberation \
  fonts-noto-cjk \
  fonts-noto-color-emoji \
  git \
  gnupg \
  jq \
  openssl \
  sudo \
  whiptail
msg_ok "Installed Dependencies"

msg_info "Creating OpenClaw User"
if ! id -u openclaw >/dev/null 2>&1; then
  useradd --create-home --user-group --home-dir /home/openclaw --shell /bin/bash openclaw
fi
openclaw_passwd=$(getent passwd openclaw) || {
  msg_error "The openclaw account could not be read from the system user database."
  exit 1
}
IFS=: read -r openclaw_name openclaw_password openclaw_uid openclaw_gid \
  openclaw_gecos openclaw_home openclaw_shell <<<"$openclaw_passwd"
if [[ ! "$openclaw_uid" =~ ^[1-9][0-9]*$ ||
  ! "$openclaw_gid" =~ ^[1-9][0-9]*$ ||
  "$openclaw_home" != "/home/openclaw" ||
  "$openclaw_shell" != "/bin/bash" ]]; then
  msg_error "The existing openclaw account has an unsafe UID, home, group, or shell."
  exit 1
fi
if [[ -L /home/openclaw || ! -d /home/openclaw ||
  "$(stat -c '%u' /home/openclaw)" != "$openclaw_uid" ||
  "$(stat -c '%g' /home/openclaw)" != "$openclaw_gid" ]]; then
  msg_error "The openclaw home directory is missing, linked, or owned by an unexpected account."
  exit 1
fi
chmod 700 /home/openclaw
if ! passwd -l openclaw >/dev/null 2>&1 ||
  [[ "$(passwd -S openclaw | awk '{print $2}')" != "L" ]]; then
  msg_error "The openclaw account password could not be locked."
  exit 1
fi
if [[ -L /home/openclaw/.openclaw || (-e /home/openclaw/.openclaw && ! -d /home/openclaw/.openclaw) ]]; then
  msg_error "Refusing to use the unexpected object at /home/openclaw/.openclaw."
  exit 1
fi
runuser -u openclaw -- install -d -m 700 /home/openclaw/.openclaw
msg_ok "Created OpenClaw User"

msg_info "Installing OpenClaw"
readonly OPENCLAW_INSTALL_VERSION="2026.7.1-2"
installer_dir=$(mktemp -d /tmp/openclaw-installer.XXXXXX)
installer_path="${installer_dir}/install-cli.sh"
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh -o "$installer_path"
if [[ "$(head -c 2 "$installer_path")" != "#!" ]]; then
  msg_error "The OpenClaw installer did not contain a valid shell script."
  exit 1
fi
chmod 700 "$installer_path"
chown -R openclaw:openclaw "$installer_dir"
$STD runuser -u openclaw -- env -i \
  HOME=/home/openclaw \
  USER=openclaw \
  LOGNAME=openclaw \
  SHELL=/bin/bash \
  LANG=C.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /bin/bash "$installer_path" \
  --prefix /home/openclaw/.openclaw \
  --install-method npm \
  --version "$OPENCLAW_INSTALL_VERSION" \
  --no-onboard \
  --json
rm -f "$installer_path"
rmdir "$installer_dir"

if [[ ! -x /home/openclaw/.openclaw/bin/openclaw ]]; then
  msg_error "OpenClaw installation did not create the expected CLI binary."
  exit 1
fi
msg_ok "Installed OpenClaw"

msg_info "Granting OpenClaw Administrative Access Inside the LXC"
(
  sudoers_tmp=$(mktemp /etc/sudoers.d/.openclaw.XXXXXX)
  trap '[[ -z "${sudoers_tmp:-}" ]] || rm -f -- "$sudoers_tmp"' EXIT

  printf '%s\n' 'openclaw ALL=(ALL:ALL) NOPASSWD: ALL' >"$sudoers_tmp"
  chown root:root "$sudoers_tmp"
  chmod 440 "$sudoers_tmp"
  /usr/sbin/visudo -cf "$sudoers_tmp" >/dev/null
  mv -fT -- "$sudoers_tmp" /etc/sudoers.d/openclaw
  sudoers_tmp=""
)
/usr/sbin/visudo -cf /etc/sudoers >/dev/null
if [[ "$(runuser -u openclaw -- /usr/bin/sudo -n /usr/bin/id -u)" != "0" ]]; then
  msg_error "Passwordless sudo validation failed for the openclaw user."
  exit 1
fi
msg_ok "Granted OpenClaw Administrative Access Inside the LXC"

msg_info "Installing Cloudflared"
setup_deb822_repo \
  "cloudflared" \
  "https://pkg.cloudflare.com/cloudflare-main.gpg" \
  "https://pkg.cloudflare.com/cloudflared/" \
  "any" \
  "main"
$STD apt-get install -y cloudflared
msg_ok "Installed Cloudflared"

msg_info "Enabling Persistent User Services"
openclaw_uid=$(id -u openclaw)
if ! loginctl enable-linger openclaw >/dev/null 2>&1; then
  install -d -m 755 /var/lib/systemd/linger
  touch /var/lib/systemd/linger/openclaw
fi
systemctl start "user@${openclaw_uid}.service" >/dev/null 2>&1 || true
msg_ok "Enabled Persistent User Services"

msg_info "Creating OpenClaw Command Wrapper"
cat <<'EOF' >/usr/local/bin/openclaw
#!/usr/bin/env bash
set -Eeuo pipefail
set +x

OPENCLAW_USER="openclaw"
OPENCLAW_USER_HOME="/home/openclaw"
OPENCLAW_BIN="${OPENCLAW_USER_HOME}/.openclaw/bin/openclaw"

if [[ ! -x "$OPENCLAW_BIN" ]]; then
  echo "OpenClaw is not installed at ${OPENCLAW_BIN}." >&2
  exit 127
fi

current_user=$(id -un)
if [[ "$current_user" != "$OPENCLAW_USER" && "$EUID" -ne 0 ]]; then
  echo "Run this command as root or as the openclaw user." >&2
  exit 1
fi

openclaw_uid=$(id -u "$OPENCLAW_USER")
if [[ "$EUID" -eq 0 ]]; then
  loginctl enable-linger "$OPENCLAW_USER" >/dev/null 2>&1 || true
  systemctl start "user@${openclaw_uid}.service" >/dev/null 2>&1 || true
  runner=(runuser -u "$OPENCLAW_USER" --)
else
  runner=()
fi

exec "${runner[@]}" env -i \
  HOME="$OPENCLAW_USER_HOME" \
  USER="$OPENCLAW_USER" \
  LOGNAME="$OPENCLAW_USER" \
  SHELL=/bin/bash \
  LANG=C.UTF-8 \
  TERM="${TERM:-xterm-256color}" \
  XDG_RUNTIME_DIR="/run/user/${openclaw_uid}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${openclaw_uid}/bus" \
  PATH="${OPENCLAW_USER_HOME}/.local/bin:${OPENCLAW_USER_HOME}/.openclaw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$OPENCLAW_BIN" "$@"
EOF
chmod 755 /usr/local/bin/openclaw
msg_ok "Created OpenClaw Command Wrapper"

msg_info "Creating Gateway Token Helper"
cat <<'TOKEN_HELPER' >/usr/local/sbin/openclaw-gateway-token
#!/usr/bin/env bash
set -Eeuo pipefail
set +x

readonly TOKEN_FILE="/home/openclaw/.openclaw/.env"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run this command as root." >&2
  exit 1
fi
if [[ ! -t 0 || ! -t 1 ]]; then
  echo "Refusing to reveal the Gateway token without an interactive terminal." >&2
  exit 1
fi
if [[ ! -r "$TOKEN_FILE" ]]; then
  echo "Gateway token file not found. Run openclaw-setup first." >&2
  exit 1
fi

read -r -p "Reveal the OpenClaw Gateway token on this terminal? [y/N] " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

gateway_token=$(awk '/^OPENCLAW_GATEWAY_TOKEN=/{ sub(/^OPENCLAW_GATEWAY_TOKEN=/, ""); token = $0 } END { if (token != "") print token }' "$TOKEN_FILE")
if [[ -z "$gateway_token" ]]; then
  echo "No Gateway token was found in ${TOKEN_FILE}." >&2
  exit 1
fi

printf '%s\n' "$gateway_token"
unset gateway_token
TOKEN_HELPER
chmod 750 /usr/local/sbin/openclaw-gateway-token
msg_ok "Created Gateway Token Helper"

msg_info "Creating OpenClaw Setup Wizard"
cat <<'WIZARD' >/usr/local/sbin/openclaw-setup
#!/usr/bin/env bash
set -Eeuo pipefail
# This wizard handles OAuth, API, Gateway, and Tunnel credentials. Never echo
# shell expansions, even if it is invoked explicitly with bash -x.
set +x

readonly OPENCLAW_USER="openclaw"
readonly OPENCLAW_USER_HOME="/home/openclaw"
readonly OPENCLAW_STATE_DIR="${OPENCLAW_USER_HOME}/.openclaw"
readonly OPENCLAW_BIN="${OPENCLAW_STATE_DIR}/bin/openclaw"
readonly OPENCLAW_CONFIG="${OPENCLAW_STATE_DIR}/openclaw.json"
readonly OPENCLAW_ENV_FILE="${OPENCLAW_STATE_DIR}/.env"
readonly BACKTITLE="OpenClaw on Proxmox LXC"
readonly CLOUDFLARED_BIN="/usr/bin/cloudflared"

public_hostname=""
cloudflare_configured=0
browser_configured=0
browser_agent_tool_configured=0
browser_probe_output=""
browser_was_managed_before_hardening=0
browser_was_running_before_hardening=0
system_control_mode=""
readonly CLOUDFLARED_TOKEN_FILE="/etc/cloudflared/tunnel-token"
readonly CLOUDFLARED_METRICS_URL="http://127.0.0.1:20241/metrics"
cloudflared_rollback_backup=""
cloudflared_rollback_unit=""
cloudflared_rollback_mode=""
cloudflared_rollback_uid=""
cloudflared_rollback_gid=""
cloudflared_rollback_token_backup=""
cloudflared_rollback_token_mode=""
cloudflared_rollback_token_uid=""
cloudflared_rollback_token_gid=""
cloudflared_rollback_token_existed=0
cloudflared_rollback_had_service=0
cloudflared_rollback_is_managed=0
cloudflared_rollback_active_state=""
cloudflared_rollback_unit_file_state=""
cloudflared_transaction_pending=0
cloudflare_commit_requested=0
cloudflared_service_mutated=0
cloudflared_service_retained=0
cloudflared_retained_service_managed=0
cloudflare_origin_mutated=0
cloudflare_allowed_origins_existed=0
cloudflare_allowed_origins_rollback_json=""
optional_config_value_found=0
optional_config_value_json=""
gateway_created_this_run=0

function cloudflared_systemd_property() {
  local property="$1"
  local value

  value=$(systemctl show cloudflared.service --property="$property" --value 2>/dev/null) || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

function cloudflared_has_connections() {
  curl --connect-timeout 1 --max-time 2 -fsS "$CLOUDFLARED_METRICS_URL" 2>/dev/null |
    awk '$1 ~ /^cloudflared_tunnel_ha_connections(\{|$)/ && ($NF + 0) > 0 { found = 1 } END { exit !found }'
}

function wait_for_cloudflared_connections() {
  local active_state

  for _ in {1..60}; do
    active_state=$(cloudflared_systemd_property ActiveState) || return 1
    if [[ "$active_state" == "active" ]] && cloudflared_has_connections; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

function wait_for_cloudflared_inactive() {
  local active_state

  for _ in {1..40}; do
    active_state=$(cloudflared_systemd_property ActiveState) || return 1
    case "$active_state" in
    inactive | failed)
      return 0
      ;;
    esac
    sleep 0.25
  done
  return 1
}

function wait_for_cloudflared_active() {
  local active_state

  for _ in {1..60}; do
    active_state=$(cloudflared_systemd_property ActiveState) || return 1
    if [[ "$active_state" == "active" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

function stop_cloudflared_bounded() {
  systemctl stop --no-block cloudflared.service >/dev/null 2>&1 || return 1
  if wait_for_cloudflared_inactive; then
    return 0
  fi

  if ! systemctl kill --kill-who=all --signal=TERM cloudflared.service >/dev/null 2>&1; then
    wait_for_cloudflared_inactive && return 0
    return 1
  fi
  wait_for_cloudflared_inactive
}

function set_cloudflared_unit_file_state() {
  local actual_state
  local target_state="$1"

  case "$target_state" in
  enabled)
    systemctl enable cloudflared.service >/dev/null 2>&1 || return 1
    ;;
  enabled-runtime)
    systemctl disable cloudflared.service >/dev/null 2>&1 || return 1
    systemctl enable --runtime cloudflared.service >/dev/null 2>&1 || return 1
    ;;
  disabled)
    systemctl disable cloudflared.service >/dev/null 2>&1 || return 1
    ;;
  *)
    return 1
    ;;
  esac

  actual_state=$(cloudflared_systemd_property UnitFileState) || return 1
  [[ "$actual_state" == "$target_state" ]]
}

function restore_cloudflared_service() {
  local current_load_state
  local current_unit_file_state

  current_load_state=$(cloudflared_systemd_property LoadState) || return 1
  if [[ "$current_load_state" != "not-found" ]]; then
    stop_cloudflared_bounded || return 1
  fi

  if [[ "$cloudflared_rollback_had_service" -eq 1 ]]; then
    if ! install -o "$cloudflared_rollback_uid" -g "$cloudflared_rollback_gid" -m "$cloudflared_rollback_mode" \
      "$cloudflared_rollback_backup" "$cloudflared_rollback_unit"; then
      return 1
    fi
  else
    if [[ "$current_load_state" != "not-found" ]]; then
      systemctl disable cloudflared.service >/dev/null 2>&1 || return 1
      current_unit_file_state=$(cloudflared_systemd_property UnitFileState) || return 1
      [[ "$current_unit_file_state" == "disabled" ]] || return 1
    fi
    rm -f -- /etc/systemd/system/cloudflared.service || return 1
  fi

  if [[ "$cloudflared_rollback_token_existed" -eq 1 ]]; then
    if ! install -o "$cloudflared_rollback_token_uid" -g "$cloudflared_rollback_token_gid" -m "$cloudflared_rollback_token_mode" \
      "$cloudflared_rollback_token_backup" "$CLOUDFLARED_TOKEN_FILE"; then
      return 1
    fi
  else
    rm -f -- "$CLOUDFLARED_TOKEN_FILE" || return 1
  fi
  systemctl daemon-reload >/dev/null 2>&1 || return 1

  if [[ "$cloudflared_rollback_had_service" -eq 1 ]]; then
    set_cloudflared_unit_file_state "$cloudflared_rollback_unit_file_state" || return 1
    if [[ "$cloudflared_rollback_active_state" == "active" ]]; then
      systemctl start --no-block cloudflared.service >/dev/null 2>&1 || return 1
      wait_for_cloudflared_active || return 1
      if [[ "$cloudflared_rollback_is_managed" -eq 1 ]]; then
        wait_for_cloudflared_connections || return 1
      fi
    else
      stop_cloudflared_bounded || return 1
    fi
    [[ "$(cloudflared_systemd_property ActiveState)" == "$cloudflared_rollback_active_state" ]] || return 1
  else
    [[ "$(cloudflared_systemd_property LoadState)" == "not-found" ]] || return 1
  fi
}

function restore_cloudflare_origin() {
  local current_gateway_json
  local gateway_ready=0

  if [[ "$cloudflare_allowed_origins_existed" -eq 1 ]]; then
    openclaw_cli_bounded config set gateway.controlUi.allowedOrigins \
      "$cloudflare_allowed_origins_rollback_json" --strict-json || return 1
  elif openclaw_cli_bounded config get gateway.controlUi.allowedOrigins --json >/dev/null 2>&1; then
    openclaw_cli_bounded config unset gateway.controlUi.allowedOrigins || return 1
  fi
  openclaw_cli_bounded config validate || return 1
  openclaw_cli_bounded gateway restart || return 1
  for _ in {1..40}; do
    if curl --connect-timeout 1 --max-time 2 -fsS http://127.0.0.1:18789/readyz >/dev/null 2>&1; then
      gateway_ready=1
      break
    fi
    sleep 0.5
  done
  [[ "$gateway_ready" -eq 1 ]] || return 1

  current_gateway_json=$(openclaw_cli_bounded config get gateway --json) || return 1
  if [[ "$cloudflare_allowed_origins_existed" -eq 1 ]]; then
    jq -e --argjson expected "$cloudflare_allowed_origins_rollback_json" \
      '.controlUi.allowedOrigins == $expected' <<<"$current_gateway_json" >/dev/null
  else
    jq -e '(.controlUi // {} | has("allowedOrigins")) | not' \
      <<<"$current_gateway_json" >/dev/null
  fi
}

function commit_cloudflare_transaction() {
  cloudflare_commit_requested=1
}

function cleanup_cloudflared_transaction() {
  local exit_status=$?
  local browser_restore_failed=0
  local rollback_failed=0

  trap - EXIT
  set +e

  if [[ "$cloudflared_transaction_pending" -eq 1 &&
    ("$exit_status" -ne 0 || "$cloudflare_commit_requested" -ne 1) ]]; then
    if [[ "$cloudflared_service_mutated" -eq 1 ]]; then
      echo "Restoring the previous cloudflared service..." >&2
      if restore_cloudflared_service; then
        echo "Previous cloudflared service restored." >&2
      else
        echo "Warning: automatic cloudflared rollback failed; inspect the service before retrying." >&2
        rollback_failed=1
      fi
    fi

    if [[ "$cloudflare_origin_mutated" -eq 1 ]]; then
      echo "Restoring the previous OpenClaw allowed origins..." >&2
      if restore_cloudflare_origin; then
        echo "Previous OpenClaw allowed origins restored." >&2
      else
        echo "Warning: automatic allowed-origin rollback failed; inspect the Gateway before retrying." >&2
        rollback_failed=1
      fi
    fi
  fi

  # Origin rollback restarts the Gateway and can terminate its Chromium child,
  # so restore the browser's original running state only after all rollbacks.
  if ! restore_browser_original_state \
    "$browser_was_managed_before_hardening" \
    "$browser_was_running_before_hardening"; then
    browser_restore_failed=1
    [[ "$exit_status" -ne 0 ]] || exit_status=1
  fi

  if [[ "$rollback_failed" -eq 0 ]]; then
    case "$cloudflared_rollback_backup" in
    /run/openclaw-cloudflared-unit.*)
      rm -f -- "$cloudflared_rollback_backup"
      ;;
    esac
    case "$cloudflared_rollback_token_backup" in
    /run/openclaw-cloudflared-token.*)
      rm -f -- "$cloudflared_rollback_token_backup"
      ;;
    esac
  else
    echo "Rollback files were preserved under /run/openclaw-cloudflared-* (root-only)." >&2
    [[ "$exit_status" -ne 0 ]] || exit_status=1
  fi

  if [[ "$browser_restore_failed" -eq 1 ]]; then
    echo "Warning: the browser state from before setup was not restored." >&2
  fi

  exit "$exit_status"
}

trap cleanup_cloudflared_transaction EXIT

function fail() {
  echo "Error: $*" >&2
  exit 1
}

function require_root_and_tty() {
  [[ "$EUID" -eq 0 ]] || fail "Run this wizard as root."
  [[ -t 0 && -t 1 ]] || fail "This wizard requires an interactive terminal. Run: pct enter <CTID>"
  [[ -x "$OPENCLAW_BIN" ]] || fail "OpenClaw is not installed at ${OPENCLAW_BIN}."
}

function show_message() {
  local title="$1"
  local message="$2"
  whiptail --backtitle "$BACKTITLE" --title "$title" --msgbox "$message" 18 78
}

function ask_yes_no() {
  local title="$1"
  local message="$2"
  whiptail --backtitle "$BACKTITLE" --title "$title" --yesno "$message" 16 78
}

function ask_yes_no_default_no() {
  local title="$1"
  local message="$2"
  whiptail --backtitle "$BACKTITLE" --title "$title" --defaultno --yesno "$message" 18 78
}

function ensure_user_manager() {
  local openclaw_uid
  openclaw_uid=$(id -u "$OPENCLAW_USER") || return 1

  loginctl enable-linger "$OPENCLAW_USER" >/dev/null 2>&1 || true
  systemctl start "user@${openclaw_uid}.service" >/dev/null 2>&1 || true

  for _ in {1..20}; do
    [[ -S "/run/user/${openclaw_uid}/bus" ]] && return 0
    sleep 0.25
  done

  echo "Error: the systemd user manager for ${OPENCLAW_USER} is unavailable." >&2
  return 1
}

function run_as_openclaw() {
  local openclaw_uid
  openclaw_uid=$(id -u "$OPENCLAW_USER") || return 1
  ensure_user_manager || return 1

  runuser -u "$OPENCLAW_USER" -- env -i \
    HOME="$OPENCLAW_USER_HOME" \
    USER="$OPENCLAW_USER" \
    LOGNAME="$OPENCLAW_USER" \
    SHELL=/bin/bash \
    LANG=C.UTF-8 \
    TERM="${TERM:-xterm-256color}" \
    XDG_RUNTIME_DIR="/run/user/${openclaw_uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${openclaw_uid}/bus" \
    PATH="${OPENCLAW_USER_HOME}/.local/bin:${OPENCLAW_STATE_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

function openclaw_cli() {
  run_as_openclaw "$OPENCLAW_BIN" "$@"
}

function openclaw_cli_bounded() {
  run_as_openclaw /usr/bin/timeout --foreground --kill-after=5s 30s \
    "$OPENCLAW_BIN" "$@"
}

function openclaw_cli_quick() {
  run_as_openclaw /usr/bin/timeout --foreground --kill-after=1s 3s \
    "$OPENCLAW_BIN" "$@"
}

function openclaw_cli_browser_bounded() {
  run_as_openclaw /usr/bin/timeout --foreground --kill-after=5s 60s \
    "$OPENCLAW_BIN" "$@"
}

function openclaw_cli_service_bounded() {
  run_as_openclaw /usr/bin/timeout --foreground --kill-after=5s 60s \
    "$OPENCLAW_BIN" "$@"
}

function read_optional_config_value() {
  local config_output
  local config_path="$1"

  optional_config_value_found=0
  optional_config_value_json=""
  if config_output=$(openclaw_cli config get "$config_path" --json 2>&1); then
    if ! jq -e . <<<"$config_output" >/dev/null 2>&1; then
      echo "Config path ${config_path} did not return valid JSON." >&2
      return 1
    fi
    optional_config_value_found=1
    optional_config_value_json="$config_output"
    return 0
  fi
  if grep -Fq "Config path not found: ${config_path}" <<<"$config_output"; then
    return 0
  fi

  [[ -z "$config_output" ]] || printf '%s\n' "$config_output" >&2
  return 1
}

function get_optional_config_object() {
  local config_path="$1"

  read_optional_config_value "$config_path" || return 1
  if [[ "$optional_config_value_found" -eq 0 ]]; then
    printf '{}\n'
    return 0
  fi
  if ! jq -e 'type == "object"' <<<"$optional_config_value_json" >/dev/null 2>&1; then
    echo "Config path ${config_path} is not an object." >&2
    return 1
  fi
  printf '%s\n' "$optional_config_value_json"
}

function has_persisted_session_exec_overrides() {
  local has_session_override
  local session_store
  local sessions_json
  local total_entries
  local -a session_stores=()

  sessions_json=$(openclaw_cli sessions --all-agents --limit all --json) || return 2
  if ! jq -e '
    type == "object" and
    (.totalCount | type == "number" and floor == . and . >= 0) and
    (.hasMore == false) and
    (.stores | type == "array")
  ' <<<"$sessions_json" >/dev/null 2>&1; then
    return 2
  fi
  total_entries=$(jq -r '.totalCount' <<<"$sessions_json") || return 2
  [[ "$total_entries" -gt 0 ]] || return 1

  # Stable OpenClaw stores session-only /exec overrides in sessions.json. If a
  # newer release reports a database-backed or otherwise unfamiliar store,
  # fail closed instead of claiming that the global preset is the whole policy.
  if jq -e '
    any(.stores[]?; (.databasePath? // null) != null) or
    any(.sessions[]?; (.databasePath? // null) != null)
  ' <<<"$sessions_json" >/dev/null 2>&1; then
    return 0
  fi
  mapfile -t session_stores < <(
    jq -r '.stores[]?.path | select(type == "string")' <<<"$sessions_json"
  )
  ((${#session_stores[@]} > 0)) || return 0

  for session_store in "${session_stores[@]}"; do
    case "$session_store" in
    *.json) ;;
    *) return 0 ;;
    esac
    if [[ -L "$session_store" || ! -f "$session_store" ]]; then
      return 0
    fi
    has_session_override=$(run_as_openclaw /usr/bin/jq -r '
      if type != "object" then error("session store is not an object")
      else any(.[];
        type == "object" and
        (
          has("execHost") or
          has("execSecurity") or
          has("execAsk") or
          has("execNode") or
          (has("inheritedToolAllow") and .inheritedToolAllow != null and
            ((.inheritedToolAllow | length) > 0)) or
          (has("inheritedToolDeny") and .inheritedToolDeny != null and
            ((.inheritedToolDeny | length) > 0)) or
          (has("toolOverrides") and .toolOverrides != null and
            ((.toolOverrides | length) > 0))
        )
      )
      end
    ' "$session_store") || return 2
    if [[ "$has_session_override" == "true" ]]; then
      return 0
    fi
    [[ "$has_session_override" == "false" ]] || return 2
  done

  return 1
}

function get_tool_policy_snapshot() {
  local agents_json
  local gateway_json
  local tools_json

  tools_json=$(get_optional_config_object tools) || return 1
  agents_json=$(get_optional_config_object agents) || return 1
  gateway_json=$(get_optional_config_object gateway) || return 1
  jq -cn \
    --argjson tools "$tools_json" \
    --argjson agents "$agents_json" \
    --argjson gateway "$gateway_json" \
    '{tools:$tools,agents:$agents,gateway:$gateway}'
}

function has_restrictive_custom_tool_policy() {
  local approvals_json
  local exec_policy_json
  local policy_json
  local jq_status
  local session_policy_status

  policy_json=$(get_tool_policy_snapshot) || return 2
  if jq -e '
    ((.tools.profile? // "coding") as $profile | ($profile != "coding" and $profile != "full")) or
    (.tools.allow? != null) or
    (((.tools.deny? // []) | length) > 0) or
    (.tools.byProvider? != null) or
    (.tools.toolsBySender? != null) or
    (.tools.sandbox.tools? != null) or
    (.gateway.tools.allow? != null) or
    (((.gateway.tools.deny? // []) | length) > 0) or
    ([.agents.list[]? | select(.tools? != null)] | length > 0) or
    ([.agents.entries[]? | select(.tools? != null)] | length > 0) or
    ((.agents.defaults.sandbox.mode? // "off") != "off") or
    ([.agents.list[]? | select(((.sandbox.mode? // "off") != "off"))] | length > 0) or
    ([.agents.entries[]? | select(((.sandbox.mode? // "off") != "off"))] | length > 0)
  ' <<<"$policy_json" >/dev/null; then
    return 0
  else
    jq_status=$?
  fi
  if [[ "$jq_status" -ne 1 ]]; then
    return 2
  fi

  if has_persisted_session_exec_overrides; then
    return 0
  else
    session_policy_status=$?
    [[ "$session_policy_status" -eq 1 ]] || return 2
  fi

  approvals_json=$(openclaw_cli approvals get --json) || return 2
  if ! jq -e '
    type == "object" and
    (.file | type == "object") and
    ((.file.agents? // {}) | type == "object")
  ' <<<"$approvals_json" >/dev/null 2>&1; then
    return 2
  fi
  if jq -e '
    [(.file.agents.main? // {}), (.file.agents["*"]? // {})]
    | any(.[]; has("security") or has("ask") or has("askFallback"))
  ' <<<"$approvals_json" >/dev/null; then
    return 0
  else
    jq_status=$?
  fi
  [[ "$jq_status" -eq 1 ]] || return 2

  exec_policy_json=$(openclaw_cli exec-policy show --json) || return 2
  if jq -e '
    ([.effectivePolicy.scopes[]? | select(.scopeLabel != "tools.exec")] | length > 0) or
    ([.effectivePolicy.scopes[]? |
      select(
        ([.security.hostSource?, .ask.hostSource?, .askFallback.source?]
          | any(. != null and test(" agents\\.(main|\\*)\\.")))
      )
    ] | length > 0)
  ' <<<"$exec_policy_json" >/dev/null; then
    return 0
  else
    jq_status=$?
  fi
  [[ "$jq_status" -eq 1 ]] && return 1
  return 2
}

function has_browser_custom_tool_policy() {
  local policy_json
  local jq_status

  policy_json=$(get_tool_policy_snapshot) || return 2
  if jq -e '
    ((.tools.profile? // "coding") as $profile | ($profile != "coding" and $profile != "full")) or
    (.tools.allow? != null) or
    (((.tools.deny? // []) | length) > 0) or
    (.tools.byProvider? != null) or
    (.tools.toolsBySender? != null) or
    (.tools.sandbox.tools? != null) or
    (.gateway.tools.allow? != null) or
    (((.gateway.tools.deny? // []) | length) > 0) or
    ([.agents.list[]? | select(.tools? != null)] | length > 0) or
    ([.agents.entries[]? | select(.tools? != null)] | length > 0) or
    ((.agents.defaults.sandbox.mode? // "off") != "off") or
    ([.agents.list[]? | select(((.sandbox.mode? // "off") != "off"))] | length > 0) or
    ([.agents.entries[]? | select(((.sandbox.mode? // "off") != "off"))] | length > 0)
  ' <<<"$policy_json" >/dev/null; then
    return 0
  else
    jq_status=$?
  fi
  [[ "$jq_status" -eq 1 ]] && return 1
  return 2
}

function ensure_gateway_token() {
  local gateway_token

  if [[ -L "$OPENCLAW_ENV_FILE" || (-e "$OPENCLAW_ENV_FILE" && ! -f "$OPENCLAW_ENV_FILE") ]]; then
    fail "Refusing to replace the unexpected object at ${OPENCLAW_ENV_FILE}."
  fi

  if ! gateway_token=$(run_as_openclaw /bin/bash -c '
    set -Eeuo pipefail
    set +x
    readonly env_file="$HOME/.openclaw/.env"
    env_tmp=""
    token=""

    cleanup_env_tmp() {
      if [[ -n "$env_tmp" ]]; then
        rm -f -- "$env_tmp"
      fi
    }
    trap cleanup_env_tmp EXIT

    if [[ -L "$env_file" || (-e "$env_file" && ! -f "$env_file") ]]; then
      echo "Unexpected OpenClaw environment-file object." >&2
      exit 1
    fi
    if [[ -f "$env_file" ]]; then
      token=$(awk '\''/^OPENCLAW_GATEWAY_TOKEN=/{ sub(/^OPENCLAW_GATEWAY_TOKEN=/, ""); value = $0 } END { if (value != "") print value }'\'' "$env_file")
    fi
    [[ -n "$token" ]] || token=$(openssl rand -hex 32)

    umask 077
    env_tmp=$(mktemp "$HOME/.openclaw/.env.tmp.XXXXXX")
    if [[ -f "$env_file" ]]; then
      awk '\''!/^OPENCLAW_GATEWAY_TOKEN=/'\'' "$env_file" >"$env_tmp"
    fi
    printf '\''OPENCLAW_GATEWAY_TOKEN=%s\n'\'' "$token" >>"$env_tmp"
    chmod 600 "$env_tmp"
    mv -fT -- "$env_tmp" "$env_file"
    env_tmp=""
    printf '\''%s\n'\'' "$token"
  '); then
    fail "The Gateway token file could not be normalized safely as ${OPENCLAW_USER}."
  fi
  printf '%s\n' "$gateway_token"
  unset gateway_token
}

function initialize_gateway() {
  local gateway_token
  local openclaw_uid
  openclaw_uid=$(id -u "$OPENCLAW_USER")

  if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
    if ! ask_yes_no "Security Notice" \
      "OpenClaw agents can read files, run tools, and use passwordless sudo for full administrative control inside this dedicated LXC. The unprivileged LXC remains the boundary from the Proxmox host.\n\nContinue and create the local Gateway?"; then
      echo "Setup cancelled. Run openclaw-setup when you are ready."
      exit 2
    fi
  fi

  if [[ -L "$OPENCLAW_STATE_DIR" || (-e "$OPENCLAW_STATE_DIR" && ! -d "$OPENCLAW_STATE_DIR") ]]; then
    fail "Refusing to use the unexpected object at ${OPENCLAW_STATE_DIR}."
  fi
  run_as_openclaw /usr/bin/install -d -m 700 "$OPENCLAW_STATE_DIR"
  umask 077
  gateway_token=$(ensure_gateway_token)

  if [[ -f "$OPENCLAW_CONFIG" ]]; then
    openclaw_cli config set gateway.auth.mode token
    openclaw_cli config set gateway.auth.token \
      --ref-provider default \
      --ref-source env \
      --ref-id OPENCLAW_GATEWAY_TOKEN
    openclaw_cli config validate
    unset gateway_token
    return 0
  fi

  clear
  echo "Initializing the loopback-only OpenClaw Gateway..."
  if ! runuser -u "$OPENCLAW_USER" -- env -i \
    HOME="$OPENCLAW_USER_HOME" \
    USER="$OPENCLAW_USER" \
    LOGNAME="$OPENCLAW_USER" \
    SHELL=/bin/bash \
    LANG=C.UTF-8 \
    TERM="${TERM:-xterm-256color}" \
    XDG_RUNTIME_DIR="/run/user/${openclaw_uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${openclaw_uid}/bus" \
    PATH="${OPENCLAW_USER_HOME}/.local/bin:${OPENCLAW_STATE_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    OPENCLAW_GATEWAY_TOKEN="$gateway_token" \
    "$OPENCLAW_BIN" onboard \
    --non-interactive \
    --accept-risk \
    --mode local \
    --workspace "${OPENCLAW_STATE_DIR}/workspace" \
    --auth-choice skip \
    --gateway-port 18789 \
    --gateway-bind loopback \
    --gateway-auth token \
    --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
    --tailscale off \
    --no-install-daemon \
    --skip-health \
    --skip-channels \
    --skip-skills \
    --skip-search \
    --skip-ui \
    --skip-hooks \
    --suppress-gateway-token-output \
    --json; then
    unset gateway_token
    fail "OpenClaw baseline onboarding failed. Re-run openclaw-setup after reviewing the output."
  fi
  unset gateway_token
  gateway_created_this_run=1

  # Onboarding defaults to permissive local exec. Persist a cautious baseline
  # before any model credentials are added or a daemon can be started. The
  # interactive policy step may deliberately replace it with full control.
  apply_system_control_policy auto allowlist on-miss deny cautious ||
    fail "The initial cautious command policy could not be established. No Gateway daemon was installed."
}

function configure_codex() {
  local set_default="${1:-yes}"
  local args=(models auth login --provider openai --device-code)
  [[ "$set_default" == "yes" ]] && args+=(--set-default)

  clear
  echo "Codex device-code sign-in"
  echo
  echo "Open the URL shown below on another device and enter the short-lived code."
  echo "This command waits until you confirm the login in your browser."
  echo
  openclaw_cli "${args[@]}"
}

function configure_claude() {
  local set_default="${1:-yes}"
  local method
  local args

  if ! method=$(whiptail --backtitle "$BACKTITLE" --title "Claude Authentication" \
    --menu "Choose how this LXC should authenticate with Anthropic:" 18 78 5 \
    "setup-token" "Claude subscription token created with: claude setup-token" \
    "api-key" "Anthropic API key (pay-as-you-go; recommended for servers)" \
    "cli" "Reuse an existing Claude CLI login in this LXC" \
    "back" "Return without configuring Claude" \
    3>&1 1>&2 2>&3); then
    return 2
  fi

  case "$method" in
  setup-token)
    clear
    echo "On a computer with Claude Code installed, run: claude setup-token"
    echo "Then paste the resulting token into the secure OpenClaw prompt below."
    echo
    args=(models auth login --provider anthropic --method setup-token)
    ;;
  api-key)
    clear
    echo "Paste your Anthropic API key into the secure OpenClaw prompt below."
    echo
    args=(models auth login --provider anthropic --method api-key)
    ;;
  cli)
    if ! run_as_openclaw /bin/sh -c 'command -v claude >/dev/null 2>&1'; then
      show_message "Claude CLI Not Found" \
        "Claude CLI is not installed for the openclaw user.\n\nUse setup-token, or install and authenticate Claude Code in this LXC before selecting this option."
      return 1
    fi
    clear
    echo "Checking the existing Claude CLI login..."
    if ! run_as_openclaw claude auth status --text; then
      show_message "Claude Login Missing" \
        "Claude CLI is installed, but its login could not be verified for the openclaw user."
      return 1
    fi
    args=(models auth login --provider anthropic --method cli)
    ;;
  back)
    return 2
    ;;
  esac

  [[ "$set_default" == "yes" ]] && args+=(--set-default)
  openclaw_cli "${args[@]}"
}

function run_claude_flow() {
  local set_default="${1:-yes}"
  local status

  while true; do
    if configure_claude "$set_default"; then
      return 0
    else
      status=$?
    fi

    [[ "$status" -eq 2 ]] && return 2
    if ! ask_yes_no "Claude Authentication Failed" \
      "Claude authentication did not complete successfully. Retry now?"; then
      return 1
    fi
  done
}

function configure_models() {
  local claude_status
  local provider_choice
  local primary_choice

  if ! provider_choice=$(whiptail --backtitle "$BACKTITLE" --title "Model Authentication" \
    --menu "Choose the model provider flow. You can rerun this wizard later." 19 78 6 \
    "codex" "ChatGPT/Codex subscription using a device code" \
    "claude" "Claude subscription/setup token or Anthropic API key" \
    "both" "Configure both Codex and Claude" \
    "official" "Open the full official OpenClaw model wizard" \
    "skip" "Skip model authentication for now" \
    3>&1 1>&2 2>&3); then
    return 0
  fi

  case "$provider_choice" in
  codex)
    configure_codex yes
    ;;
  claude)
    if run_claude_flow yes; then
      :
    else
      claude_status=$?
      if [[ "$claude_status" -eq 2 ]]; then
        show_message "Claude Not Configured" \
          "Claude authentication was skipped. The Gateway setup can continue; re-run openclaw-setup to add it later."
      else
        fail "Claude authentication failed. Re-run openclaw-setup when you are ready to retry."
      fi
    fi
    ;;
  both)
    if ! primary_choice=$(whiptail --backtitle "$BACKTITLE" --title "Primary Model Provider" \
      --menu "Which provider should become the default?" 14 68 3 \
      "codex" "Use Codex as the default" \
      "claude" "Use Claude as the default" \
      3>&1 1>&2 2>&3); then
      return 0
    fi

    if [[ "$primary_choice" == "codex" ]]; then
      configure_codex yes
      if ! run_claude_flow no; then
        show_message "Claude Not Configured" \
          "Codex remains the default. Re-run openclaw-setup later to add Claude."
      fi
    else
      if run_claude_flow yes; then
        configure_codex no
      else
        show_message "Claude Not Configured" \
          "Claude authentication did not complete, so Codex will be configured as the default instead."
        configure_codex yes
      fi
    fi
    ;;
  official)
    clear
    openclaw_cli configure --section models
    ;;
  skip)
    return 0
    ;;
  esac

  echo
  openclaw_cli models status || true
}

function system_control_policy_matches() {
  local control_mode="$1"
  local exec_security="$2"
  local exec_ask="$3"
  local exec_fallback="$4"
  local policy_json

  policy_json=$(openclaw_cli exec-policy show --json) || return 1
  if ! jq -e \
    --arg mode "$control_mode" \
    --arg security "$exec_security" \
    --arg ask "$exec_ask" \
    --arg fallback "$exec_fallback" '
      (.effectivePolicy.scopes
        | map(select(.scopeLabel == "tools.exec"))
        | .[0]) as $policy
      | ((.effectivePolicy.scopes | length) == 1)
        and ($policy != null)
        and ($policy.runtimeApprovalsSource == "local-file")
        and ($policy.host.requested == "gateway")
        and ($policy.mode.requested == $mode)
        and ($policy.mode.effective == $mode)
        and ($policy.security.effective == $security)
        and ($policy.ask.effective == $ask)
        and ($policy.askFallback.effective == $fallback)
        and ($policy.security.hostSource | endswith(" defaults.security"))
        and ($policy.ask.hostSource | endswith(" defaults.ask"))
        and ($policy.askFallback.source | endswith(" defaults.askFallback"))
    ' <<<"$policy_json" >/dev/null; then
    printf '%s\n' "$policy_json" >&2
    return 1
  fi
}

function apply_system_control_policy() {
  local control_mode="$1"
  local exec_security="$2"
  local exec_ask="$3"
  local exec_fallback="$4"
  local exec_preset="$5"

  # OpenClaw 2026.7.1-2 cannot store the canonical mode alongside its legacy
  # security/ask fields. Transition through a valid legacy representation,
  # synchronize the approvals file, then persist only the canonical mode.
  jq -cn \
    --arg security "$exec_security" \
    --arg ask "$exec_ask" \
    '{
      tools: {
        exec: {
          host: "gateway",
          mode: null,
          security: $security,
          ask: $ask
        }
      }
    }' |
    openclaw_cli config patch --stdin || return 1

  openclaw_cli exec-policy preset "$exec_preset" --json >/dev/null || return 1

  jq -cn \
    --arg mode "$control_mode" \
    '{
      tools: {
        exec: {
          host: "gateway",
          mode: $mode,
          security: null,
          ask: null
        }
      }
    }' |
    openclaw_cli config patch --stdin || return 1

  openclaw_cli config validate || return 1
  system_control_policy_matches "$control_mode" "$exec_security" \
    "$exec_ask" "$exec_fallback"
}

function verify_selected_system_control_policy() {
  local custom_policy_status

  case "$system_control_mode" in
  auto)
    set -- auto allowlist on-miss deny
    ;;
  full)
    set -- full full off full
    ;;
  unchanged)
    return 0
    ;;
  *)
    return 1
    ;;
  esac

  if has_restrictive_custom_tool_policy; then
    return 1
  else
    custom_policy_status=$?
    [[ "$custom_policy_status" -eq 1 ]] || return 1
  fi
  system_control_policy_matches "$@"
}

function configure_system_control() {
  local custom_policy_status=0
  local exec_ask
  local exec_config_json="{}"
  local exec_fallback
  local exec_preset
  local exec_security
  local control_choice
  local offer_keep=0
  local policy_json
  local -a policy_options=(
    "auto" "Automatic review; ask you only when a command remains uncertain (recommended)"
    "full" "No command approvals; passwordless sudo gives full control of this LXC"
  )

  if has_restrictive_custom_tool_policy; then
    custom_policy_status=1
  else
    case "$?" in
    1) custom_policy_status=0 ;;
    *) fail "The existing tool policy could not be inspected safely." ;;
    esac
  fi

  # Offer Keep for an existing explicit exec policy or any policy the wizard
  # cannot safely rewrite. Fresh onboarding's temporary cautious baseline is
  # intentionally not presented as a user-authored policy.
  read_optional_config_value tools.exec ||
    fail "The existing tools.exec policy could not be inspected safely."
  if [[ "$optional_config_value_found" -eq 1 ]]; then
    exec_config_json="$optional_config_value_json"
    if ! jq -e 'type == "object"' <<<"$exec_config_json" >/dev/null 2>&1; then
      fail "Existing tools.exec is not an object; fix it before configuring system control."
    fi
    if jq -e 'has("mode") or has("security") or has("ask")' \
      <<<"$exec_config_json" >/dev/null 2>&1; then
      offer_keep=1
    fi
  fi
  [[ "$custom_policy_status" -eq 0 ]] || offer_keep=1
  [[ "$gateway_created_this_run" -eq 0 ]] || offer_keep=0
  if [[ "$offer_keep" -eq 1 ]]; then
    policy_options+=(
      "keep" "Keep the existing custom tool and exec policies unchanged"
    )
  fi

  while true; do
    if ! control_choice=$(whiptail --backtitle "$BACKTITLE" --title "LXC System Control" \
      --default-item auto \
      --menu "Gateway and Chromium remain under the openclaw account. Commands allowed by this policy may use passwordless sudo to administer the whole LXC." 20 88 3 \
      "${policy_options[@]}" \
      3>&1 1>&2 2>&3); then
      echo "Setup cancelled before the system-command policy was changed."
      exit 2
    fi

    case "$control_choice" in
    auto)
      if [[ "$custom_policy_status" -eq 1 ]]; then
        show_message "Custom Tool Policy Preserved" \
          "Existing allow/deny, provider, sender, per-agent, sandbox, or per-agent approval overrides may block or alter exec. The wizard will not overwrite them or claim full LXC control. Choose Keep if available, or cancel and review the custom policy first."
        continue
      fi
      exec_security="allowlist"
      exec_ask="on-miss"
      exec_fallback="deny"
      exec_preset="cautious"
      break
      ;;
    full)
      if [[ "$custom_policy_status" -eq 1 ]]; then
        show_message "Custom Tool Policy Preserved" \
          "Existing allow/deny, provider, sender, per-agent, sandbox, or per-agent approval overrides may block or alter exec. The wizard will not overwrite them or claim full LXC control. Choose Keep if available, or cancel and review the custom policy first."
        continue
      fi
      if ! ask_yes_no_default_no "Unattended Root Control" \
        "This permits OpenClaw to run any command and passwordless sudo inside the LXC without asking you first. A malicious page, prompt, plugin, or model action could take over the entire container. It still does not grant Proxmox-host root by itself.\n\nEnable fully autonomous system control?"; then
        show_message "Full Control Not Enabled" \
          "No policy was changed. Choose automatic review, keep an existing policy, or confirm fully autonomous control."
        continue
      fi
      exec_security="full"
      exec_ask="off"
      exec_fallback="full"
      exec_preset="yolo"
      break
      ;;
    keep)
      openclaw_cli config validate
      policy_json=$(openclaw_cli exec-policy show --json)
      if ! jq -e '
        (.effectivePolicy.scopes
          | map(select(.scopeLabel == "tools.exec"))
          | .[0]) as $policy
        | ($policy != null)
          and ((["auto", "sandbox", "gateway", "node"]
            | index($policy.host.requested)) != null)
          and ((["deny", "allowlist", "ask", "auto", "full"]
            | index($policy.mode.requested)) != null)
      ' <<<"$policy_json" >/dev/null; then
        openclaw_cli exec-policy show || true
        fail "The existing exec policy could not be resolved safely."
      fi
      if [[ "$custom_policy_status" -eq 1 ]] || jq -e '
        any(.effectivePolicy.scopes[]?;
          .security.effective == "full" and .ask.effective == "off"
        )
      ' <<<"$policy_json" >/dev/null 2>&1; then
        if ! ask_yes_no_default_no "Keep Existing System Policy" \
          "The existing custom, per-agent, approval-file, or session policy may permit unattended commands with passwordless sudo, or may prevent the wizard from determining the exact effective policy for every session.\n\nKeep it unchanged and continue setup?"; then
          continue
        fi
      fi
      system_control_mode="unchanged"
      echo
      openclaw_cli exec-policy show
      return 0
      ;;
    *)
      fail "Unexpected system-command policy selection: ${control_choice}"
      ;;
    esac
  done

  if ! apply_system_control_policy "$control_choice" "$exec_security" \
    "$exec_ask" "$exec_fallback" "$exec_preset"; then
    openclaw_cli exec-policy show || true
    fail "The effective exec policy does not match the selected ${control_choice} mode."
  fi
  system_control_mode="$control_choice"
  echo
  openclaw_cli exec-policy show
}

function harden_gateway() {
  local gateway_json
  local gateway_ready=0
  local dangerous_key

  openclaw_cli config set gateway.mode local
  openclaw_cli config set gateway.bind loopback
  openclaw_cli config set gateway.port 18789 --strict-json
  openclaw_cli config set gateway.auth.mode token
  openclaw_cli config set gateway.auth.allowTailscale false --strict-json
  openclaw_cli config set gateway.tailscale.mode off
  openclaw_cli config set gateway.trustedProxies '[]' --strict-json
  for dangerous_key in \
    gateway.controlUi.allowInsecureAuth \
    gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback \
    gateway.controlUi.dangerouslyDisableDeviceAuth \
    gateway.allowRealIpFallback; do
    read_optional_config_value "$dangerous_key" ||
      fail "The existing Gateway safety flags could not be inspected safely."
    if [[ "$optional_config_value_found" -eq 1 ]]; then
      openclaw_cli config unset "$dangerous_key"
    fi
  done
  openclaw_cli config validate
  gateway_json=$(openclaw_cli config get gateway --json)
  if ! jq -e '
    (.controlUi.allowInsecureAuth? != true) and
    (.controlUi.dangerouslyAllowHostHeaderOriginFallback? != true) and
    (.controlUi.dangerouslyDisableDeviceAuth? != true) and
    (.allowRealIpFallback? != true)
  ' <<<"$gateway_json" >/dev/null; then
    fail "A dangerous Gateway compatibility flag remained enabled after hardening."
  fi
  openclaw_cli_service_bounded gateway install --force

  # gateway install --force activates the replacement service. Restarting it a
  # second time can interrupt startup migrations, so wait for readiness instead.
  for _ in {1..40}; do
    if curl --connect-timeout 1 --max-time 2 -fsS \
      http://127.0.0.1:18789/readyz >/dev/null 2>&1; then
      gateway_ready=1
      break
    fi
    sleep 0.5
  done
  [[ "$gateway_ready" -eq 1 ]] || fail "The Gateway service did not become ready after installation."
}

function restart_gateway_and_wait() {
  local gateway_ready=0

  if ! openclaw_cli_bounded gateway restart; then
    echo "Error: the Gateway restart command failed." >&2
    return 1
  fi
  for _ in {1..40}; do
    if curl --connect-timeout 1 --max-time 2 -fsS \
      http://127.0.0.1:18789/readyz >/dev/null 2>&1; then
      gateway_ready=1
      break
    fi
    sleep 0.5
  done

  if [[ "$gateway_ready" -ne 1 ]]; then
    echo "Error: the Gateway did not become ready after its restart." >&2
    return 1
  fi
}

function is_local_managed_browser_status() {
  local status_json="$1"

  jq -e '
    .enabled == true and
    .profile == "openclaw" and
    .driver == "openclaw" and
    .transport == "cdp" and
    .attachOnly == false and
    .headless == true and
    .executablePath == "/usr/bin/chromium" and
    (.cdpUrl | test("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]+$"))
  ' <<<"$status_json" >/dev/null 2>&1
}

function verify_managed_browser_process_owner() {
  local browser_pid
  local openclaw_uid
  local status_json

  status_json=$(openclaw_cli_quick browser --browser-profile openclaw --json status 2>/dev/null) || return 1
  is_local_managed_browser_status "$status_json" || return 1
  browser_pid=$(jq -er '
    .pid
    | select(type == "number" and . > 0 and floor == .)
    | tostring
  ' <<<"$status_json") || return 1
  [[ -d "/proc/${browser_pid}" ]] || return 1

  openclaw_uid=$(id -u "$OPENCLAW_USER")
  [[ "$(stat -c '%u' "/proc/${browser_pid}")" == "$openclaw_uid" ]]
}

function probe_managed_browser() {
  local failed=0
  local output=""

  browser_probe_output=""

  if output=$(openclaw_cli_browser_bounded browser --browser-profile openclaw stop 2>&1); then
    [[ -z "$output" ]] || printf '%s\n' "$output"
  else
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2
    browser_probe_output+="${output}"$'\n'
    failed=1
  fi
  if [[ "$failed" -eq 0 ]] && ! wait_for_managed_browser_running_state false; then
    browser_probe_output+="Managed Chromium did not reach a verified stopped state before its live check."$'\n'
    failed=1
  fi
  if [[ "$failed" -eq 0 ]] && output=$(openclaw_cli_browser_bounded browser --browser-profile openclaw start 2>&1); then
    [[ -z "$output" ]] || printf '%s\n' "$output"
  elif [[ "$failed" -eq 0 ]]; then
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2
    browser_probe_output+="${output}"$'\n'
    failed=1
  fi
  if [[ "$failed" -eq 0 ]]; then
    if output=$(openclaw_cli_browser_bounded browser --browser-profile openclaw doctor --deep 2>&1); then
      [[ -z "$output" ]] || printf '%s\n' "$output"
    else
      [[ -z "$output" ]] || printf '%s\n' "$output" >&2
      browser_probe_output+="${output}"$'\n'
      failed=1
    fi
  fi
  if [[ "$failed" -eq 0 ]] && ! verify_managed_browser_process_owner; then
    browser_probe_output+="Managed Chromium was not verified as a process owned by the openclaw user."$'\n'
    failed=1
  fi
  if output=$(openclaw_cli_browser_bounded browser --browser-profile openclaw stop 2>&1); then
    [[ -z "$output" ]] || printf '%s\n' "$output"
  else
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2
    browser_probe_output+="${output}"$'\n'
    failed=1
  fi
  if ! wait_for_managed_browser_running_state false; then
    browser_probe_output+="Managed Chromium did not return to a verified stopped state after its live check."$'\n'
    failed=1
  fi

  return "$failed"
}

function wait_for_managed_browser_running_state() {
  local expected_running="$1"
  local status_json=""

  case "$expected_running" in
  1) expected_running=true ;;
  0) expected_running=false ;;
  true | false) ;;
  *) return 1 ;;
  esac

  for _ in {1..20}; do
    if status_json=$(openclaw_cli_quick browser --browser-profile openclaw --json status 2>/dev/null) &&
      is_local_managed_browser_status "$status_json" &&
      jq -e --argjson expected_running "$expected_running" \
        '.running == $expected_running' <<<"$status_json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done

  return 1
}

function restore_browser_original_state() {
  local browser_was_managed="$1"
  local browser_was_running="$2"
  local status_json=""

  [[ "$browser_was_managed" -eq 1 ]] || return 0
  if ! status_json=$(openclaw_cli_quick browser --browser-profile openclaw --json status 2>/dev/null); then
    echo "Warning: the browser state from before setup could not be read or restored." >&2
    return 1
  fi
  if ! is_local_managed_browser_status "$status_json"; then
    echo "Warning: the browser route changed during setup, so its prior running state was not changed automatically." >&2
    return 1
  fi
  if [[ "$browser_was_running" -eq 0 ]] &&
    jq -e '.running == false' <<<"$status_json" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$browser_was_running" -eq 1 ]] &&
    jq -e '.running == true' <<<"$status_json" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$browser_was_running" -eq 1 ]]; then
    if ! openclaw_cli_browser_bounded browser --browser-profile openclaw start; then
      echo "Warning: the browser was running before setup, but its running state could not be restored." >&2
      echo "Run 'openclaw browser --browser-profile openclaw start' for details." >&2
      return 1
    fi
  else
    if ! openclaw_cli_browser_bounded browser --browser-profile openclaw stop; then
      echo "Warning: the browser was stopped before setup, but it could not be stopped again automatically." >&2
      echo "Run 'openclaw browser --browser-profile openclaw stop' for details." >&2
      return 1
    fi
  fi
  if wait_for_managed_browser_running_state "$browser_was_running"; then
    return 0
  fi

  echo "Warning: OpenClaw accepted the browser state restoration request, but the result was not verified." >&2
  return 1
}

function capture_browser_running_state() {
  local browser_config_json
  local browser_config_claims_managed=0
  local status_json=""

  # A fresh onboarding deliberately has no daemon yet, so there is no prior
  # browser process whose state needs preserving.
  [[ "$gateway_created_this_run" -eq 0 ]] || return 0

  browser_config_json=$(get_optional_config_object browser) ||
    fail "The existing browser configuration could not be inspected safely."
  if jq -e '
    .enabled == true and
    (.defaultProfile // "openclaw") == "openclaw" and
    (.attachOnly // false) == false and
    .headless == true and
    .executablePath == "/usr/bin/chromium"
  ' <<<"$browser_config_json" >/dev/null 2>&1; then
    browser_config_claims_managed=1
  fi

  if status_json=$(openclaw_cli_quick browser --browser-profile openclaw --json status 2>&1) &&
    is_local_managed_browser_status "$status_json"; then
    browser_was_managed_before_hardening=1
    if jq -e '.running == true' <<<"$status_json" >/dev/null 2>&1; then
      browser_was_running_before_hardening=1
    fi
  elif [[ "$browser_config_claims_managed" -eq 1 ]]; then
    [[ -z "$status_json" ]] || printf '%s\n' "$status_json" >&2
    fail "Managed Chromium is configured, but its running state could not be captured safely before setup."
  fi
}

function browser_failure_looks_like_sandbox() {
  grep -Eiq \
    'no usable sandbox|suid sandbox helper|setuid_sandbox|zygote_host_impl_linux|failed to move to new namespace|namespace.*(operation not permitted|permission denied)|sandbox.*(failed|unavailable|not available|permission denied)' \
    <<<"$browser_probe_output"
}

function prepare_managed_browser_overrides() {
  local clear_extra_args=0
  local extra_args=""
  local has_custom_profile=0
  local has_legacy_cdp_url=0
  local remove_custom_route=0
  local ssrf_key
  local ssrf_policy=""

  read_optional_config_value browser.profiles.openclaw ||
    fail "The existing openclaw browser profile could not be inspected safely."
  if [[ "$optional_config_value_found" -eq 1 ]]; then
    has_custom_profile=1
  fi
  read_optional_config_value browser.cdpUrl ||
    fail "The existing browser CDP route could not be inspected safely."
  if [[ "$optional_config_value_found" -eq 1 ]]; then
    has_legacy_cdp_url=1
  fi
  if [[ "$has_custom_profile" -eq 1 || "$has_legacy_cdp_url" -eq 1 ]]; then
    if ! ask_yes_no_default_no "Existing Browser Route" \
      "An existing custom route for the openclaw browser profile would override this LXC's local Chromium settings.\n\nReplace that route with the implicit local, loopback-only managed profile? Browser data is not deleted."; then
      show_message "Browser Unchanged" \
        "The existing custom browser route was preserved. The LXC browser preset was not applied."
      return 2
    fi
    remove_custom_route=1
  fi

  read_optional_config_value browser.extraArgs ||
    fail "The existing Chromium arguments could not be inspected safely."
  if [[ "$optional_config_value_found" -eq 1 ]]; then
    extra_args="$optional_config_value_json"
    if ! jq -e 'type == "array"' <<<"$extra_args" >/dev/null 2>&1; then
      fail "Existing browser.extraArgs is not an array; fix it before applying the managed browser preset."
    fi
    if jq -e 'length > 0' <<<"$extra_args" >/dev/null 2>&1; then
      if ! ask_yes_no_default_no "Custom Chromium Arguments" \
        "browser.extraArgs is not empty. Custom Chromium flags can alter its sandbox, profile, proxy, or debugging endpoint, so the wizard cannot certify the managed preset while keeping them.\n\nRemove the entire existing browser.extraArgs array and continue?"; then
        show_message "Browser Unchanged" \
          "The existing Chromium overrides were preserved. The LXC browser preset was not applied."
        return 2
      fi
      clear_extra_args=1
    fi
  fi

  read_optional_config_value browser.ssrfPolicy ||
    fail "The existing browser SSRF policy could not be inspected safely."
  if [[ "$optional_config_value_found" -eq 1 ]]; then
    ssrf_policy="$optional_config_value_json"
    if ! jq -e 'type == "object"' <<<"$ssrf_policy" >/dev/null 2>&1; then
      fail "Existing browser.ssrfPolicy is not an object; fix it before applying the managed browser preset."
    fi
  fi
  if [[ "$optional_config_value_found" -eq 1 ]] && jq -e '
      (.dangerouslyAllowPrivateNetwork == true) or
      (.allowPrivateNetwork == true) or
      (.allowRfc2544BenchmarkRange == true) or
      (.allowIpv6UniqueLocalRange == true) or
      (((.allowedHostnames // []) | length) > 0)
    ' <<<"$ssrf_policy" >/dev/null 2>&1; then
    if ! ask_yes_no_default_no "Private-network Browser Access" \
      "The existing browser policy broadens access to private or internal destinations through a general opt-in or hostname exceptions.\n\nKeep those exceptions? Choosing No removes them and restores OpenClaw's normal private-network blocking."; then
      for ssrf_key in \
        dangerouslyAllowPrivateNetwork \
        allowPrivateNetwork \
        allowRfc2544BenchmarkRange \
        allowIpv6UniqueLocalRange; do
        if jq -e --arg key "$ssrf_key" '.[$key] == true' <<<"$ssrf_policy" >/dev/null; then
          openclaw_cli config unset "browser.ssrfPolicy.${ssrf_key}" ||
            fail "The existing browser SSRF exception could not be removed safely."
        fi
      done
      if jq -e '((.allowedHostnames // []) | length) > 0' <<<"$ssrf_policy" >/dev/null; then
        openclaw_cli config unset browser.ssrfPolicy.allowedHostnames ||
          fail "The existing browser hostname exceptions could not be removed safely."
      fi
    fi
  fi

  if [[ "$remove_custom_route" -eq 1 ]]; then
    if [[ "$has_custom_profile" -eq 1 ]]; then
      openclaw_cli config unset browser.profiles.openclaw ||
        fail "The existing custom browser profile could not be removed safely."
    fi
    if [[ "$has_legacy_cdp_url" -eq 1 ]]; then
      openclaw_cli config unset browser.cdpUrl ||
        fail "The existing browser CDP route could not be removed safely."
    fi
  fi
  if [[ "$clear_extra_args" -eq 1 ]]; then
    openclaw_cli config unset browser.extraArgs ||
      fail "The existing Chromium arguments could not be removed safely."
  fi
  return 0
}

function validate_managed_browser_status() {
  local expected_no_sandbox="$1"
  local status_json

  if ! status_json=$(openclaw_cli_quick browser --browser-profile openclaw --json status); then
    return 1
  fi

  if ! jq -e --argjson expected_no_sandbox "$expected_no_sandbox" '
    .enabled == true and
    .profile == "openclaw" and
    .driver == "openclaw" and
    .transport == "cdp" and
    .attachOnly == false and
    .headless == true and
    .noSandbox == $expected_no_sandbox and
    .executablePath == "/usr/bin/chromium" and
    (.cdpUrl | test("^http://(127\\.0\\.0\\.1|localhost|\\[::1\\]):[0-9]+$"))
  ' <<<"$status_json" >/dev/null; then
    printf '%s\n' "$status_json" >&2
    return 1
  fi
}

function enable_browser_agent_tool() {
  local custom_policy_status
  local current_tools='[]'
  local merged_tools

  if has_browser_custom_tool_policy; then
    return 1
  else
    custom_policy_status=$?
    if [[ "$custom_policy_status" -ne 1 ]]; then
      fail "The existing tool policy could not be inspected before enabling browser access."
    fi
  fi

  read_optional_config_value tools.alsoAllow ||
    fail "Existing tools.alsoAllow could not be inspected before enabling browser access."
  if [[ "$optional_config_value_found" -eq 0 ]]; then
    current_tools='[]'
  elif ! current_tools=$(jq -ce 'if type == "array" and all(.[]; type == "string") then . else error("tools.alsoAllow is not a string array") end' \
    <<<"$optional_config_value_json"); then
    fail "Existing tools.alsoAllow is invalid; fix it before enabling the browser tool."
  fi

  merged_tools=$(jq -cn --argjson current "$current_tools" '$current + ["browser"] | unique') ||
    fail "The browser tool policy could not be constructed safely."
  if [[ "$merged_tools" != "$current_tools" ]]; then
    openclaw_cli config set tools.alsoAllow "$merged_tools" --strict-json ||
      fail "The browser tool could not be added to the agent policy."
    openclaw_cli config validate ||
      fail "The browser tool policy did not pass configuration validation."
    restart_gateway_and_wait ||
      fail "The Gateway did not become ready after enabling the browser tool."
  fi

  browser_agent_tool_configured=1
  return 0
}

function configure_browser() {
  local prepare_status

  if ! ask_yes_no "Managed Browser" \
    "Configure and test an isolated Chromium profile for OpenClaw?\n\nIt will run headless as the unprivileged openclaw user. Fresh installs retain OpenClaw's default protection against private-network destinations."; then
    return 0
  fi

  [[ -x /usr/bin/chromium ]] || fail "Chromium is not installed at /usr/bin/chromium."
  if prepare_managed_browser_overrides; then
    :
  else
    prepare_status=$?
    if [[ "$prepare_status" -eq 2 ]]; then
      return 0
    fi
    fail "The existing browser overrides could not be prepared safely."
  fi

  openclaw_cli config set browser.enabled true --strict-json
  openclaw_cli config set browser.evaluateEnabled false --strict-json
  openclaw_cli config set browser.executablePath /usr/bin/chromium
  openclaw_cli config set browser.defaultProfile openclaw
  openclaw_cli config set browser.headless true --strict-json
  openclaw_cli config set browser.attachOnly false --strict-json
  openclaw_cli config set browser.noSandbox false --strict-json
  openclaw_cli config set browser.tabCleanup.enabled true --strict-json
  openclaw_cli config validate
  restart_gateway_and_wait

  if ! validate_managed_browser_status false; then
    openclaw_cli config set browser.enabled false --strict-json
    restart_gateway_and_wait
    fail "The effective browser route is not local, loopback-only Chromium, so browser control was disabled."
  fi

  clear
  echo "Testing OpenClaw's managed Chromium profile..."
  if probe_managed_browser; then
    browser_configured=1
    if enable_browser_agent_tool; then :; fi
    if [[ "$browser_agent_tool_configured" -eq 1 ]]; then
      show_message "Browser Ready" \
        "The managed browser passed a live deep check with Chromium's internal sandbox enabled, and the browser tool was added to the default agent policy. Arbitrary page-JavaScript evaluation is disabled by default."
    else
      show_message "Browser Ready; Policy Preserved" \
        "The managed browser passed its live deep check with Chromium's internal sandbox enabled. Existing custom agent, provider, deny, or sandbox tool policies were preserved, so the wizard did not claim that every agent can use the browser tool. CLI browser commands are ready; review the effective tool policy before granting agent access."
    fi
    return 0
  fi

  if ! browser_failure_looks_like_sandbox; then
    openclaw_cli config set browser.enabled false --strict-json
    openclaw_cli config set browser.noSandbox false --strict-json
    restart_gateway_and_wait
    fail "The browser failed for a reason that was not identified as a Chromium sandbox error, so no security downgrade was offered and browser control was disabled."
  fi

  if ! ask_yes_no_default_no "Chromium Sandbox Failed" \
    "Chromium could not start with its internal sandbox inside this LXC.\n\nRetry with browser.noSandbox=true? This improves LXC compatibility but weakens protection against a malicious or compromised web page. The browser will still run as the unprivileged openclaw user inside an unprivileged LXC."; then
    openclaw_cli config set browser.enabled false --strict-json
    restart_gateway_and_wait
    show_message "Browser Disabled" \
      "The Gateway remains operational, but browser control was disabled. Re-run openclaw-setup if you later want to retry or accept the compatibility fallback. A browser hosted in a separate VM is the stronger-isolation alternative."
    return 0
  fi

  openclaw_cli config set browser.noSandbox true --strict-json
  openclaw_cli config validate
  restart_gateway_and_wait

  clear
  echo "Retrying the managed browser without Chromium's internal sandbox..."
  if ! validate_managed_browser_status true || ! probe_managed_browser; then
    openclaw_cli config set browser.enabled false --strict-json
    openclaw_cli config set browser.noSandbox false --strict-json
    restart_gateway_and_wait
    fail "The managed browser still failed and was disabled. Review 'openclaw browser doctor' before retrying."
  fi

  browser_configured=1
  if enable_browser_agent_tool; then :; fi
  if [[ "$browser_agent_tool_configured" -eq 1 ]]; then
    show_message "Browser Ready" \
      "The managed browser passed its live check with browser.noSandbox=true, and the browser tool was added to the default agent policy. It remains headless and runs as the unprivileged openclaw user inside the unprivileged LXC."
  else
    show_message "Browser Ready; Policy Preserved" \
      "The managed browser passed its live check with browser.noSandbox=true. Existing custom agent, provider, deny, or sandbox tool policies were preserved, so the wizard did not claim that every agent can use the browser tool. CLI browser commands are ready; review the effective tool policy before granting agent access."
  fi
}

function valid_hostname() {
  local hostname="$1"
  [[ ${#hostname} -le 253 ]] || return 1
  [[ "$hostname" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

function is_openclaw_managed_cloudflared_service() {
  local exec_start
  local fragment_path

  fragment_path=$(cloudflared_systemd_property FragmentPath) || return 2
  exec_start=$(cloudflared_systemd_property ExecStart) || return 2
  [[ "$fragment_path" == "/etc/systemd/system/cloudflared.service" &&
    "$exec_start" == *"--metrics 127.0.0.1:20241"* &&
    "$exec_start" == *"--token-file /etc/cloudflared/tunnel-token"* ]]
}

function retain_existing_cloudflared_service() {
  local managed_status

  cloudflared_service_retained=1
  if is_openclaw_managed_cloudflared_service; then
    cloudflared_retained_service_managed=1
  else
    managed_status=$?
    [[ "$managed_status" -eq 1 ]] ||
      fail "The existing cloudflared service could not be classified safely."
  fi
}

function begin_cloudflare_transaction() {
  local gateway_json

  [[ "$cloudflared_transaction_pending" -eq 0 ]] || return 0
  gateway_json=$(openclaw_cli config get gateway --json) ||
    fail "The current Gateway configuration could not be captured for rollback."

  if jq -e '(.controlUi? | type == "object") and (.controlUi | has("allowedOrigins"))' \
    <<<"$gateway_json" >/dev/null; then
    cloudflare_allowed_origins_rollback_json=$(jq -ce '.controlUi.allowedOrigins' <<<"$gateway_json")
    if ! jq -e 'type == "array" and all(.[]; type == "string")' \
      <<<"$cloudflare_allowed_origins_rollback_json" >/dev/null; then
      fail "Existing gateway.controlUi.allowedOrigins is not a string array; fix it before configuring Cloudflare."
    fi
    if jq -e 'index("*") != null' <<<"$cloudflare_allowed_origins_rollback_json" >/dev/null; then
      fail "Existing gateway.controlUi.allowedOrigins contains '*'; remove that unsafe wildcard before configuring Cloudflare."
    fi
    cloudflare_allowed_origins_existed=1
  else
    cloudflare_allowed_origins_rollback_json='[]'
  fi

  cloudflared_transaction_pending=1
}

function configure_cloudflare_origin() {
  local current_origins
  local origin_json

  begin_cloudflare_transaction
  current_origins="$cloudflare_allowed_origins_rollback_json"
  origin_json=$(jq -cn --argjson current "$current_origins" \
    --arg origin "https://${public_hostname}" \
    '$current | if index($origin) == null then . + [$origin] else . end')
  cloudflare_origin_mutated=1
  openclaw_cli config set gateway.controlUi.allowedOrigins "$origin_json" --strict-json
  openclaw_cli config validate
  restart_gateway_and_wait
  cloudflare_configured=1
}

function configure_cloudflare() {
  local hostname_input
  local managed_status
  local service_active_state=""
  local service_load_state
  local service_unit
  local service_unit_file_state=""
  local token_tmp=""
  local tunnel_active_state=""
  local tunnel_ready=0
  local tunnel_token
  local tunnel_unit_file_state=""
  local unit_tmp=""

  if ! ask_yes_no "Cloudflare Tunnel" \
    "Configure this LXC for a remotely managed Cloudflare Tunnel now?\n\nBefore continuing, create a Cloudflare Access self-hosted application and a Tunnel public hostname whose service is http://127.0.0.1:18789."; then
    return 0
  fi

  while true; do
    if ! hostname_input=$(whiptail --backtitle "$BACKTITLE" --title "Public Hostname" \
      --inputbox "Enter only the public hostname (example: openclaw.example.com):" 11 76 \
      "$public_hostname" 3>&1 1>&2 2>&3); then
      return 0
    fi
    hostname_input="${hostname_input%.}"
    if valid_hostname "$hostname_input"; then
      public_hostname="${hostname_input,,}"
      break
    fi
    show_message "Invalid Hostname" "Enter a hostname without https://, paths, spaces, or a trailing slash."
  done

  if [[ ! -x "$CLOUDFLARED_BIN" ]]; then
    fail "cloudflared is not installed at ${CLOUDFLARED_BIN}."
  fi

  service_load_state=$(cloudflared_systemd_property LoadState) ||
    fail "The existing cloudflared systemd state could not be observed safely."
  if [[ "$service_load_state" != "not-found" ]]; then
    if ! ask_yes_no "Existing Tunnel Service" \
      "A cloudflared service already exists. Replace its Tunnel token?\n\nChoose No to keep the existing service and only update OpenClaw's allowed origin."; then
      retain_existing_cloudflared_service
      configure_cloudflare_origin
      return 0
    fi

    service_unit=$(cloudflared_systemd_property FragmentPath) ||
      fail "The existing cloudflared unit path could not be observed safely."
    if [[ "$service_unit" != "/etc/systemd/system/cloudflared.service" ||
      -L "$service_unit" || ! -f "$service_unit" ]]; then
      show_message "Cloudflared Safety Check" \
        "The existing service is not the regular local unit /etc/systemd/system/cloudflared.service, so the wizard will not replace it automatically. The existing Tunnel was kept unchanged."
      retain_existing_cloudflared_service
      configure_cloudflare_origin
      return 0
    fi
    if [[ -d /etc/systemd/system/cloudflared.service.d ]] && \
      find /etc/systemd/system/cloudflared.service.d -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      show_message "Cloudflared Safety Check" \
        "The existing service has systemd drop-ins. The wizard kept that custom service unchanged and will only update OpenClaw's allowed origin."
      retain_existing_cloudflared_service
      configure_cloudflare_origin
      return 0
    fi

    service_active_state=$(cloudflared_systemd_property ActiveState) ||
      fail "The existing cloudflared active state could not be observed safely."
    service_unit_file_state=$(cloudflared_systemd_property UnitFileState) ||
      fail "The existing cloudflared boot state could not be observed safely."
    if [[ "$service_active_state" != "active" && "$service_active_state" != "inactive" ]] ||
      [[ "$service_unit_file_state" != "enabled" &&
        "$service_unit_file_state" != "enabled-runtime" &&
        "$service_unit_file_state" != "disabled" ]]; then
      show_message "Cloudflared State Is Not Stable" \
        "The existing service is transitional, failed, masked, linked, or otherwise custom. The wizard kept it unchanged and will only update OpenClaw's allowed origin."
      retain_existing_cloudflared_service
      configure_cloudflare_origin
      return 0
    fi

    cloudflared_rollback_backup=$(mktemp /run/openclaw-cloudflared-unit.XXXXXX)
    cloudflared_rollback_unit="$service_unit"
    cloudflared_rollback_mode=$(stat -c '%a' "$service_unit")
    cloudflared_rollback_uid=$(stat -c '%u' "$service_unit")
    cloudflared_rollback_gid=$(stat -c '%g' "$service_unit")
    install -o root -g root -m 600 "$service_unit" "$cloudflared_rollback_backup"
    cloudflared_rollback_had_service=1
    if is_openclaw_managed_cloudflared_service; then
      cloudflared_rollback_is_managed=1
    else
      managed_status=$?
      [[ "$managed_status" -eq 1 ]] ||
        fail "The existing cloudflared service could not be classified safely before replacement."
    fi
    cloudflared_rollback_active_state="$service_active_state"
    cloudflared_rollback_unit_file_state="$service_unit_file_state"
  else
    if [[ -e /etc/systemd/system/cloudflared.service ||
      -L /etc/systemd/system/cloudflared.service ]]; then
      fail "A dormant cloudflared unit exists while systemd reports no service. Run 'systemctl daemon-reload' and stabilize it before retrying."
    fi
    if [[ -d /etc/systemd/system/cloudflared.service.d ]] &&
      find /etc/systemd/system/cloudflared.service.d -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      fail "Dormant cloudflared drop-ins exist without a loaded service. Review or remove them before retrying."
    fi
    cloudflared_rollback_unit=/etc/systemd/system/cloudflared.service
    cloudflared_rollback_mode=644
    cloudflared_rollback_uid=0
    cloudflared_rollback_gid=0
  fi

  if ! tunnel_token=$(whiptail --backtitle "$BACKTITLE" --title "Cloudflare Tunnel Token" \
    --passwordbox "Paste the Tunnel token copied from the Cloudflare dashboard:" 11 76 \
    3>&1 1>&2 2>&3); then
    public_hostname=""
    return 0
  fi

  if [[ -z "$tunnel_token" ]]; then
    show_message "Tunnel Token Missing" \
      "Neither cloudflared nor OpenClaw's allowed origin was changed. Re-run openclaw-setup when you have the Tunnel token."
    public_hostname=""
    return 0
  fi

  if [[ -L /etc/cloudflared || (-e /etc/cloudflared && ! -d /etc/cloudflared) ]]; then
    unset tunnel_token
    fail "Refusing to use an unexpected /etc/cloudflared directory object."
  fi
  if [[ -L "$CLOUDFLARED_TOKEN_FILE" || (-e "$CLOUDFLARED_TOKEN_FILE" && ! -f "$CLOUDFLARED_TOKEN_FILE") ]]; then
    unset tunnel_token
    fail "Refusing to replace the unexpected token-file object at ${CLOUDFLARED_TOKEN_FILE}."
  fi
  if [[ -f "$CLOUDFLARED_TOKEN_FILE" ]]; then
    cloudflared_rollback_token_backup=$(mktemp /run/openclaw-cloudflared-token.XXXXXX)
    cloudflared_rollback_token_mode=$(stat -c '%a' "$CLOUDFLARED_TOKEN_FILE")
    cloudflared_rollback_token_uid=$(stat -c '%u' "$CLOUDFLARED_TOKEN_FILE")
    cloudflared_rollback_token_gid=$(stat -c '%g' "$CLOUDFLARED_TOKEN_FILE")
    install -o root -g root -m 600 "$CLOUDFLARED_TOKEN_FILE" "$cloudflared_rollback_token_backup"
    cloudflared_rollback_token_existed=1
  else
    cloudflared_rollback_token_mode=600
    cloudflared_rollback_token_uid=0
    cloudflared_rollback_token_gid=0
  fi

  begin_cloudflare_transaction
  cloudflared_service_mutated=1
  if [[ "$cloudflared_rollback_had_service" -eq 1 ]] && ! stop_cloudflared_bounded; then
    unset tunnel_token
    fail "The existing cloudflared service did not stop within the safety timeout. Its captured runtime state will now be restored if possible."
  fi

  clear
  echo "Installing the Cloudflare Tunnel service..."
  install -d -o root -g root -m 700 /etc/cloudflared
  umask 077
  token_tmp=$(mktemp /etc/cloudflared/.tunnel-token.XXXXXX)
  if ! printf '%s\n' "$tunnel_token" >"$token_tmp" ||
    ! chown root:root "$token_tmp" ||
    ! chmod 600 "$token_tmp" ||
    ! mv -fT -- "$token_tmp" "$CLOUDFLARED_TOKEN_FILE"; then
    rm -f -- "$token_tmp"
    unset tunnel_token
    fail "The Tunnel token file could not be written. The previous service, if any, will now be restored."
  fi
  token_tmp=""
  unset tunnel_token

  unit_tmp=$(mktemp /etc/systemd/system/.openclaw-cloudflared.XXXXXX)
  if ! cat <<CLOUDFLARED_UNIT >"$unit_tmp"
[Unit]
Description=Cloudflare Tunnel for OpenClaw
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
User=root
ExecStart=${CLOUDFLARED_BIN} --no-autoupdate tunnel --metrics 127.0.0.1:20241 run --token-file ${CLOUDFLARED_TOKEN_FILE}
Restart=on-failure
RestartSec=5s
TimeoutStartSec=15

[Install]
WantedBy=multi-user.target
CLOUDFLARED_UNIT
  then
    rm -f -- "$unit_tmp"
    fail "The cloudflared service unit could not be written. The previous service, if any, will now be restored."
  fi
  if ! chown root:root "$unit_tmp" ||
    ! chmod 644 "$unit_tmp" ||
    ! mv -fT -- "$unit_tmp" /etc/systemd/system/cloudflared.service; then
    rm -f -- "$unit_tmp"
    fail "The cloudflared service unit could not be installed. The previous service, if any, will now be restored."
  fi
  unit_tmp=""
  systemctl daemon-reload

  if ! systemctl enable cloudflared.service; then
    fail "cloudflared.service could not be enabled. The previous service, if any, will now be restored."
  fi
  tunnel_unit_file_state=$(cloudflared_systemd_property UnitFileState) ||
    fail "cloudflared's boot state could not be observed after enablement. The previous service, if any, will now be restored."
  if [[ "$tunnel_unit_file_state" != "enabled" ]]; then
    fail "cloudflared.service did not become persistently enabled. The previous service, if any, will now be restored."
  fi
  if ! systemctl start --no-block cloudflared.service; then
    fail "cloudflared.service could not be started. The previous service, if any, will now be restored."
  fi

  for _ in {1..60}; do
    tunnel_active_state=$(cloudflared_systemd_property ActiveState) ||
      fail "cloudflared's active state could not be observed after startup. The previous service, if any, will now be restored."
    if [[ "$tunnel_active_state" == "active" ]] && cloudflared_has_connections; then
      tunnel_ready=1
      break
    fi
    sleep 0.5
  done
  if [[ "$tunnel_ready" -ne 1 ]]; then
    fail "cloudflared did not establish an edge connection. The previous service, if any, will now be restored."
  fi
  configure_cloudflare_origin
}

function verify_security_audit() {
  local audit_json=""
  local audit_status=0
  local critical_count
  local suppressed_count

  if audit_json=$(openclaw_cli security audit --deep --json); then
    audit_status=0
  else
    audit_status=$?
  fi
  [[ -z "$audit_json" ]] || printf '%s\n' "$audit_json"

  if ! jq -e '
    type == "object" and
    (.summary.critical | type == "number") and
    (.findings | type == "array")
  ' <<<"$audit_json" >/dev/null 2>&1; then
    echo "Security audit returned malformed JSON." >&2
    return 1
  fi

  critical_count=$(jq -r '.summary.critical' <<<"$audit_json")
  suppressed_count=$(jq -r '(.suppressedFindings // []) | length' <<<"$audit_json")
  if [[ "$suppressed_count" -gt 0 ]]; then
    echo "Security audit suppressions active: ${suppressed_count}" >&2
  fi
  if [[ "$critical_count" -gt 0 ]]; then
    echo "Active critical OpenClaw security findings:" >&2
    jq -r '.findings[] | select(.severity == "critical") | "- \(.checkId): \(.title // .detail // "critical finding")"' \
      <<<"$audit_json" >&2
    return 1
  fi
  if [[ "$audit_status" -ne 0 ]]; then
    echo "Security audit command failed with status ${audit_status}." >&2
    return 1
  fi
}

function verify_gateway_runtime_identity() {
  local gateway_pid
  local openclaw_uid

  openclaw_uid=$(id -u "$OPENCLAW_USER")
  gateway_pid=$(run_as_openclaw /usr/bin/systemctl --user show \
    openclaw-gateway.service --property=MainPID --value) || return 1

  [[ "$gateway_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -d "/proc/${gateway_pid}" ]] || return 1
  [[ "$(stat -c '%u' "/proc/${gateway_pid}")" == "$openclaw_uid" ]] || return 1

  # Passwordless sudo cannot work for commands spawned by a service with
  # NoNewPrivileges enabled, so verify the actual runtime rather than only the
  # sudoers file.
  grep -Eq '^NoNewPrivs:[[:space:]]+0$' "/proc/${gateway_pid}/status"
}

function verify_setup() {
  local cloudflared_active_state=""
  local failed=0

  echo
  echo "Verifying OpenClaw..."
  if ! openclaw_cli config validate; then
    failed=1
  fi

  for _ in {1..20}; do
    if curl --connect-timeout 1 --max-time 2 -fsS \
      http://127.0.0.1:18789/readyz >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done

  if curl --connect-timeout 1 --max-time 2 -fsS \
    http://127.0.0.1:18789/readyz >/dev/null 2>&1; then
    echo "Gateway readiness check: OK"
  else
    echo "Gateway readiness check: FAILED" >&2
    failed=1
  fi

  if ! openclaw_cli_service_bounded gateway status --require-rpc --deep; then
    failed=1
  fi
  if verify_gateway_runtime_identity; then
    echo "Gateway runtime identity: ${OPENCLAW_USER}"
  else
    echo "Gateway runtime identity or sudo-capable process state: FAILED" >&2
    failed=1
  fi
  if verify_selected_system_control_policy; then
    echo "Selected LXC command policy: ${system_control_mode}"
  else
    echo "Selected LXC command policy changed or could not be verified: FAILED" >&2
    failed=1
  fi
  if [[ "$(run_as_openclaw /usr/bin/sudo -n /usr/bin/id -u 2>/dev/null || true)" == "0" ]]; then
    echo "Passwordless LXC administration: OK"
  else
    echo "Passwordless LXC administration: FAILED" >&2
    failed=1
  fi
  if [[ "$cloudflared_service_mutated" -eq 1 ||
    "$cloudflared_retained_service_managed" -eq 1 ]]; then
    if cloudflared_active_state=$(cloudflared_systemd_property ActiveState) &&
      [[ "$cloudflared_active_state" == "active" ]] && cloudflared_has_connections; then
      echo "Cloudflare edge connection: OK"
    else
      echo "Cloudflare edge connection: FAILED" >&2
      failed=1
    fi
  elif [[ "$cloudflared_service_retained" -eq 1 ]]; then
    if cloudflared_active_state=$(cloudflared_systemd_property ActiveState) &&
      [[ "$cloudflared_active_state" == "active" ]]; then
      echo "Retained custom cloudflared service: active (edge connection not independently verified)"
    else
      echo "Retained custom cloudflared service: INACTIVE" >&2
      failed=1
    fi
  fi
  openclaw_cli doctor --lint --json || true
  if ! verify_security_audit; then
    failed=1
  fi

  return "$failed"
}

function mark_complete() {
  local completed_at
  completed_at=$(date --iso-8601=seconds)

  run_as_openclaw /bin/bash -c '
    set -Eeuo pipefail
    readonly marker="$HOME/.openclaw/.proxmox-wizard-complete"
    marker_tmp=""

    cleanup_marker_tmp() {
      if [[ -n "$marker_tmp" ]]; then
        rm -f -- "$marker_tmp"
      fi
    }
    trap cleanup_marker_tmp EXIT

    umask 077
    marker_tmp=$(mktemp "$HOME/.openclaw/.proxmox-wizard-complete.tmp.XXXXXX")
    printf '\''completed_at=%s\n'\'' "$1" >"$marker_tmp"
    chmod 600 "$marker_tmp"
    mv -fT -- "$marker_tmp" "$marker"
    marker_tmp=""
  ' _ "$completed_at"
}

require_root_and_tty
ensure_user_manager
if [[ -f "$OPENCLAW_CONFIG" ]]; then
  capture_browser_running_state
fi
initialize_gateway
configure_system_control
harden_gateway
configure_models
configure_browser
configure_cloudflare
if ! verify_setup; then
  fail "The configuration was saved, but the Gateway health check failed. Review the output and re-run openclaw-setup."
fi
if ! restore_browser_original_state \
  "$browser_was_managed_before_hardening" \
  "$browser_was_running_before_hardening"; then
  fail "The browser state from before setup could not be restored; Cloudflare changes will be rolled back."
fi
mark_complete
commit_cloudflare_transaction
browser_was_managed_before_hardening=0
browser_was_running_before_hardening=0

clear
echo "OpenClaw setup is complete."
echo
echo "Gateway origin: http://127.0.0.1:18789"
if [[ "$cloudflare_configured" -eq 1 && -n "$public_hostname" ]]; then
  echo "Public URL:     https://${public_hostname}"
  echo "Cloudflare Access must allow your identity before the Tunnel route is considered protected."
fi
if [[ "$browser_configured" -eq 1 ]]; then
  echo "Managed browser: Chromium (headless, isolated OpenClaw profile)"
  if [[ "$browser_agent_tool_configured" -eq 0 ]]; then
    echo "Agent browser tool: custom tool policy preserved; review it before granting access"
  fi
fi
if [[ -n "$system_control_mode" ]]; then
  echo "LXC system control: ${system_control_mode} (passwordless sudo)"
fi
echo
echo "Useful commands:"
echo "  openclaw tui"
echo "  openclaw gateway status --deep"
echo "  openclaw browser --browser-profile openclaw doctor --deep"
echo "  openclaw browser --browser-profile openclaw start"
echo "  openclaw dashboard --no-open"
echo "  openclaw-gateway-token"
echo "  openclaw devices list"
echo "  openclaw devices approve --latest"
echo "  openclaw-setup"
WIZARD
chmod 750 /usr/local/sbin/openclaw-setup
ln -sf /usr/local/sbin/openclaw-setup /usr/local/bin/openclaw-setup
msg_ok "Created OpenClaw Setup Wizard"

motd_ssh
customize
cat <<'UPDATE_WRAPPER' >/usr/bin/update
#!/usr/bin/env bash
set -Eeuo pipefail

/usr/bin/curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/j0nl1/ProxmoxVE/main/ct/openclaw.sh |
  /bin/bash
UPDATE_WRAPPER
chmod 755 /usr/bin/update
cleanup_lxc
