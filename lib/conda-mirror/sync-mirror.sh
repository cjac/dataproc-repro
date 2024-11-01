#!/bin/bash

#
# The license to this software must be negotiated with Collier Technologies LLC
#
# Copyright 2024, Collier Technologies LLC and contributors
#

#
# This script is copied to the conda mirror synchronization host.  The
# host must have ${CONDA_DISK_FQN} attached in rw mode. After running
# this script, the attached disk will have an ext4 filesystem written
# directy to it, no partitions.  On this filesystem, conda channels
# will be mirrored to the / directory
#
# In addition, the content will be served from http://$(hostname -s)/
#

zone="$(/usr/share/google/get_metadata_value zone)"
ZONE="$(echo $zone | sed -e 's:.*/::')"
REGION="$(echo ${ZONE} | perl -pe 's/^(.+)-[^-]+$/$1/')"
PROJECT_ID="$(gcloud config get project)"
CONDA_MIRROR_DISK_NAME="conda-mirror-${REGION}"
CONDA_DISK_FQN="projects/${PROJECT_ID}/regions/${REGION}/disks/${CONDA_MIRROR_DISK_NAME}"

mirror_block="/dev/disk/by-id/google-${CONDA_MIRROR_DISK_NAME}"
mirror_mountpoint="/var/www/html"
if [[ -e "${mirror_block}" ]] ; then
  if ! e2fsck -n "${mirror_block}" > /dev/null 2>&1 ; then
    echo "creating filesystem on mirror block device"
    mkfs.ext4 "${mirror_block}"
  fi

  if ! grep -q "${mirror_mountpoint}" /proc/mounts ; then
    echo "mounting ${mirror_block} on ${mirror_mountpoint}"
    mkdir -p "${mirror_mountpoint}"
    mount "${mirror_block}" "${mirror_mountpoint}"
  fi

  which a2ensite || \
  apt-get install -y -qq apache2 > /dev/null 2>&1
  a2enmod authz_core
  systemctl enable apache2
  rm -f "${mirror_mountpoint}/index.html"

  tmp_dir="/mnt/shm"
  if ! grep -q "${tmp_dir}" /proc/mounts ; then
    echo "mounting ramdisk on ${tmp_dir}"
    mkdir -p "${tmp_dir}"
    #  5G  (5242880k) of tmpfs for use as a temp directory
    # 10G (10485760k) of tmpfs for use as a temp directory
    #    mount -t tmpfs -o size=10485760k tmpfs "${tmp_dir}"
    mount -t tmpfs tmpfs "${tmp_dir}"
  fi

  CONDA="/opt/conda/miniconda3/bin/conda"
  CONDA_MIRROR="${CONDA}-mirror"

  if [[ ! -f "${CONDA_MIRROR}" ]] ; then
    "${CONDA}" update -n base -c defaults conda
    "${CONDA}" install conda-mirror -c conda-forge
  fi

  which screen || \
  apt-get install -y -qq screen > /dev/null 2>&1

  #time "${CONDA_MIRROR}" -v -D \
  #    --upstream-channel=defaults    \
  #    --upstream-channel=https://repo.anaconda.cloud/pkgs/main \
  #    --upstream-channel=https://repo.anaconda.cloud/pkgs/r \

  CHANNEL_CMD=(
      'conda-forge'
      'rapidsai'
      'nvidia'
      'pkgs/main'
      'pkgs/r'
  )

  mirror_screenrc=/tmp/conda-mirror.screenrc
  echo "# conda-mirror.screenrc" > "${mirror_screenrc}"
  i=1 ; num_channels=${#CHANNEL_CMD[@]}
  for channel in 'conda-forge' 'rapidsai' 'nvidia' 'pkgs/main' 'pkgs/r' ; do
    cmd=$(echo "${CONDA_MIRROR}" -vvv \
      --upstream-channel="${channel}" \
      --platform=linux-64            \
      --temp-directory="${tmp_dir}"  \
      --target-directory="${mirror_mountpoint}/${channel}" \
      --num-threads="$(expr $(expr $(nproc) / ${num_channels})  - 1)" )
    echo "screen -L -t ${channel} ${i} $cmd" >> "${mirror_screenrc}"
    i="$(expr $i + 1)"
  done
  screen -US "conda-mirror" -c "${mirror_screenrc}"

  systemctl stop apache2
  umount "${mirror_mountpoint}"

  # detach the rw disk
  echo gcloud compute instances detach-disk "$(hostname -s)" \
    --disk       "${CONDA_DISK_FQN}" \
    --zone       "${ZONE}" \
    --disk-scope regional
fi

# attach disk with mode ro
echo gcloud compute instances attach-disk "$(hostname -s)" \
  --disk        "${CONDA_DISK_FQN}" \
  --device-name "${CONDA_MIRROR_DISK_NAME}" \
  --zone        "${ZONE}" \
  --disk-scope  regional \
  --mode=ro

if ! grep -q "${mirror_mountpoint}" /proc/mounts ; then
  # Now re-mount the mirror in read-only mode
  echo "mounting ${mirror_block} on ${mirror_mountpoint}"
  mkdir -p "${mirror_mountpoint}"
  mount "${mirror_block}" "${mirror_mountpoint}"
  systemctl restart apache2
fi

