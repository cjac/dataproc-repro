#!/bin/bash


set -x
set -e

. env.sh

# https://github.com/glevand/secure-boot-utils

# https://cloud.google.com/compute/shielded-vm/docs/creating-shielded-images#adding-shielded-image

# https://cloud.google.com/compute/shielded-vm/docs/creating-shielded-images#generating-security-keys-certificates

# https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#Creating_keys

eval "$(bash create-key-pair.sh)"

ITERATION=047
export REGION="$(jq -r .REGION env.json)"
export ZONE="${REGION}-a"

# gcloud compute images list --format json | jq > image-list-$(date +%F).json
# https://www.googleapis.com/compute/v1/projects/debian-cloud/global/images/debian-11-bullseye-v20240110

#SOURCE_IMAGE="debian-12-bookworm-v20240110"
#SOURCE_IMAGE="debian-12-bookworm-v20240515"
SOURCE_IMAGE="debian-12-bookworm-v20240910"
# Dataproc images can be found with:

# find image by: gcloud compute images list --project cloud-dataproc | grep dataproc-2-2-deb12

# gcloud compute images create gpu-2-2-debian12-2024-10-05-03-40-install --project=${PROJECT_ID} --source-disk-zone=us-west4-a --source-disk=projects/cloud-dataproc/global/images/dataproc-2-2-deb12-20240903-031150-rc01 --signature-database-file=tls/db.der,tls/MicCorUEFCA2011_2011-06-27.crt --guest-os-features=UEFI_COMPATIBLE --family=dataproc-custom-image
# + gcloud compute disks create gpu-2-2-debian12-2024-10-05-03-40-install --project=${PROJECT_ID} --zone=us-west4-a --image=projects/cloud-dataproc/global/images/dataproc-2-2-deb12-20240903-031150-rc01 --type=pd-ssd --size=50GB


# Use the base image created for use with rapids
IMAGE_WITH_CERTS="rapids-pre-init-2-2-debian12-2024-10-31-07-41"
DATAPROC_IMAGE_VERSION="2.2"

eval "bash create-key-pair.sh"
metadata="public_secret_name=${public_secret_name},private_secret_name=${private_secret_name},secret_project=${secret_project},secret_version=${secret_version}"

if ( gcloud compute images describe ${IMAGE_WITH_CERTS} > /dev/null 2>&1 ) ; then
    echo "image ${IMAGE_WITH_CERTS} already exists"
else
    echo "image generation not supported"
fi

CONDA_MIRROR_DISK_NAME="conda-mirror-${REGION}"
CONDA_DISK_FQN="projects/${PROJECT_ID}/regions/${REGION}/disks/${CONDA_MIRROR_DISK_NAME}"
if [[ "0" == "1" ]]; then
  # https://business-docs.anaconda.com/en/latest/admin/mirrors.html
  /dev/null <<EOF

Active mirroring will download all the packages not filtered out of
your mirror immediately to your local server. These mirrors can be
extremely large in size; the Anaconda’s public repository is 700GB,
the conda-forge repository is 3TB, and the PyPI repository is 10TB in
their entirety! Due to this, active mirrors can take a long time to
complete.

EOF
  replica_zones="$(gcloud compute zones list | perl -e '@l=map{/^([^\s]+)/}grep{ /^$ARGV[0]/ } <STDIN>; print(join(q{,},@l[0,1]),$/)' ${REGION})"
  gcloud compute disks create "${CONDA_MIRROR_DISK_NAME}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --type="pd-balanced" \
      --replica-zones="${replica_zones}" \
      --size="15TB"
fi

function compare_versions_lte {
  [ "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
}

function compare_versions_lt() {
  [ "$1" = "$2" ] && return 1 || compare_versions_lte $1 $2
}

# boot a VM with this image
MACHINE_TYPE=n1-standard-8
INSTANCE_NAME="dpgce-conda-mirror-${REGION}"
if ( gcloud compute instances describe "${INSTANCE_NAME}" > /dev/null 2>&1 ) ; then
    echo "instance ${INSTANCE_NAME} already online.  Deleting"
#    gcloud compute instances delete -q "${INSTANCE_NAME}" --zone ${ZONE}
else
echo "it's not online."
  secure_boot_arg="--shielded-secure-boot"
  # Dataproc images prior to 2.2 do not recognize the trust database
  if (compare_versions_lt "${DATAPROC_IMAGE_VERSION}" "2.2") ; then
    secure_boot_arg="--no-shielded-secure-boot" ; fi

  gcloud compute instances create "${INSTANCE_NAME}" \
    --machine-type="${MACHINE_TYPE}" \
    --maintenance-policy TERMINATE \
    "${secure_boot_arg}" \
    --accelerator="type=nvidia-tesla-t4,count=4" \
    --zone="${ZONE}" \
    --boot-disk-size=50G \
    --boot-disk-type=pd-ssd \
    --image-project "${PROJECT_ID}" \
    --image="${IMAGE_WITH_CERTS}" \
    --metadata="${metadata}" \
    --disk="auto-delete=no,name=${CONDA_DISK_FQN},mode=rw,boot=no,device-name=${CONDA_MIRROR_DISK_NAME},scope=regional"

  sleep 30
fi

gcloud compute scp \
       "lib/conda-mirror/sync-mirror.sh" \
       --zone "${ZONE}" \
       "${INSTANCE_NAME}:/tmp/" \
       --project "${PROJECT_ID}" \
       --tunnel-through-iap


DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
COMPONENTS="main contrib non-free non-free-firmware"
gcloud compute ssh \
       --zone "${ZONE}" \
       "${INSTANCE_NAME}" \
       --project "${PROJECT_ID}" \
       --tunnel-through-iap

set +x
