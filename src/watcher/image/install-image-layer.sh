#!/usr/bin/env bash
# Run only while building the Frank workstation image, after copying this
# watcher directory to /tmp/wristmemo-watcher-source.
set -euo pipefail

source_root="${1:-/tmp/wristmemo-watcher-source}"
version="$(<"${source_root}/VERSION")"
[[ "${version}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || {
  echo "Invalid WristMemo watcher VERSION" >&2
  exit 1
}
install_root="/opt/wristmemo-watcher/${version}"

install -d -m 0755 "${install_root}" /opt/wristmemo-watcher /etc/workstation-startup.d
install -m 0644 "${source_root}/VERSION" "${install_root}/VERSION"
install -m 0644 "${source_root}/wristmemo-watcher.ts" "${install_root}/wristmemo-watcher.ts"
install -m 0755 "${source_root}/run.sh" "${install_root}/run.sh"
install -m 0755 "${source_root}/service.sh" "${install_root}/service.sh"
install -m 0644 "${source_root}/watcher.env.example" "${install_root}/watcher.env.example"
ln -sfn "${install_root}" /opt/wristmemo-watcher/current
install -m 0755 "${source_root}/image/245-wristmemo-watcher.sh" \
  /etc/workstation-startup.d/245-wristmemo-watcher.sh
ln -sfn /opt/wristmemo-watcher/current/service.sh /usr/local/bin/wristmemo-watcher-service

test "$(</opt/wristmemo-watcher/current/VERSION)" = "${version}"
test -x /etc/workstation-startup.d/245-wristmemo-watcher.sh
test ! -e /opt/wristmemo-watcher/current/watcher.env
echo "WRISTMEMO_WATCHER_IMAGE_LAYER_OK version=${version}"
