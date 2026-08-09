#!/usr/bin/env bash
# Image-owned Cloud Workstations startup hook. It starts only when the retained
# user has explicitly installed a private runtime configuration.
set -euo pipefail

workstation_user="${WORKSTATION_USER:-user}"
id "${workstation_user}" >/dev/null 2>&1 || exit 0
workstation_home="$(getent passwd "${workstation_user}" | cut -d: -f6)"
config_file="${workstation_home}/.config/wristmemo-watcher/watcher.env"
[[ -f "${config_file}" && ! -L "${config_file}" ]] || exit 0

runuser -u "${workstation_user}" -- env -i \
  HOME="${workstation_home}" \
  LOGNAME="${workstation_user}" \
  PATH="${workstation_home}/.local/bin:${workstation_home}/.local/npm/bin:/usr/local/bin:/usr/bin:/bin" \
  SHELL=/bin/bash \
  USER="${workstation_user}" \
  WRISTMEMO_WATCHER_CONFIG_FILE="${config_file}" \
  /opt/wristmemo-watcher/current/service.sh start
