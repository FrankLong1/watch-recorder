#!/usr/bin/env bash
# Manage the image-owned watcher process; config and state remain retained.
set -euo pipefail

ACTION="${1:-status}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${WRISTMEMO_WATCHER_CONFIG_FILE:-${HOME}/.config/wristmemo-watcher/watcher.env}"
STATE_DIR="${WRISTMEMO_WATCHER_STATE_DIR:-${HOME}/.local/state/wristmemo-watcher}"
PID_FILE="${STATE_DIR}/supervisor.pid"
CHILD_PID_FILE="${STATE_DIR}/watcher.pid"
LOG_FILE="${STATE_DIR}/watcher.log"
IMAGE_STARTUP_HOOK="/etc/workstation-startup.d/245-wristmemo-watcher.sh"

usage() {
  cat <<'EOF'
Usage: wristmemo-watcher-service [install|start|status|restart|stop|remove|supervise]

The executable and startup hook are image-owned. Runtime configuration belongs
in ~/.config/wristmemo-watcher/watcher.env (0600); state and logs belong in
~/.local/state/wristmemo-watcher (0700). No command copies secrets into /opt.
EOF
}

process_command() {
  local pid="$1"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    tr '\0' ' ' <"/proc/${pid}/cmdline"
  else
    ps -o command= -p "${pid}" 2>/dev/null || true
  fi
}

process_matches() {
  local command_line
  command_line="$(process_command "$1")" || return 1
  [[ "${command_line}" == *"${ROOT}/service.sh"* && "${command_line}" == *" supervise"* ]]
}

watcher_process_matches() {
  local command_line
  command_line="$(process_command "$1")" || return 1
  [[ "${command_line}" == *"${ROOT}/wristmemo-watcher.ts watch"* ]]
}

current_pid() {
  [[ -f "${PID_FILE}" ]] || return 1
  local pid
  pid="$(<"${PID_FILE}")"
  process_matches "${pid}" || return 1
  printf '%s\n' "${pid}"
}

write_pid() {
  local path="$1" pid="$2" temporary
  temporary="$(mktemp "${STATE_DIR}/.pid.XXXXXX")"
  printf '%s\n' "${pid}" >"${temporary}"
  chmod 600 "${temporary}"
  mv "${temporary}" "${path}"
}

prepare_state() {
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"
  touch "${LOG_FILE}"
  chmod 600 "${LOG_FILE}"
}

validate_config() {
  [[ -f "${CONFIG_FILE}" && ! -L "${CONFIG_FILE}" ]] || {
    echo "Missing regular private watcher configuration: ${CONFIG_FILE}" >&2
    return 74
  }
  [[ "$(stat -c '%u' "${CONFIG_FILE}")" == "$(id -u)" ]] || {
    echo "Refusing to start: watcher.env must be owned by the watcher user." >&2
    return 74
  }
  [[ "$(stat -c '%a' "${CONFIG_FILE}")" == "600" ]] || {
    echo "Refusing to start: watcher.env must have mode 600." >&2
    return 74
  }
}

start_service() {
  local pid
  validate_config
  prepare_state
  if pid="$(current_pid)"; then
    echo "WristMemo watcher service is already running (supervisor pid ${pid})."
    return 0
  fi
  nohup setsid "${ROOT}/service.sh" supervise </dev/null >>"${LOG_FILE}" 2>&1 &
  pid=$!
  write_pid "${PID_FILE}" "${pid}"
  for _ in {1..50}; do
    if process_matches "${pid}"; then
      echo "WristMemo watcher service started (supervisor pid ${pid})."
      return 0
    fi
    sleep 0.1
  done
  echo "WristMemo watcher supervisor did not stay running; inspect ${LOG_FILE}." >&2
  return 75
}

stop_service() {
  local pid
  if ! pid="$(current_pid)"; then
    echo "WristMemo watcher service is not running."
    return 0
  fi
  kill "${pid}"
  for _ in {1..100}; do
    process_matches "${pid}" || {
      rm -f "${PID_FILE}" "${CHILD_PID_FILE}"
      echo "WristMemo watcher service stopped."
      return 0
    }
    sleep 0.1
  done
  echo "WristMemo watcher supervisor ${pid} did not stop; ownership records remain." >&2
  return 76
}

supervise() {
  local child_pid="" exit_code=0
  validate_config
  prepare_state
  write_pid "${PID_FILE}" "$$"
  stop_child() {
    if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
      kill "${child_pid}"
      wait "${child_pid}" 2>/dev/null || true
    fi
    rm -f "${CHILD_PID_FILE}"
    exit 0
  }
  trap stop_child INT TERM

  while true; do
    printf '%s watcher-supervisor: starting watcher version=%s\n' \
      "$(date --iso-8601=seconds)" "$(<"${ROOT}/VERSION")"
    (
      set -a
      # shellcheck disable=SC1090
      source "${CONFIG_FILE}"
      set +a
      export WRISTMEMO_WATCHER_STATE_DIR="${STATE_DIR}"
      exec "${ROOT}/run.sh" watch
    ) &
    child_pid=$!
    write_pid "${CHILD_PID_FILE}" "${child_pid}"
    if wait "${child_pid}"; then exit_code=0; else exit_code=$?; fi
    rm -f "${CHILD_PID_FILE}"
    child_pid=""
    printf '%s watcher-supervisor: watcher exited with %s; restarting in 5 seconds\n' \
      "$(date --iso-8601=seconds)" "${exit_code}"
    sleep 5
  done
}

show_status() {
  local pid watcher_pid status_code=0
  echo "WristMemo watcher build: $(<"${ROOT}/VERSION")"
  if pid="$(current_pid)"; then
    echo "WristMemo watcher service is running (supervisor pid ${pid})."
  else
    echo "WristMemo watcher service is not running." >&2
    status_code=1
  fi
  echo "Image startup hook: ${IMAGE_STARTUP_HOOK}"
  echo "Config: ${CONFIG_FILE}"
  echo "State: ${STATE_DIR}"
  echo "Log: ${LOG_FILE}"
  if [[ -f "${CHILD_PID_FILE}" ]]; then
    watcher_pid="$(<"${CHILD_PID_FILE}")"
    watcher_process_matches "${watcher_pid}" || status_code=1
  else
    status_code=1
  fi
  if validate_config; then
    if ! (
      set -a
      # shellcheck disable=SC1090
      source "${CONFIG_FILE}"
      set +a
      export WRISTMEMO_WATCHER_STATE_DIR="${STATE_DIR}"
      "${ROOT}/run.sh" --status
    ); then
      status_code=1
    fi
  else
    status_code=1
  fi
  return "${status_code}"
}

case "${ACTION}" in
  install)
    [[ -x "${IMAGE_STARTUP_HOOK}" ]] || {
      echo "Image-owned watcher startup hook is missing: ${IMAGE_STARTUP_HOOK}" >&2
      exit 78
    }
    start_service
    echo "Startup is asynchronous; run wristmemo-watcher-service status after the first poll."
    ;;
  start) start_service ;;
  status) show_status ;;
  restart) stop_service; start_service; show_status ;;
  stop) stop_service ;;
  remove|uninstall)
    stop_service
    echo "The image-owned startup hook remains. Remove or rename ${CONFIG_FILE} to disable future starts; state and logs remain."
    ;;
  supervise) supervise ;;
  -h|--help|help) usage ;;
  *) echo "Unknown action: ${ACTION}" >&2; usage >&2; exit 2 ;;
esac
