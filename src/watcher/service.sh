#!/usr/bin/env bash
# Manage the retained, user-owned WristMemo watcher service on a Cloud Workstation.
set -euo pipefail

ACTION="${1:-status}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STARTUP_DIR="${HOME}/.workstation/startup.d"
STARTUP_ITEM="${STARTUP_DIR}/120-wristmemo-watcher.sh"
STATE_DIR="${ROOT}/service"
PID_FILE="${STATE_DIR}/supervisor.pid"
CHILD_PID_FILE="${STATE_DIR}/watcher.pid"
LOG_FILE="${STATE_DIR}/watcher.log"
MARKER="# Managed by WristMemo watcher service"

usage() {
  cat <<'EOF'
Usage: ./service.sh [install|start|status|restart|stop|remove|supervise]

Install and manage the retained-home WristMemo watcher. The install action adds
a user-owned Cloud Workstations startup item; no root service or public listener
is created.
EOF
}

process_matches() {
  local pid="$1" command_line
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    command_line="$(tr '\0' ' ' <"/proc/${pid}/cmdline")"
  else
    command_line="$(ps -o command= -p "${pid}" 2>/dev/null || true)"
  fi
  [[ "${command_line}" == *"${ROOT}/service.sh"* && "${command_line}" == *" supervise"* ]]
}

watcher_process_matches() {
  local pid="$1" command_line
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    command_line="$(tr '\0' ' ' <"/proc/${pid}/cmdline")"
  else
    command_line="$(ps -o command= -p "${pid}" 2>/dev/null || true)"
  fi
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
  [[ -f "${ROOT}/watcher.env" && ! -L "${ROOT}/watcher.env" ]] || {
    echo "Missing regular private watcher configuration: ${ROOT}/watcher.env" >&2
    return 74
  }
  [[ "$(stat -c '%u' "${ROOT}/watcher.env")" == "$(id -u)" ]] || {
    echo "Refusing to start: watcher.env must be owned by the watcher user." >&2
    return 74
  }
  [[ "$(stat -c '%a' "${ROOT}/watcher.env")" == "600" ]] || {
    echo "Refusing to start: watcher.env must have mode 600." >&2
    return 74
  }
}

write_startup_item() {
  local temporary
  mkdir -p "${STARTUP_DIR}"
  chmod 700 "${STARTUP_DIR}"
  if [[ -e "${STARTUP_ITEM}" ]] && ! grep -Fq "${MARKER}" "${STARTUP_ITEM}"; then
    echo "Refusing to replace unmanaged startup item: ${STARTUP_ITEM}" >&2
    exit 73
  fi
  temporary="$(mktemp "${STARTUP_DIR}/.wristmemo-watcher.XXXXXX")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "${MARKER}" \
    'set -euo pipefail' \
    "exec $(printf '%q' "${ROOT}/service.sh") start" >"${temporary}"
  chmod 700 "${temporary}"
  mv "${temporary}" "${STARTUP_ITEM}"
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
  echo "WristMemo watcher supervisor ${pid} did not stop; leaving ownership records intact." >&2
  return 76
}

supervise() {
  local child_pid="" exit_code=0 stopping=0
  validate_config
  prepare_state
  write_pid "${PID_FILE}" "$$"
  stop_child() {
    stopping=1
    if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
      kill "${child_pid}"
      wait "${child_pid}" 2>/dev/null || true
    fi
    rm -f "${CHILD_PID_FILE}"
    exit 0
  }
  trap stop_child INT TERM

  while (( stopping == 0 )); do
    printf '%s watcher-supervisor: starting watcher\n' "$(date --iso-8601=seconds)"
    (
      set -a
      # shellcheck disable=SC1091
      source "${ROOT}/watcher.env"
      set +a
      exec "${ROOT}/run.sh" watch
    ) &
    child_pid=$!
    write_pid "${CHILD_PID_FILE}" "${child_pid}"
    if wait "${child_pid}"; then
      exit_code=0
    else
      exit_code=$?
    fi
    rm -f "${CHILD_PID_FILE}"
    child_pid=""
    printf '%s watcher-supervisor: watcher exited with %s; restarting in 5 seconds\n' \
      "$(date --iso-8601=seconds)" "${exit_code}"
    sleep 5
  done
}

show_status() {
  local pid watcher_pid status_code=0
  if pid="$(current_pid)"; then
    echo "WristMemo watcher service is running (supervisor pid ${pid})."
  else
    echo "WristMemo watcher service is not running." >&2
    [[ -e "${STARTUP_ITEM}" ]] && echo "Startup item exists: ${STARTUP_ITEM}" >&2
    return 1
  fi
  echo "Startup item: ${STARTUP_ITEM}"
  echo "Log: ${LOG_FILE}"
  if [[ -f "${CHILD_PID_FILE}" ]]; then
    watcher_pid="$(<"${CHILD_PID_FILE}")"
    if watcher_process_matches "${watcher_pid}"; then
      echo "Watcher pid: ${watcher_pid}"
    else
      echo "Watcher process is not healthy; recorded pid: ${watcher_pid}" >&2
      status_code=1
    fi
  else
    echo "Watcher process pid is missing." >&2
    status_code=1
  fi
  if ! (
    set -a
    # shellcheck disable=SC1091
    source "${ROOT}/watcher.env"
    set +a
    "${ROOT}/run.sh" --status
  ); then
    status_code=1
  fi
  return "${status_code}"
}

case "${ACTION}" in
  install)
    [[ "$(uname -s)" == "Linux" ]] || {
      echo "Run service installation inside the Linux Cloud Workstation." >&2
      exit 20
    }
    validate_config
    write_startup_item
    start_service
    show_status
    ;;
  start)
    start_service
    ;;
  status)
    show_status
    ;;
  restart)
    stop_service
    start_service
    show_status
    ;;
  stop)
    stop_service
    ;;
  remove|uninstall)
    stop_service
    if [[ -e "${STARTUP_ITEM}" ]]; then
      grep -Fq "${MARKER}" "${STARTUP_ITEM}" || {
        echo "Refusing to remove unmanaged startup item: ${STARTUP_ITEM}" >&2
        exit 73
      }
      rm -f "${STARTUP_ITEM}"
    fi
    echo "WristMemo watcher startup item removed. State and logs remain in ${STATE_DIR}."
    ;;
  supervise)
    supervise
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown action: ${ACTION}" >&2
    usage >&2
    exit 2
    ;;
esac
