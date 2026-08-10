#!/usr/bin/env bash
# Produce a versioned, secret-free payload consumed by the external Frank
# workstation image build. This does not publish or build an image.
set -euo pipefail

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:?Usage: build-artifact.sh OUTPUT_DIRECTORY}"
version="$(<"${source_root}/VERSION")"
artifact_name="wristmemo-watcher-${version}"
temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT

mkdir -p "${output_dir}" "${temporary}/${artifact_name}/image"
install -m 0644 "${source_root}/VERSION" "${temporary}/${artifact_name}/VERSION"
install -m 0644 "${source_root}/wristmemo-watcher.ts" "${temporary}/${artifact_name}/wristmemo-watcher.ts"
install -m 0755 "${source_root}/run.sh" "${temporary}/${artifact_name}/run.sh"
install -m 0755 "${source_root}/service.sh" "${temporary}/${artifact_name}/service.sh"
install -m 0644 "${source_root}/watcher.env.example" "${temporary}/${artifact_name}/watcher.env.example"
install -m 0755 "${source_root}/image/245-wristmemo-watcher.sh" \
  "${temporary}/${artifact_name}/image/245-wristmemo-watcher.sh"
install -m 0755 "${source_root}/image/install-image-layer.sh" \
  "${temporary}/${artifact_name}/image/install-image-layer.sh"

# Normalize the tar metadata so one source/version has one reviewable digest on
# both macOS (bsdtar) and Linux (GNU tar). The staged tree contains no symlinks.
find "${temporary}/${artifact_name}" -exec touch -h -t 200001010000.00 {} +
tar_ownership=(--owner=0 --group=0 --numeric-owner)
if tar --version 2>&1 | grep -Fq bsdtar; then
  tar_ownership=(--uid 0 --gid 0 --uname root --gname root)
fi
archive="${output_dir}/${artifact_name}.tar.gz"
COPYFILE_DISABLE=1 tar --format=ustar "${tar_ownership[@]}" \
  -C "${temporary}" -cf - "${artifact_name}" | gzip -n >"${archive}"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "${output_dir}" && sha256sum "${artifact_name}.tar.gz") >"${archive}.sha256"
else
  (cd "${output_dir}" && shasum -a 256 "${artifact_name}.tar.gz") >"${archive}.sha256"
fi
printf 'WRISTMEMO_WATCHER_ARTIFACT_OK version=%s archive=%s\n' "${version}" "${archive}"
