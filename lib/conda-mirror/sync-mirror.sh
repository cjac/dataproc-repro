#!/bin/bash

#
# The license to this software must be negotiated with Collier Technologies LLC
#
# Copyright 2024, Collier Technologies LLC and contributors
#
# A one-month duration, non-transferrable licenses to use, but not
# redistribute is automatically granted to sponsors of $50 or more
#
# https://github.com/sponsors/LLC-Technologies-Collier
#

set -ex

#
# This script is copied to the conda mirror synchronization host.  The
# host must have ${CONDA_DISK_FQN} attached in rw mode. After running
# this script, the attached disk will have an ext4 filesystem written
# directy to it, no partitions.  On this filesystem, conda channels
# will be mirrored to the / directory
#
# In addition, the content will be served from http://$(hostname -s)/
#

function install_apache(){
  which a2ensite || \
  apt-get install -y -qq apache2 > /dev/null 2>&1
  a2enmod authz_core
  systemctl enable apache2
  rm -f "${mirror_mountpoint}/index.html"
}

function mount_tmp_dir(){
  if grep -q "${tmp_dir}" /proc/mounts ; then return 0 ; fi
  echo "mounting ramdisk on ${tmp_dir}"
  mkdir -p "${tmp_dir}"
  #  5G  (5242880k) of tmpfs for use as a temp directory
  # 10G (10485760k) of tmpfs for use as a temp directory
  #    mount -t tmpfs -o size=10485760k tmpfs "${tmp_dir}"
  # n1-standard-16 has sufficient memory to support a ram tmp_dir
  mount -t tmpfs tmpfs "${tmp_dir}"
}

function umount_tmp_dir(){
  mount -o remount,ro "${mirror_block}"
  sync
  sleep 3s
  sync
  umount "${tmp_dir}"
}

function install_conda_mirror(){
  if [[ ! -f "${CONDA_MIRROR}" ]] ; then
    "${CONDA}" update -n base -c defaults conda
    "${CONDA}" install conda-mirror -c conda-forge
  fi
}

function install_screen(){
  which screen || \
    apt-get install -y -qq screen > /dev/null 2>&1
}

function attach_conda_mirror_disk(){
  mode="${1:-ro}"
  # attach disk to this host with mode ro by default
  gcloud compute instances attach-disk "$(hostname -s)" \
    --disk        "${CONDA_DISK_FQN}" \
    --device-name "${CONDA_MIRROR_DISK_NAME}" \
    --disk-scope  "regional" \
    --zone        "${ZONE}"  \
    --mode        "${mode}"
}

function detach_conda_mirror_disk(){
  gcloud compute instances detach-disk "$(hostname -s)" \
    --disk       "${CONDA_DISK_FQN}" \
    --zone       "${ZONE}" \
    --disk-scope regional
}

function exit_handler(){
  set +e
  local cleanup_after="$(/usr/share/google/get_metadata_value attributes/cleanup-after || echo '')"
  echo "cleanup_after=${cleanup_after}"
  case "${cleanup_after}" in
    "yes" | "true" )
      # When the script finishes, detach and re-attach the disk in read-only mode

      # stop apache, since it serves http from the mount point
      systemctl stop apache2
      # unmount the rw disk, detach the virtual device
      umount_mirror_block_device
      detach_conda_mirror_disk
      # attach a new device with the same name in ro mode
      attach_conda_mirror_disk ro
      mount_mirror_block_device ro
      # unmount the tmpfs temp directory
      umount_tmp_dir
      # bring apache back online to serve a ro copy of the archive via http
      systemctl restart apache2
      # Take a snapshot of the archive
      replica_zones="$(gcloud compute zones list | \
        perl -e '@l=sort map{/^([^\s]+)/}grep{ /^$ARGV[0]/ } <STDIN>; print(join(q{,},@l[0,1]),$/)' ${REGION})"
      gcloud compute disks create "${CONDA_MIRROR_DISK_NAME}-${timestamp}" \
        --project="${PROJECT_ID}" \
	--region="${REGION}" \
	--source-disk "${CONDA_MIRROR_DISK_NAME}" \
        --source-disk-region="${REGION}" \
        --replica-zones="${replica_zones}"
    ;;
    "*" )
      echo "no operation"
    ;;
  esac
}

function mount_conda_mirror_disk() {
  mode="${1:-ro}"
  if ! grep -q "${mirror_mountpoint}" /proc/mounts ; then
    echo "mounting ${mirror_block} on ${mirror_mountpoint}"
    mkdir -p "${mirror_mountpoint}"
    mount -o "${mode}" "${mirror_block}" "${mirror_mountpoint}"
  fi
}
function mount_mirror_block_device(){
  mode="${1:-ro}"
    
  if [[ ! -e "${mirror_block}" ]] ; then return 0 ; fi

  if [[ "${mode}" == "rw" ]] && ! e2fsck -n "${mirror_block}" > /dev/null 2>&1 ; then
    echo "creating filesystem on mirror block device"
    mkfs.ext4 "${mirror_block}"
  fi

  mount_line=""
  #/dev/sdb /var/www/html ext4 rw,relatime 0 0
  if grep -q "${mirror_mountpoint}" /proc/mounts ; then
    # If already mounted, find out the mode
    current_mount_mode=$(perl -e '@f=(split(/\s+/, $ARGV[1]));print($f[3]=~/(ro|rw)/);' "$(grep "${mirror_mountpoint}" /proc/mounts)")
    if [[ "${mode}" == "rw" && "${current_mount_mode}" == "ro" ]] ; then
      echo "remounting in read/write mode"
      umount_mirror_block_device
      detach_conda_mirror_disk
      attach_conda_mirror_disk rw
      # If the above fails, it's sometimes because there are VMs which
      # have attached to the block device in ro mode
      mount_mirror_block_device rw
    fi
  else
    echo "mounting ${mirror_block} on ${mirror_mountpoint}"
    mkdir -p "${mirror_mountpoint}"
    mount "${mirror_block}" "${mirror_mountpoint}"
    mount -o "${mode}" "${mirror_block}" "${mirror_mountpoint}"
  fi
}
function umount_mirror_block_device(){
  sync
  sleep 3s
  sync
  umount "${mirror_block}"
}

function prepare_conda_mirror(){
  zone="$(/usr/share/google/get_metadata_value zone)"
  ZONE="$(echo $zone | sed -e 's:.*/::')"
  REGION="$(echo ${ZONE} | perl -pe 's/^(.+)-[^-]+$/$1/')"
  PROJECT_ID="$(gcloud config get project)"
  CONDA="/opt/conda/miniconda3/bin/conda"
  CONDA_MIRROR="${CONDA}-mirror"
  CONDA_MIRROR_DISK_NAME="conda-mirror-${REGION}"
  CONDA_DISK_FQN="projects/${PROJECT_ID}/regions/${REGION}/disks/${CONDA_MIRROR_DISK_NAME}"

  mirror_screenrc=/tmp/conda-mirror.screenrc
  mirror_block="/dev/disk/by-id/google-${CONDA_MIRROR_DISK_NAME}"
  mirror_mountpoint="/var/www/html"
  tmp_dir="/mnt/shm"

  # clean up after
  trap exit_handler EXIT

  mount_mirror_block_device rw
  install_apache
  install_screen
  mount_tmp_dir
  install_conda_mirror
}

#time "${CONDA_MIRROR}" -v -D \
#    --upstream-channel=defaults    \
#    --upstream-channel=https://repo.anaconda.cloud/pkgs/main \
#    --upstream-channel=https://repo.anaconda.cloud/pkgs/r \
# https://conda.anaconda.org/main/linux-64/repodata.json is the correct repodata URL for Anaconda Distribution

function create_conda_mirror(){
  mirror_config="conda-mirror.yaml"
  cat > "${mirror_config}" <<EOF
blacklist:
    - name: "*"
whitelist:
    - name: "*py3"
EOF

  echo "# conda-mirror.screenrc" > "${mirror_screenrc}"
  i=1
  for channel in 'rapidsai' 'nvidia' ; do
  #  + 'conda-forge' # Mirroring this at the current rate of 1.2 seconds per package may take 1.5 years
    #num_threads="$(expr $(expr $(nproc) / ${num_channels})  - 1)"
    num_threads=12
    channel_path="${mirror_mountpoint}/${channel}"
    cmd=$(echo "${CONDA_MIRROR}" -vvv        \
      --upstream-channel="${channel}"        \
              --platform="linux-64"          \
        --temp-directory="${tmp_dir}"        \
      --target-directory="${channel_path}"   \
           --num-threads="${num_threads}" )
  #             --config="${mirror_config}"
#    --no-validate-target \
  	echo "screen -L -t ${channel} ${i} $cmd" >> "${mirror_screenrc}"
    i="$(expr $i + 1)"
  done

  # block until all channel mirrors are built and verified
  time screen -US "conda-mirror" -c "${mirror_screenrc}"
}

readonly timestamp="$(date +%F-%H-%M)"

prepare_conda_mirror
create_conda_mirror
