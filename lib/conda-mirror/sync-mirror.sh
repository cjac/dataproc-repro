#!/bin/bash

zone="$(/usr/share/google/get_metadata_value zone)"
ZONE="$(echo $zone | sed -e 's:.*/::')"
REGION="$(echo ${ZONE} | perl -pe 's/^(.+)-[^-]+$/$1/')"

mirror_block=/dev/disk/by-id/google-conda-mirror-us-west4
if ! e2fsck -n "${mirror_block}" > /dev/null 2>&1 ; then
  echo "creating filesystem on mirror block device"
  mkfs.ext4 "${mirror_block}"
fi

mirror_mountpoint="/var/www/html"
if ! grep -q "${mirror_mountpoint}" /proc/mounts ; then
  echo "mounting ${mirror_block} on ${mirror_mountpoint}"
  mkdir -p "${mirror_mountpoint}"
  mount "${mirror_block}" "${mirror_mountpoint}"
  systemctl daemon-reload
fi

which a2ensite || \
apt-get install -y -qq apache2 > /dev/null 2>&1
a2enmod authz_core
systemctl enable apache2

tmp_dir="/mnt/shm"
if ! grep -q "${tmp_dir}" /proc/mounts ; then
  echo "mounting ramdisk on ${tmp_dir}"
  mkdir -p "${tmp_dir}"
  # 5G of tmpfs for use as a temp directory
  mount -t tmpfs -o size=5242880k tmpfs "${tmp_dir}"
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

screen -L -US conda-mirror "${CONDA_MIRROR}" -vv \
    --upstream-channel=conda-forge \
    --upstream-channel=rapidsai    \
    --upstream-channel=nvidia      \
    --platform=linux-64            \
    --temp-directory="${tmp_dir}"  \
    --target-directory="${mirror_mountpoint}" \
    --num-threads="$(expr $(nproc) - 1)"

systemctl stop apache2
umount "${mirror_mountpoint}"

# detach the rw disk
gcloud compute instances detach-disk "$(hostname -s)" \
  --disk       "${CONDA_DISK_FQN}" \
  --zone       "${ZONE}" \
  --disk-scope regional

# re-attach as ro
gcloud compute instances attach-disk "$(hostname -s)" \
  --disk        "${CONDA_DISK_FQN}" \
  --device-name "${CONDA_MIRROR_DISK_NAME}" \
  --zone        "${ZONE}" \
  --disk-scope  regional \
  --mode=ro

# Now re-mount the mirror in read-only mode
mount "${mirror_block}" "${mirror_mountpoint}"
systemctl daemon-reload

systemctl start apache2
