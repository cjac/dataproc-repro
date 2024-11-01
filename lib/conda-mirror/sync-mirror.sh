#!/bin/bash

zone="$(/usr/share/google/get_metadata_value zone)"
ZONE="$(echo $zone | sed -e 's:.*/::')"
REGION="$(echo ${ZONE} | perl -pe 's/^(.+)-[^-]+$/$1/')"

mirror_block=/dev/disk/by-id/google-conda-mirror-us-west4
if ! e2fsck -n "${mirror_block}" > /dev/null 2>&1 ; then
  echo "creating filesystem on mirror block device"
  mkfs.ext4 "${mirror_block}"
fi

mirror_mountpoint="/srv/conda-mirror"
if ! grep -q "${mirror_mountpoint}" /proc/mounts ; then
  echo "mounting ${mirror_block} on ${mirror_mountpoint}"
  mkdir -p "${mirror_mountpoint}"
  mount "${mirror_block}" "${mirror_mountpoint}"
fi

tmp_dir="/mnt/shm"
if ! grep -q "${tmp_dir}" /proc/mounts ; then
  echo "mounting ramdisk on ${tmp_dir}"
  mkdir -p "${tmp_dir}"
  # 5G of tmpfs for use as a temp directory
  mount -t tmpfs -o size=5242880k tmpfs "${tmp_dir}"
fi


CONDA="/opt/conda/miniconda3/bin/conda"

"${CONDA}" install conda-mirror -c conda-forge

CONDA_MIRROR="${CONDA}-mirror"

apt-get install screen

screen "${CONDA_MIRROR}" \
    --upstream-channel=conda-forge \
    --upstream-channel=rapidsai    \
    --upstream-channel=nvidia      \
    --platform=linux-64            \
    --temp-directory="${tmp_dir}"  \
    --target-directory="${mirror_mountpoint}" \
    --num-threads=7
