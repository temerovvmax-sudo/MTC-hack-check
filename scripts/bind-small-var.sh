#!/bin/bash
# If /var or the container runtime directories are on a filesystem smaller
# than 8GiB, bind-mount directories on the root filesystem over them and
# record that in fstab. /var/tmp is included so image tarballs are not
# copied onto the small /var filesystem. Do the same for /var/log when its
# filesystem is under 4GiB. No reboot, no lvreduce, no format.
set -euo pipefail

say() {
  printf '%s\n' "$*"
}

fstab=${BIND_FSTAB:-/etc/fstab}
prefix=${BIND_ROOT:-}

gib=$((1024 * 1024 * 1024))
runtime_limit=$((8 * gib))
log_limit=$((4 * gib))

existing_path() {
  local path="$1"
  while [[ "${path}" != "/" && ! -e "${path}" ]]; do
    path="$(dirname "${path}")"
  done
  printf '%s\n' "${path}"
}

fs_field() {
  local field="$1" path="$2" probe
  probe="$(existing_path "${path}")"
  findmnt -nbo "${field}" -T "${probe}" | tr -d '[:space:]'
}

mounted_source() {
  local path="$1"
  findmnt -n -M "${path}" -o SOURCE 2>/dev/null | tr -d '[:space:]' || true
}

fstab_has() {
  local src="$1" dst="$2"
  [[ -f "${fstab}" ]] || return 1
  awk -v src="${src}" -v dst="${dst}" '
    $0 ~ /^[[:space:]]*#/ { next }
    $1 == src && $2 == dst && $4 ~ /(^|,)bind(,|$)/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "${fstab}"
}

ensure_fstab() {
  local src="$1" dst="$2"
  if fstab_has "${src}" "${dst}"; then
    return 1
  fi
  printf '%s %s none bind 0 0\n' "${src}" "${dst}" >>"${fstab}"
  say "fstab ${dst}"
  return 0
}

bind_one() {
  local src_rel="$1" dst_rel="$2" limit="$3" label="$4"
  local src="${prefix}${src_rel}"
  local dst="${prefix}${dst_rel}"
  local current bytes root_bytes src_fs root_fs

  current="$(mounted_source "${dst}")"
  if [[ "${current}" == "${src}" ]]; then
    ensure_fstab "${src_rel}" "${dst_rel}" || true
    say "skip: ${dst_rel} already bind-mounted from ${src_rel}"
    return 0
  fi

  bytes="$(fs_field SIZE "${dst}")"
  if [[ "${bytes}" -ge "${limit}" ]]; then
    say "skip: ${dst_rel} filesystem is at least ${label}"
    return 0
  fi

  root_bytes="$(fs_field SIZE "${prefix}/")"
  if [[ "${root_bytes}" -lt "${limit}" ]]; then
    say "skip: root filesystem is under ${label}, not binding ${dst_rel}"
    return 0
  fi

  if [[ "$(fs_field SOURCE "${dst}")" == "$(fs_field SOURCE "${prefix}/")" ]]; then
    say "skip: ${dst_rel} is already on the root filesystem"
    return 0
  fi

  if [[ -L "${dst}" ]]; then
    printf '%s is a symlink\n' "${dst_rel}" >&2
    exit 1
  fi
  if [[ -n "${current}" && "${current}" != /dev/* ]]; then
    printf '%s is already mounted from %s\n' "${dst_rel}" "${current}" >&2
    exit 1
  fi

  mkdir -p "${src}"
  src_fs="$(fs_field SOURCE "${src}")"
  root_fs="$(fs_field SOURCE "${prefix}/")"
  if [[ "${src_fs}" != "${root_fs}" ]]; then
    printf '%s is not on the root filesystem\n' "${src_rel}" >&2
    exit 1
  fi

  mkdir -p "${dst}"
  chmod --reference="${dst}" "${src}"
  chown --reference="${dst}" "${src}"
  if [[ -n "$(ls -A "${dst}")" && -n "$(ls -A "${src}")" ]]; then
    printf 'both %s and %s have contents\n' "${src_rel}" "${dst_rel}" >&2
    exit 1
  fi
  if [[ -n "$(ls -A "${dst}")" ]]; then
    find "${dst}" -mindepth 1 -maxdepth 1 -exec mv -t "${src}" {} +
    say "moved ${dst_rel}"
  fi

  mount --bind "${src}" "${dst}"
  say "bound ${src_rel} ${dst_rel}"
  ensure_fstab "${src_rel}" "${dst_rel}" || true
}

runtime_small=0
for probe in /var /var/lib/docker /var/lib/containerd; do
  if [[ "$(fs_field SIZE "${prefix}${probe}")" -lt "${runtime_limit}" ]]; then
    runtime_small=1
  fi
done

if [[ "${runtime_small}" -eq 1 ]] \
  || [[ "$(mounted_source "${prefix}/var/lib/docker")" == "${prefix}/opt/docker" ]] \
  || [[ "$(mounted_source "${prefix}/var/lib/containerd")" == "${prefix}/opt/containerd" ]]; then
  bind_one /opt/docker /var/lib/docker "${runtime_limit}" "8G"
  bind_one /opt/containerd /var/lib/containerd "${runtime_limit}" "8G"
else
  say "skip: docker and containerd filesystems are at least 8G"
fi

if [[ "$(fs_field SIZE "${prefix}/var")" -lt "${runtime_limit}" ]] \
  || [[ "$(fs_field SIZE "${prefix}/var/tmp")" -lt "${runtime_limit}" ]] \
  || [[ "$(mounted_source "${prefix}/var/tmp")" == "${prefix}/opt/tmp" ]]; then
  bind_one /opt/tmp /var/tmp "${runtime_limit}" "8G"
else
  say "skip: /var/tmp filesystem is at least 8G"
fi

if [[ "$(fs_field SIZE "${prefix}/var/log")" -lt "${log_limit}" ]] \
  || [[ "$(mounted_source "${prefix}/var/log")" == "${prefix}/opt/log" ]]; then
  bind_one /opt/log /var/log "${log_limit}" "4G"
else
  say "skip: /var/log filesystem is at least 4G"
fi
