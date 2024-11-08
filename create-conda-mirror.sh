#!/bin/bash

set -ex

function compare_versions_lte() { [ "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ] ; }
function compare_versions_lt() { [ "$1" = "$2" ] && return 1 || compare_versions_lte $1 $2 ; }

. env.sh

# Use the base image created for use with rapids
IMAGE_WITH_CERTS="rapids-pre-init-2-2-debian12-2024-10-31-07-41"
DATAPROC_IMAGE_VERSION="2.2"

eval "$(bash create-key-pair.sh)"
metadata="public_secret_name=${public_secret_name},private_secret_name=${private_secret_name},secret_project=${secret_project},secret_version=${secret_version}"
metadata="cleanup-after=yes"
#metadata="cleanup-after=no"

if ( gcloud compute images describe ${IMAGE_WITH_CERTS} > /dev/null 2>&1 ) ; then
  echo "image ${IMAGE_WITH_CERTS} already exists"
else
  echo "image generation not supported in free version.
        Please purchase subscription from Collier Technologies LLC."
fi

function recreate_disk(){
  local disk_size_gb="300"
  local disk_type="pd-ssd"
  # https://business-docs.anaconda.com/en/latest/admin/mirrors.html
  /dev/null <<EOF

Active mirroring will download all the packages not filtered out of
your mirror immediately to your local server. These mirrors can be
extremely large in size; the Anaconda’s public repository is 700GB,
the conda-forge repository is 3TB, and the PyPI repository is 10TB in
their entirety! Due to this, active mirrors can take a long time to
complete.

EOF
  gcloud compute disks delete "${CONDA_MIRROR_DISK_NAME}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}"
  # replicate to the first two zones in the region, with asciibetical sort order
  # TODO: translate to json for easier value extraction
  replica_zones="$(gcloud compute zones list | \
    perl -e '@l=sort map{/^([^\s]+)/}grep{ /^$ARGV[0]/ } <STDIN>; print(join(q{,},@l[0,1]),$/)' ${REGION})"
  gcloud compute disks create "${CONDA_MIRROR_DISK_NAME}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --type="${disk_type}" \
      --replica-zones="${replica_zones}" \
      --size="${disk_size_gb}GB"
  gcloud compute disks resize "${CONDA_MIRROR_DISK_NAME}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --size="${disk_size_gb}GB"

}

function start_conda_mirror_instance(){

  secure_boot_arg="--shielded-secure-boot"
  # Dataproc images prior to 2.2 do not recognize the trust database
  if (compare_versions_lt "${DATAPROC_IMAGE_VERSION}" "2.2") ; then
    secure_boot_arg="--no-shielded-secure-boot" ; fi

  gcloud compute instances create "${INSTANCE_NAME}" \
    --service-account="${GSA}" \
    --machine-type="${CONDA_MM_TYPE}" \
    "${secure_boot_arg}" \
    --accelerator="type=nvidia-tesla-t4,count=4" \
    --maintenance-policy TERMINATE \
    --zone="${ZONE}" \
    --network-interface="subnet=${SUBNET},private-network-ip=${CONDA_REGIONAL_MIRROR_ADDR[${REGION}]},address=" \
    --boot-disk-size=50G \
    --boot-disk-type=pd-ssd \
    --image-project "${PROJECT_ID}" \
    --image="${IMAGE_WITH_CERTS}" \
    --metadata="${metadata}" \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --disk="auto-delete=no,name=${CONDA_DISK_FQN},mode=rw,boot=no,device-name=${CONDA_MIRROR_DISK_NAME},scope=regional" #\
#    --metadata-from-file="startup-script=lib/conda-mirror/sync-mirror.sh"
#    --network-interface="subnet=${SUBNET},address="
}

# boot a VM with this image
INSTANCE_NAME="dpgce-conda-mirror-${REGION}"
if ( gcloud compute instances describe "${INSTANCE_NAME}" --format json \
         > "/tmp/${INSTANCE_NAME}.json" ) ; then
  echo "instance ${INSTANCE_NAME} already online."
  gcloud compute instances delete -q "${INSTANCE_NAME}"
else
  echo "instance ${INSTANCE_NAME} is not yet extant."
fi
start_conda_mirror_instance
sleep 45

# copy script for installing conda-mirror
gcloud compute scp \
       "lib/conda-mirror/sync-mirror.sh" \
       --zone "${ZONE}" \
       "${INSTANCE_NAME}:/tmp/" \
       --project "${PROJECT_ID}" \
       --tunnel-through-iap

gcloud compute ssh \
       --zone "${ZONE}" \
       "${INSTANCE_NAME}" \
       --project "${PROJECT_ID}" \
       --tunnel-through-iap
