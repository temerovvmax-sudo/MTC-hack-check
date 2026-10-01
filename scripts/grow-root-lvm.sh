#!/bin/bash
# Grow the root LVM online. No reboot.
# Rescan the virtio/scsi disk, growpart the last partition, pvresize,
# lvextend -l +100%FREE, then resize2fs or xfs_growfs.
# Exits 0 without changes when the disk has no free space or root is not on LVM.
set -euo pipefail

say() {
  printf '%s\n' "$*"
}

root_src="$(findmnt -nro SOURCE /)"
fstype="$(findmnt -nro FSTYPE /)"

if [[ -z "${root_src}" || ! -b "${root_src}" ]]; then
  say "skip: root source is not a block device (${root_src:-empty})"
  exit 0
fi

tree="$(lsblk -nrpo NAME,TYPE "${root_src}" -s)"
lv="$(awk '$2 == "lvm" { print $1; exit }' <<<"${tree}")"
if [[ -z "${lv}" ]]; then
  say "skip: root is not on LVM (${root_src})"
  exit 0
fi

disk="$(awk '$2 == "disk" { print $1; exit }' <<<"${tree}")"
pv="$(awk '$2 == "part" { print $1; exit }' <<<"${tree}")"
if [[ -z "${disk}" ]]; then
  say "skip: no parent disk for ${root_src}"
  exit 0
fi
if [[ -z "${pv}" ]]; then
  pv="${disk}"
fi

base="$(basename "${disk}")"
if [[ -e "/sys/block/${base}/device/rescan" ]]; then
  echo 1 >"/sys/block/${base}/device/rescan" || true
fi
shopt -s nullglob
for scan in /sys/class/scsi_host/host*/scan; do
  echo "- - -" >"${scan}" || true
done
shopt -u nullglob
blockdev --rereadpt "${disk}" || true

last_part="$(lsblk -nrpo NAME,TYPE "${disk}" | awk '$2 == "part" { name = $1 } END { print name }')"
grew_part=0
if [[ -n "${last_part}" ]]; then
  partnum="$(cat "/sys/class/block/$(basename "${last_part}")/partition")"
  set +e
  grow_out="$(growpart "${disk}" "${partnum}" 2>&1)"
  grow_rc=$?
  set -e
  if grep -q 'NOCHANGE' <<<"${grow_out}"; then
    :
  elif [[ "${grow_rc}" -eq 0 ]]; then
    grew_part=1
    say "grew partition ${disk} ${partnum}"
  else
    printf '%s\n' "${grow_out}" >&2
    exit "${grow_rc}"
  fi
fi

if ! pvs --noheadings -o pv_name "${pv}" >/dev/null 2>&1; then
  say "skip: ${pv} is not a physical volume"
  exit 0
fi
pvresize "${pv}"

vg="$(pvs --noheadings -o vg_name "${pv}" | tr -d '[:space:]')"
free_pe="$(vgs --noheadings --nosuffix -o vg_free_count "${vg}" | tr -d '[:space:]')"
free_pe="${free_pe:-0}"

grew_lv=0
if [[ "${free_pe}" -gt 0 ]]; then
  lvextend -l +100%FREE "${lv}"
  grew_lv=1
  say "grew logical volume ${lv}"
fi

case "${fstype}" in
  ext2|ext3|ext4)
    resize2fs "${lv}"
    ;;
  xfs)
    xfs_growfs /
    ;;
  *)
    if [[ "${grew_part}" -eq 1 || "${grew_lv}" -eq 1 ]]; then
      printf 'filesystem %s is not ext or xfs\n' "${fstype}" >&2
      exit 1
    fi
    say "skip: filesystem ${fstype} is not ext or xfs"
    exit 0
    ;;
esac

if [[ "${grew_part}" -eq 0 && "${grew_lv}" -eq 0 ]]; then
  say "skip: no free space"
  exit 0
fi

say "grew root filesystem"
exit 0
