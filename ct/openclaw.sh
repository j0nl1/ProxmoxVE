#!/usr/bin/env bash

SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
fi
if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/../misc/build.func" ]]; then
  source "${SCRIPT_DIR}/../misc/build.func"
else
  build_func_tmp=$(mktemp /tmp/openclaw-build-func.XXXXXX)
  if ! curl -fsSL --proto '=https' --tlsv1.2 \
    https://raw.githubusercontent.com/j0nl1/ProxmoxVE/main/misc/build.func \
    -o "$build_func_tmp"; then
    rm -f -- "$build_func_tmp"
    echo "Failed to download the ProxmoxVE build framework." >&2
    exit 1
  fi
  # The verified temporary path is created above.
  # shellcheck disable=SC1090
  if ! source "$build_func_tmp"; then
    rm -f -- "$build_func_tmp"
    echo "Failed to load the ProxmoxVE build framework." >&2
    exit 1
  fi
  rm -f -- "$build_func_tmp"
fi
for framework_function in \
  header_info variables color catch_errors build_container start description \
  check_container_storage check_container_resources \
  msg_info msg_ok msg_warn msg_error msg_menu; do
  if ! declare -F "$framework_function" >/dev/null 2>&1; then
    echo "The ProxmoxVE build framework is incomplete (missing ${framework_function})." >&2
    exit 1
  fi
done
unset framework_function

# Copyright (c) 2021-2026 community-scripts ORG
# Author: j0nl1
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://openclaw.ai/ | Github: https://github.com/openclaw/openclaw

APP="OpenClaw"
readonly OPENCLAW_INSTALLER_URL="https://raw.githubusercontent.com/j0nl1/ProxmoxVE/main/install/openclaw-install.sh"
readonly OPENCLAW_VERSION_PATTERN='^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(-[0-9]+|-(beta|rc)\.[0-9]+)?$'
var_tags="${var_tags:-ai;agent;automation;cloudflare}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-50}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_nesting="${var_nesting:-0}"
# The current ProxmoxVE framework enables keyctl for every unprivileged LXC.
# Declare the effective value honestly; OpenClaw itself does not require it.
var_keyctl="${var_keyctl:-1}"
var_tun="${var_tun:-no}"
var_fuse="${var_fuse:-no}"

header_info "$APP"
variables
color
catch_errors

openclaw_update_browser_restore_armed=0
openclaw_update_browser_is_managed=0
openclaw_update_browser_was_running=0
openclaw_update_cloudflared_restore_armed=0
openclaw_update_cloudflared_had_service=0
openclaw_update_cloudflared_active_state=""
openclaw_update_cloudflared_unit_file_state=""
openclaw_update_cloudflared_is_managed=0
openclaw_update_wizard_staged_path=""
openclaw_update_target_version=""
openclaw_optional_config_found=0
openclaw_optional_config_json=""

function ensure_openclaw_user_manager() {
  local openclaw_uid
  openclaw_uid=$(id -u openclaw) || return 1

  loginctl enable-linger openclaw >/dev/null 2>&1 || true
  systemctl start "user@${openclaw_uid}.service" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    [[ -S "/run/user/${openclaw_uid}/bus" ]] && return 0
    sleep 0.25
  done
  return 1
}

function run_as_openclaw_command() {
  local openclaw_uid
  openclaw_uid=$(id -u openclaw) || return 1
  ensure_openclaw_user_manager || return 1

  runuser -u openclaw -- env -i \
    HOME=/home/openclaw \
    USER=openclaw \
    LOGNAME=openclaw \
    SHELL=/bin/bash \
    LANG=C.UTF-8 \
    TERM="${TERM:-xterm-256color}" \
    XDG_RUNTIME_DIR="/run/user/${openclaw_uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${openclaw_uid}/bus" \
    PATH="/home/openclaw/.local/bin:/home/openclaw/.openclaw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

function run_as_openclaw() {
  run_as_openclaw_command /home/openclaw/.openclaw/bin/openclaw "$@"
}

function run_as_openclaw_quick() {
  run_as_openclaw_command /usr/bin/timeout --foreground --kill-after=1s 3s \
    /home/openclaw/.openclaw/bin/openclaw "$@"
}

function run_as_openclaw_browser_bounded() {
  run_as_openclaw_command /usr/bin/timeout --foreground --kill-after=5s 60s \
    /home/openclaw/.openclaw/bin/openclaw "$@"
}

function run_as_openclaw_service_bounded() {
  run_as_openclaw_command /usr/bin/timeout --foreground --kill-after=5s 60s \
    /home/openclaw/.openclaw/bin/openclaw "$@"
}

function read_openclaw_optional_config_value() {
  local config_output
  local config_path="$1"

  openclaw_optional_config_found=0
  openclaw_optional_config_json=""
  if config_output=$(run_as_openclaw config get "$config_path" --json 2>&1); then
    jq -e . <<<"$config_output" >/dev/null 2>&1 || return 1
    openclaw_optional_config_found=1
    openclaw_optional_config_json="$config_output"
    return 0
  fi
  if grep -Fq "Config path not found: ${config_path}" <<<"$config_output"; then
    return 0
  fi

  [[ -z "$config_output" ]] || printf '%s\n' "$config_output" >&2
  return 1
}

function is_openclaw_managed_cloudflared_service() {
  local exec_start
  local fragment_path

  fragment_path=$(systemctl show cloudflared.service --property=FragmentPath --value 2>/dev/null) || return 1
  exec_start=$(systemctl show cloudflared.service --property=ExecStart --value 2>/dev/null) || return 1
  [[ "$fragment_path" == "/etc/systemd/system/cloudflared.service" &&
    "$exec_start" == *"--metrics 127.0.0.1:20241"* &&
    "$exec_start" == *"--token-file /etc/cloudflared/tunnel-token"* ]]
}

function cloudflared_systemd_property() {
  local property="$1"
  local value

  value=$(systemctl show cloudflared.service --property="$property" --value 2>/dev/null) || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

function cloudflared_has_connections() {
  curl --connect-timeout 1 --max-time 2 -fsS http://127.0.0.1:20241/metrics 2>/dev/null |
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

function restore_cloudflared_original_state() {
  local active_state
  local load_state
  local restart_active="${1:-0}"
  local unit_file_state

  [[ "$openclaw_update_cloudflared_restore_armed" -eq 1 ]] || return 0
  load_state=$(cloudflared_systemd_property LoadState) || return 1

  if [[ "$openclaw_update_cloudflared_had_service" -eq 0 ]]; then
    if [[ "$load_state" != "not-found" ]]; then
      stop_cloudflared_bounded || return 1
      systemctl disable cloudflared.service >/dev/null 2>&1 || return 1
      active_state=$(cloudflared_systemd_property ActiveState) || return 1
      unit_file_state=$(cloudflared_systemd_property UnitFileState) || return 1
      [[ "$active_state" == "inactive" || "$active_state" == "failed" ]] || return 1
      [[ "$unit_file_state" == "disabled" ]] || return 1
    fi
    return 0
  fi

  [[ "$load_state" != "not-found" ]] || return 1
  if [[ "$openclaw_update_cloudflared_active_state" == "inactive" ]]; then
    stop_cloudflared_bounded || return 1
  fi
  set_cloudflared_unit_file_state "$openclaw_update_cloudflared_unit_file_state" || return 1

  if [[ "$openclaw_update_cloudflared_active_state" == "active" ]]; then
    if [[ "$restart_active" -eq 1 ]]; then
      # A no-block restart can briefly expose the old active process and old
      # metrics before its queued restart actually runs. Reach a verified
      # stopped state first so the readiness checks observe the new process.
      stop_cloudflared_bounded || return 1
    fi
    systemctl start --no-block cloudflared.service >/dev/null 2>&1 || return 1
    wait_for_cloudflared_active || return 1
    if [[ "$openclaw_update_cloudflared_is_managed" -eq 1 ]]; then
      wait_for_cloudflared_connections || return 1
    fi
  fi

  active_state=$(cloudflared_systemd_property ActiveState) || return 1
  unit_file_state=$(cloudflared_systemd_property UnitFileState) || return 1
  [[ "$active_state" == "$openclaw_update_cloudflared_active_state" ]] || return 1
  [[ "$unit_file_state" == "$openclaw_update_cloudflared_unit_file_state" ]]
}

function is_local_managed_chromium_status() {
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

function restore_managed_chromium_running_state() {
  local status_json=""

  if ! status_json=$(run_as_openclaw_quick browser --browser-profile openclaw --json status 2>/dev/null) ||
    ! is_local_managed_chromium_status "$status_json"; then
    msg_warn "Managed Chromium no longer has the expected local route; its running state was not changed."
    return 1
  fi
  if jq -e '.running == true' <<<"$status_json" >/dev/null 2>&1; then
    return 0
  fi
  if ! run_as_openclaw_browser_bounded browser --browser-profile openclaw start >/dev/null 2>&1; then
    msg_warn "Managed Chromium was running before the update, but could not be restarted automatically."
    return 1
  fi
  for _ in {1..20}; do
    if status_json=$(run_as_openclaw_quick browser --browser-profile openclaw --json status 2>/dev/null) &&
      is_local_managed_chromium_status "$status_json" &&
      jq -e '.running == true' <<<"$status_json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done

  msg_warn "Managed Chromium restart was requested, but its running state could not be verified."
  return 1
}

function stop_local_managed_chromium_and_wait() {
  local status_json=""

  if ! status_json=$(run_as_openclaw_quick browser --browser-profile openclaw --json status 2>/dev/null) ||
    ! is_local_managed_chromium_status "$status_json"; then
    return 1
  fi
  if jq -e '.running == false' <<<"$status_json" >/dev/null 2>&1; then
    return 0
  fi
  if ! $STD run_as_openclaw_browser_bounded browser --browser-profile openclaw stop; then
    return 1
  fi
  for _ in {1..20}; do
    if status_json=$(run_as_openclaw_quick browser --browser-profile openclaw --json status 2>/dev/null) &&
      is_local_managed_chromium_status "$status_json" &&
      jq -e '.running == false' <<<"$status_json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done

  return 1
}

function restore_managed_chromium_original_state() {
  [[ "$openclaw_update_browser_restore_armed" -eq 1 ]] || return 0
  [[ "$openclaw_update_browser_is_managed" -eq 1 ]] || return 0

  if [[ "$openclaw_update_browser_was_running" -eq 1 ]]; then
    restore_managed_chromium_running_state
    return
  fi
  if stop_local_managed_chromium_and_wait; then
    return 0
  fi

  msg_warn "Managed Chromium was stopped before the update, but its stopped state could not be restored automatically."
  return 1
}

function openclaw_update_exit_handler() {
  local exit_code=$?
  local browser_restore_failed=0
  local cloudflared_restore_failed=0

  trap - EXIT
  trap - ERR
  set +e

  if ! restore_cloudflared_original_state; then
    cloudflared_restore_failed=1
    msg_warn "Cloudflared's original active/boot state could not be restored automatically."
  fi
  if ! restore_managed_chromium_original_state; then
    browser_restore_failed=1
    msg_warn "Managed Chromium's original running state could not be restored automatically."
  fi
  case "$openclaw_update_wizard_staged_path" in
  /tmp/openclaw-setup-source.*)
    rm -f -- "$openclaw_update_wizard_staged_path"
    ;;
  esac
  openclaw_update_wizard_staged_path=""
  if [[ ("$browser_restore_failed" -eq 1 || "$cloudflared_restore_failed" -eq 1) &&
    "$exit_code" -eq 0 ]]; then
    exit_code=1
  fi

  if declare -F on_exit >/dev/null 2>&1; then
    (exit "$exit_code")
    on_exit
  fi
  exit "$exit_code"
}

function create_openclaw_backup() {
  local backup_parent="/home/openclaw/Backups"
  local backup_dir="/home/openclaw/Backups/openclaw"
  local available_bytes
  local required_bytes
  local state_bytes
  local backup_file
  local -a backup_files=()

  if [[ ! -f /home/openclaw/.openclaw/openclaw.json ]]; then
    msg_warn "OpenClaw has not been configured yet; no state backup was created."
    return 0
  fi

  if [[ -L "$backup_parent" || (-e "$backup_parent" && ! -d "$backup_parent") ||
    -L "$backup_dir" || (-e "$backup_dir" && ! -d "$backup_dir") ]]; then
    msg_error "Refusing to use an unexpected backup path under ${backup_parent}."
    return 1
  fi
  $STD runuser -u openclaw -- /usr/bin/install -d -m 700 "$backup_parent" "$backup_dir"
  state_bytes=$(du -sb /home/openclaw/.openclaw | awk '{print $1}')
  available_bytes=$(df -PB1 "$backup_dir" | awk 'NR == 2 {print $4}')
  required_bytes=$((state_bytes + 536870912))
  if [[ ! "$available_bytes" =~ ^[0-9]+$ || "$available_bytes" -lt "$required_bytes" ]]; then
    msg_error "Not enough free space for a safe OpenClaw backup."
    msg_warn "Required: at least ${required_bytes} bytes; available: ${available_bytes:-unknown} bytes."
    return 1
  fi

  msg_info "Creating verified OpenClaw backup"
  $STD run_as_openclaw backup create --output "$backup_dir" --verify
  msg_ok "Created verified OpenClaw backup in ${backup_dir}"

  mapfile -t backup_files < <(
    find "$backup_dir" -maxdepth 1 -type f -name '*-openclaw-backup.tar.gz' -printf '%T@ %p\n' |
      sort -nr |
      cut -d' ' -f2-
  )
  if ((${#backup_files[@]} > 3)); then
    for backup_file in "${backup_files[@]:3}"; do
      if [[ "$backup_file" == "$backup_dir/"*-openclaw-backup.tar.gz && -f "$backup_file" ]]; then
        rm -f -- "$backup_file"
      fi
    done
    msg_ok "Retained the 3 newest OpenClaw backups; Proxmox snapshots were not modified"
  fi
}

function stage_openclaw_setup_wizard() {
  local installer_tmp
  local target_version
  local wizard_tmp

  installer_tmp=$(mktemp /tmp/openclaw-installer-source.XXXXXX)
  wizard_tmp=$(mktemp /tmp/openclaw-setup-source.XXXXXX)
  if ! curl -fsSL --proto '=https' --tlsv1.2 "$OPENCLAW_INSTALLER_URL" -o "$installer_tmp"; then
    rm -f -- "$installer_tmp" "$wizard_tmp"
    msg_error "The current OpenClaw installer could not be downloaded."
    return 1
  fi
  target_version=$(sed -n 's/^readonly OPENCLAW_INSTALL_VERSION="\([^"]*\)"$/\1/p' "$installer_tmp")
  if [[ ! "$target_version" =~ $OPENCLAW_VERSION_PATTERN ]]; then
    rm -f -- "$installer_tmp" "$wizard_tmp"
    msg_error "The current installer did not declare one valid pinned OpenClaw version."
    return 1
  fi
  if ! awk '
    index($0, "WIZARD") && index($0, "/usr/local/sbin/openclaw-setup") { capture = 1; next }
    capture && $0 == "WIZARD" { found_end = 1; exit }
    capture { print }
    END { if (!capture || !found_end) exit 1 }
  ' "$installer_tmp" >"$wizard_tmp"; then
    rm -f -- "$installer_tmp" "$wizard_tmp"
    msg_error "The setup wizard could not be extracted from the current installer."
    return 1
  fi
  rm -f -- "$installer_tmp"
  if [[ "$(head -n 1 "$wizard_tmp")" != "#!/usr/bin/env bash" ]] ||
    ! bash -n "$wizard_tmp"; then
    rm -f -- "$wizard_tmp"
    msg_error "The downloaded setup wizard failed validation."
    return 1
  fi

  openclaw_update_wizard_staged_path="$wizard_tmp"
  openclaw_update_target_version="$target_version"
}

function get_installed_openclaw_version() {
  local version_output

  version_output=$(run_as_openclaw --version) || return 1
  if [[ "$version_output" =~ ^OpenClaw[[:space:]]+([^[:space:]]+)([[:space:]]+\([0-9a-fA-F]{7,64}\))?$ ]]; then
    version_output="${BASH_REMATCH[1]}"
  fi
  [[ "$version_output" =~ $OPENCLAW_VERSION_PATTERN ]] || return 1
  printf '%s\n' "$version_output"
}

function verify_openclaw_cli_version() {
  local current_version
  local expected_version="$1"

  current_version=$(get_installed_openclaw_version) || return 1
  [[ "$current_version" == "$expected_version" ]]
}

function get_supported_openclaw_update_status() {
  local canonical_update_root
  local openclaw_uid
  local status_json
  local update_root

  status_json=$(run_as_openclaw_service_bounded update status --json --timeout 45) || return 1
  if ! jq -e '
    type == "object" and
    .update.installKind == "package" and
    .update.packageManager == "npm" and
    .update.deps.manager == "npm" and
    .update.deps.status == "ok" and
    .channel.value == "stable" and
    (.update.root | type == "string" and
      test("^/home/openclaw/\\.openclaw/tools/node-v[0-9]+\\.[0-9]+\\.[0-9]+/lib/node_modules/openclaw$"))
  ' <<<"$status_json" >/dev/null; then
    [[ -z "$status_json" ]] || printf '%s\n' "$status_json" >&2
    return 1
  fi

  update_root=$(jq -er '.update.root' <<<"$status_json") || return 1
  [[ -d "$update_root" && ! -L "$update_root" ]] || return 1
  canonical_update_root=$(readlink -f -- "$update_root") || return 1
  [[ "$canonical_update_root" == "$update_root" ]] || return 1
  openclaw_uid=$(id -u openclaw) || return 1
  [[ "$(stat -c '%u' "$update_root")" == "$openclaw_uid" ]] || return 1
  printf '%s\n' "$status_json"
}

function install_staged_openclaw_setup_wizard() {
  local wizard_install_tmp

  case "$openclaw_update_wizard_staged_path" in
  /tmp/openclaw-setup-source.*) ;;
  *) return 1 ;;
  esac
  [[ -f "$openclaw_update_wizard_staged_path" &&
    ! -L "$openclaw_update_wizard_staged_path" ]] || return 1
  wizard_install_tmp=$(mktemp /usr/local/sbin/.openclaw-setup.XXXXXX)
  if ! install -o root -g root -m 750 "$openclaw_update_wizard_staged_path" "$wizard_install_tmp" ||
    ! mv -fT -- "$wizard_install_tmp" /usr/local/sbin/openclaw-setup ||
    ! ln -sfn /usr/local/sbin/openclaw-setup /usr/local/bin/openclaw-setup; then
    rm -f -- "$wizard_install_tmp" "$openclaw_update_wizard_staged_path"
    openclaw_update_wizard_staged_path=""
    msg_error "The validated setup wizard could not be installed atomically."
    return 1
  fi
  rm -f -- "$openclaw_update_wizard_staged_path"
  openclaw_update_wizard_staged_path=""
  msg_ok "Refreshed the OpenClaw setup wizard"
}

function normalize_exec_policy_for_comparison() {
  jq -ceS '
    if type != "object" or (.effectivePolicy.scopes | type) != "array" then
      error("invalid exec-policy payload")
    else
      [.effectivePolicy.scopes[] | {
        scopeLabel,
        agentId: (.agentId // null),
        runtimeApprovalsSource,
        hostRequested: .host.requested,
        modeRequested: .mode.requested,
        modeEffective: .mode.effective,
        securityRequested: .security.requested,
        securityHost: .security.host,
        securityEffective: .security.effective,
        askRequested: .ask.requested,
        askHost: .ask.host,
        askEffective: .ask.effective,
        askFallbackEffective: .askFallback.effective
      }] | sort_by(.scopeLabel, .agentId)
    end
  '
}

function verify_openclaw_gateway_runtime_identity() {
  local gateway_pid
  local openclaw_uid

  openclaw_uid=$(id -u openclaw) || return 1
  gateway_pid=$(run_as_openclaw_command /usr/bin/systemctl --user show \
    openclaw-gateway.service --property=MainPID --value) || return 1
  [[ "$gateway_pid" =~ ^[1-9][0-9]*$ && -d "/proc/${gateway_pid}" ]] || return 1
  [[ "$(stat -c '%u' "/proc/${gateway_pid}")" == "$openclaw_uid" ]] || return 1
  grep -Eq '^NoNewPrivs:[[:space:]]+0$' "/proc/${gateway_pid}/status" || return 1
  [[ "$(run_as_openclaw_command /usr/bin/sudo -n /usr/bin/id -u 2>/dev/null || true)" == "0" ]]
}

function verify_openclaw_security_audit() {
  local audit_json
  local audit_status=0

  if audit_json=$(run_as_openclaw_service_bounded security audit --deep --json); then
    audit_status=0
  else
    audit_status=$?
  fi
  if ! jq -e '
    type == "object" and
    (.summary.critical | type == "number") and
    (.findings | type == "array") and
    (.summary.critical == 0)
  ' <<<"$audit_json" >/dev/null 2>&1; then
    [[ -z "$audit_json" ]] || jq -r '
      .findings[]? | select(.severity == "critical") |
      "- \(.checkId): \(.title // .detail // "critical finding")"
    ' <<<"$audit_json" >&2 || true
    return 1
  fi
  [[ "$audit_status" -eq 0 ]]
}

function verify_openclaw_after_update() {
  local expected_exec_policy="$1"
  local expected_version="$2"
  local current_exec_policy

  verify_openclaw_cli_version "$expected_version" || return 1
  run_as_openclaw_service_bounded config validate || return 1
  run_as_openclaw_service_bounded gateway status --require-rpc --deep || return 1
  verify_openclaw_gateway_runtime_identity || return 1
  current_exec_policy=$(run_as_openclaw exec-policy show --json |
    normalize_exec_policy_for_comparison) || return 1
  [[ "$current_exec_policy" == "$expected_exec_policy" ]] || return 1
  verify_openclaw_security_audit
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /home/openclaw/.openclaw/bin/openclaw ]]; then
    msg_error "No ${APP} installation found!"
    exit 1
  fi

  local choice
  local browser_check_failed=0
  local browser_config_claims_managed=0
  local browser_config_json=""
  local browser_is_managed=0
  local browser_status_json=""
  local browser_was_running=0
  local cloudflared_active_state=""
  local cloudflared_exec_start=""
  local cloudflared_fragment_path=""
  local cloudflared_load_state=""
  local cloudflared_status_load_state=""
  local cloudflared_unit_file_state=""
  local exec_policy_before_update=""
  local installed_openclaw_version=""
  local update_preview_json=""
  local update_root=""
  local update_status_json=""
  local update_status=0
  choice=$(msg_menu "OpenClaw Management" \
    "1" "Update OpenClaw, Cloudflared, and Chromium" \
    "2" "Run the OpenClaw setup wizard" \
    "3" "Create a verified OpenClaw backup" \
    "4" "Show Gateway, browser, and Tunnel status")

  case "$choice" in
  1)
    stage_openclaw_setup_wizard
    # Also removes the staged wizard if backup or update fails.
    trap openclaw_update_exit_handler EXIT
    update_status_json=$(get_supported_openclaw_update_status) || {
      msg_error "This is not the healthy stable npm installation managed by the OpenClaw LXC helper."
      msg_warn "No backup, core package, wizard, or system package was changed."
      exit 1
    }
    installed_openclaw_version=$(get_installed_openclaw_version) || {
      msg_error "The installed OpenClaw version could not be identified safely."
      exit 1
    }
    update_root=$(jq -er '.update.root' <<<"$update_status_json") || exit 1
    if ! update_preview_json=$(run_as_openclaw_service_bounded update --dry-run --yes \
      --tag "$openclaw_update_target_version" --timeout 45 --json); then
      msg_error "OpenClaw could not safely preview the pinned package update."
      msg_warn "No backup, core package, wizard, or system package was changed."
      exit 1
    fi
    if ! jq -e \
      --arg current "$installed_openclaw_version" \
      --arg expected_root "$update_root" \
      --arg expected_tag "openclaw@${openclaw_update_target_version}" \
      --arg target "$openclaw_update_target_version" '
      type == "object" and
      .dryRun == true and
      .root == $expected_root and
      .installKind == "package" and
      .mode == "npm" and
      .updateInstallKind == "package" and
      .switchToGit == false and
      .switchToPackage == false and
      .restart == true and
      .effectiveChannel == "stable" and
      .tag == $expected_tag and
      .currentVersion == $current and
      .targetVersion == $target and
      .downgradeRisk == false
    ' <<<"$update_preview_json" >/dev/null; then
      [[ -z "$update_preview_json" ]] || printf '%s\n' "$update_preview_json" >&2
      msg_error "The update preview is a downgrade, uses a non-package install, or does not resolve to the pinned target."
      msg_warn "No backup, core package, wizard, or system package was changed."
      exit 1
    fi
    create_openclaw_backup

    if ! read_openclaw_optional_config_value browser; then
      msg_error "The browser configuration could not be inspected safely."
      msg_warn "No OpenClaw or system packages were updated."
      exit 1
    fi
    if [[ "$openclaw_optional_config_found" -eq 1 ]]; then
      browser_config_json="$openclaw_optional_config_json"
      if ! jq -e 'type == "object"' <<<"$browser_config_json" >/dev/null 2>&1; then
        msg_error "The browser configuration is not an object."
        msg_warn "No OpenClaw or system packages were updated."
        exit 1
      fi
    else
      browser_config_json='{}'
    fi
    if jq -e '
        .enabled == true and
        (.defaultProfile // "openclaw") == "openclaw" and
        (.attachOnly // false) == false and
        .headless == true and
        .executablePath == "/usr/bin/chromium"
      ' <<<"$browser_config_json" >/dev/null 2>&1; then
      browser_config_claims_managed=1
    fi
    if browser_status_json=$(run_as_openclaw_quick browser --browser-profile openclaw --json status 2>/dev/null) &&
      is_local_managed_chromium_status "$browser_status_json"; then
      browser_is_managed=1
      if jq -e '.running == true' <<<"$browser_status_json" >/dev/null 2>&1; then
        browser_was_running=1
      fi
    elif [[ "$browser_config_claims_managed" -eq 1 ]]; then
      msg_error "Managed Chromium is configured, but its running state could not be read safely."
      msg_warn "No packages were updated. Re-run after 'openclaw browser --browser-profile openclaw doctor --deep' succeeds."
      exit 1
    fi
    if [[ "$browser_is_managed" -eq 1 ]]; then
      openclaw_update_browser_is_managed=1
      openclaw_update_browser_was_running="$browser_was_running"
      openclaw_update_browser_restore_armed=1
      # Preserve the framework's telemetry/lock cleanup by chaining to on_exit.
      trap openclaw_update_exit_handler EXIT
    fi

    if [[ -f /home/openclaw/.openclaw/openclaw.json ]]; then
      exec_policy_before_update=$(run_as_openclaw exec-policy show --json |
        normalize_exec_policy_for_comparison) || {
        msg_error "The effective exec policy could not be captured before updating."
        exit 1
      }
    fi

    msg_info "Updating OpenClaw"
    if $STD run_as_openclaw update --yes --tag "$openclaw_update_target_version"; then
      update_status=0
    else
      update_status=$?
    fi
    if ! verify_openclaw_cli_version "$openclaw_update_target_version"; then
      msg_error "OpenClaw did not reach the exact version expected by the published setup wizard."
      exit 1
    fi
    install_staged_openclaw_setup_wizard
    if [[ "$update_status" -ne 0 ]]; then
      msg_error "OpenClaw reached the pinned core version, but update finalization failed."
      msg_warn "The matching setup wizard was installed. Run 'openclaw update repair --yes', then retry this update."
      exit "$update_status"
    fi
    msg_ok "Updated OpenClaw"

    if command -v cloudflared >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1; then
      $STD apt-get update
    fi

    if command -v cloudflared >/dev/null 2>&1; then
      cloudflared_load_state=$(cloudflared_systemd_property LoadState) || {
        msg_error "Cloudflared's systemd state could not be observed safely; no Cloudflared packages were changed."
        exit 1
      }
      if [[ "$cloudflared_load_state" != "not-found" ]]; then
        cloudflared_active_state=$(cloudflared_systemd_property ActiveState) || {
          msg_error "Cloudflared's active state could not be observed safely; no Cloudflared packages were changed."
          exit 1
        }
        cloudflared_unit_file_state=$(cloudflared_systemd_property UnitFileState) || {
          msg_error "Cloudflared's boot state could not be observed safely; no Cloudflared packages were changed."
          exit 1
        }
        if [[ "$cloudflared_active_state" != "active" && "$cloudflared_active_state" != "inactive" ]] ||
          [[ "$cloudflared_unit_file_state" != "enabled" &&
            "$cloudflared_unit_file_state" != "enabled-runtime" &&
            "$cloudflared_unit_file_state" != "disabled" ]]; then
          msg_error "Cloudflared is transitional, failed, masked, linked, static, or otherwise custom."
          msg_warn "No Cloudflared packages were changed; stabilize the service state before retrying."
          exit 1
        fi
        cloudflared_fragment_path=$(cloudflared_systemd_property FragmentPath) || {
          msg_error "Cloudflared's unit path could not be observed safely; no Cloudflared packages were changed."
          exit 1
        }
        cloudflared_exec_start=$(cloudflared_systemd_property ExecStart) || {
          msg_error "Cloudflared's command could not be observed safely; no Cloudflared packages were changed."
          exit 1
        }

        openclaw_update_cloudflared_had_service=1
        openclaw_update_cloudflared_active_state="$cloudflared_active_state"
        openclaw_update_cloudflared_unit_file_state="$cloudflared_unit_file_state"
        if [[ "$cloudflared_fragment_path" == "/etc/systemd/system/cloudflared.service" &&
          "$cloudflared_exec_start" == *"--metrics 127.0.0.1:20241"* &&
          "$cloudflared_exec_start" == *"--token-file /etc/cloudflared/tunnel-token"* ]]; then
          openclaw_update_cloudflared_is_managed=1
        fi
      fi

      openclaw_update_cloudflared_restore_armed=1
      # Chain service restoration with the framework's existing EXIT cleanup.
      trap openclaw_update_exit_handler EXIT
      msg_info "Updating Cloudflared"
      $STD apt-get install -y --only-upgrade cloudflared
      if ! restore_cloudflared_original_state 1; then
        msg_error "Cloudflared was updated, but its original active/boot state or edge connection could not be restored."
        exit 1
      fi
      if [[ "$openclaw_update_cloudflared_had_service" -eq 1 &&
        "$openclaw_update_cloudflared_active_state" == "active" &&
        "$openclaw_update_cloudflared_is_managed" -eq 0 ]]; then
        msg_warn "The custom cloudflared service is active; its edge connectivity could not be verified at the managed metrics endpoint."
      fi
      openclaw_update_cloudflared_restore_armed=0
      msg_ok "Updated Cloudflared"
    fi

    if command -v chromium >/dev/null 2>&1; then
      if [[ "$browser_is_managed" -eq 1 ]]; then
        msg_info "Stopping managed Chromium for its package update"
        if ! stop_local_managed_chromium_and_wait; then
          msg_error "Managed Chromium could not be stopped safely; its package was not updated."
          exit 1
        fi
        msg_ok "Stopped managed Chromium"
      fi

      msg_info "Updating Chromium"
      if ! $STD apt-get install -y --only-upgrade chromium chromium-common chromium-sandbox; then
        msg_error "Chromium package update failed."
        exit 1
      fi
      msg_ok "Updated Chromium"
    fi

    if [[ -f /home/openclaw/.openclaw/openclaw.json ]]; then
      msg_info "Verifying Gateway, sudo capability, exec policy, and security audit"
      if verify_openclaw_after_update \
        "$exec_policy_before_update" "$openclaw_update_target_version"; then
        msg_ok "Gateway and LXC control invariants are healthy"
      else
        msg_error "The update completed, but a Gateway, identity, sudo, exec-policy, or security invariant failed."
        msg_warn "The verified OpenClaw backup was preserved for recovery."
        msg_warn "Run 'openclaw gateway status --deep', 'openclaw exec-policy show', and 'openclaw security audit --deep' for details."
        exit 1
      fi
    fi

    if [[ "$browser_is_managed" -eq 1 ]]; then
      msg_info "Verifying managed Chromium"
      if ! browser_status_json=$(run_as_openclaw_quick browser --browser-profile openclaw --json status 2>/dev/null) ||
        ! is_local_managed_chromium_status "$browser_status_json"; then
        browser_check_failed=1
      elif ! $STD run_as_openclaw_browser_bounded browser --browser-profile openclaw start; then
        browser_check_failed=1
      elif ! $STD run_as_openclaw_browser_bounded browser --browser-profile openclaw doctor --deep; then
        browser_check_failed=1
      fi
      if [[ "$browser_check_failed" -eq 0 ]] && ! restore_managed_chromium_original_state; then
        browser_check_failed=1
      fi

      if [[ "$browser_check_failed" -eq 1 ]]; then
        msg_error "The update completed, but the managed browser health check failed."
        msg_warn "The verified OpenClaw backup was preserved for recovery."
        if [[ "$browser_was_running" -eq 1 ]]; then
          msg_warn "The browser was running before the update; its restart could not be verified."
        fi
        msg_warn "Run 'openclaw browser --browser-profile openclaw doctor --deep' for details."
        exit 1
      fi
      openclaw_update_browser_restore_armed=0
      msg_ok "Managed Chromium is healthy"
    fi
    msg_ok "Updated successfully!"
    ;;
  2)
    if [[ "${PHS_SILENT:-0}" == "1" ]]; then
      msg_warn "The setup wizard requires an interactive terminal."
      exit 0
    fi
    stage_openclaw_setup_wizard
    trap openclaw_update_exit_handler EXIT
    if ! get_supported_openclaw_update_status >/dev/null; then
      msg_error "The setup wizard only supports the healthy stable npm installation created by this LXC helper."
      exit 1
    fi
    installed_openclaw_version=$(get_installed_openclaw_version) || {
      msg_error "The installed OpenClaw version could not be identified safely."
      exit 1
    }
    if [[ "$installed_openclaw_version" != "$openclaw_update_target_version" ]]; then
      msg_error "The installed CLI (${installed_openclaw_version}) and published wizard (${openclaw_update_target_version}) do not match."
      msg_warn "Choose Update first if the CLI is older; publish a matching installer pin if it is newer."
      exit 1
    fi
    install_staged_openclaw_setup_wizard
    /usr/local/sbin/openclaw-setup
    ;;
  3)
    create_openclaw_backup
    ;;
  4)
    run_as_openclaw gateway status --deep || true
    echo
    run_as_openclaw exec-policy show || true
    echo
    run_as_openclaw_quick browser --browser-profile openclaw --json status || true
    echo
    if cloudflared_status_load_state=$(cloudflared_systemd_property LoadState) &&
      [[ "$cloudflared_status_load_state" != "not-found" ]]; then
      systemctl --no-pager --full status cloudflared.service || true
    elif [[ "$cloudflared_status_load_state" == "not-found" ]]; then
      msg_warn "Cloudflared has not been configured as a service."
    else
      msg_warn "Cloudflared's systemd state could not be read."
    fi
    ;;
  esac

  exit 0
}

if command -v pveversion >/dev/null 2>&1; then
  installer_url="$OPENCLAW_INSTALLER_URL"
  if ! curl -fsSL --proto '=https' --tlsv1.2 "$installer_url" -o /dev/null; then
    msg_error "The OpenClaw installer has not been published at ${installer_url}."
    msg_warn "Commit and push both OpenClaw helper files before creating the LXC."
    exit 1
  fi
fi

start
build_container
description

if [[ "${PHS_SILENT:-0}" != "1" && -t 0 ]]; then
  if whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "OpenClaw Clean-install Snapshot" \
    --defaultno \
    --yesno "Create a Proxmox snapshot now, before the wizard stores model and Tunnel credentials?\n\nThe selected storage must support LXC snapshots." 13 72; then
    snapshot_name="openclaw-clean-$(date +%Y%m%d-%H%M%S)"
    if pct snapshot "$CTID" "$snapshot_name" \
      --description "OpenClaw clean install before first-run credentials"; then
      msg_ok "Created Proxmox snapshot ${snapshot_name}"
    else
      msg_warn "The LXC was created, but its storage did not accept a snapshot."
      msg_warn "This does not affect the OpenClaw installation."
    fi
  fi

  if whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "OpenClaw First-run Setup" \
    --yesno "The LXC is ready. Run the resumable OpenClaw setup wizard now?" 10 68; then
    if lxc-attach -n "$CTID" --clear-env -- /usr/bin/env \
      HOME=/root \
      USER=root \
      LOGNAME=root \
      SHELL=/bin/bash \
      LANG=C.UTF-8 \
      TERM="${TERM:-xterm-256color}" \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      /usr/local/sbin/openclaw-setup; then
      msg_ok "Completed OpenClaw first-run setup"
    else
      msg_warn "The wizard did not complete. The LXC was kept intact."
      msg_warn "Resume it later with: pct enter ${CTID}, then openclaw-setup"
    fi
  fi
fi

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} has been installed in LXC ${CTID}.${CL}"
echo -e "${INFO}${YW} Run or resume the setup wizard:${CL}"
echo -e "${TAB}${BGN}pct enter ${CTID}${CL}"
echo -e "${TAB}${BGN}openclaw-setup${CL}"
echo -e "${INFO}${YW} Operate OpenClaw from the Proxmox console:${CL}"
echo -e "${TAB}${BGN}openclaw tui${CL}"
echo -e "${INFO}${YW} Local Gateway origin for Cloudflare Tunnel:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://127.0.0.1:18789${CL}"
