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

# gcloud compute images create gpu-2-2-debian12-2024-10-05-03-40-install --project=cjac-2021-00 --source-disk-zone=us-west4-a --source-disk=projects/cloud-dataproc/global/images/dataproc-2-2-deb12-20240903-031150-rc01 --signature-database-file=tls/db.der,tls/MicCorUEFCA2011_2011-06-27.crt --guest-os-features=UEFI_COMPATIBLE --family=dataproc-custom-image
# + gcloud compute disks create gpu-2-2-debian12-2024-10-05-03-40-install --project=cjac-2021-00 --zone=us-west4-a --image=projects/cloud-dataproc/global/images/dataproc-2-2-deb12-20240903-031150-rc01 --type=pd-ssd --size=50GB


# Use the base image created for use with rapids
IMAGE_WITH_CERTS="rapids-pre-init-2-2-debian12-2024-10-31-07-41"
DATAPROC_IMAGE_VERSION="2.2"

if ( gcloud compute images describe ${IMAGE_WITH_CERTS} > /dev/null 2>&1 ) ; then
    echo "image ${IMAGE_WITH_CERTS} already exists"
else
    curl 'https://raw.githubusercontent.com/LLC-Technologies-Collier/custom-images/refs/heads/main/examples/secure-boot/create-key-pair.sh'
    eval "bash create-key-pair.sh"
    # The Microsoft Corporation UEFI CA 2011
    MS_UEFI_CA="tls/MicCorUEFCA2011_2011-06-27.crt"

    echo gcloud compute images create "${IMAGE_WITH_CERTS}" \
       --source-image "${SOURCE_IMAGE}" \
       --source-image-project debian-cloud \
       --signature-database-file="tls/db.der,${MS_UEFI_CA}" \
       --guest-os-features="UEFI_COMPATIBLE"

    # find source-image by:
    # gcloud compute images list --project cloud-dataproc | grep dataproc-2-2-deb12

    # The following can be used to create an instance in a similar
    # state to the custom-image script runner VM.

    #gcloud compute images create cuda-12-4-2-2-debian12-2024-10-06-04-57-install \
    gcloud compute images create cuda-pre-init-2-0-debian10-2024-10-10-19-14 \
      --source-image="${SOURCE_IMAGE}" \
      --source-image-project=cloud-dataproc \
      --signature-database-file="tls/db.der,${MS_UEFI_CA}" \
      --guest-os-features=UEFI_COMPATIBLE \
      --family=dataproc-custom-image

    gcloud compute instances create dask-pre-init-2-0-debian10-2024-10-10-23-13-install \
	   --project=cjac-2021-00 \
	   --zone=us-west4-a \
	   --network=projects/cjac-2021-00/global/networks/default \
	   --machine-type=n1-highcpu-4 \
	   --image-project cjac-2021-00 \
	   --image=cuda-pre-init-2-0-debian10-2024-10-10-19-14 \
	   --boot-disk-size=40G \
	   --boot-disk-type=pd-ssd \
	   --accelerator=type=nvidia-tesla-t4 \
	   --maintenance-policy terminate \
	   --service-account=sa-dask-pre-init@cjac-2021-00.iam.gserviceaccount.com \
	   --scopes=cloud-platform \
	   --metadata=shutdown-timer-in-sec=300,custom-sources-path=gs://cjac-dataproc-repro-1718310842/custom-image-dask-pre-init-2-0-debian10-2024-10-10-23-13-20241010-231355/sources,public_secret_name=efi-db-pub-key-042,private_secret_name=efi-db-priv-key-042,secret_project=cjac-2021-00,secret_version=1,dask-runtime=yarn,rapids-runtime=SPARK,cuda-version=12.4 \
	   --metadata-from-file startup-script=startup_script/run.sh

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
    --disk="auto-delete=no,name=${CONDA_DISK_FQN},mode=rw,boot=no,device-name=${CONDA_MIRROR_DISK_NAME},scope=regional"
#  "${secure_boot_arg}" \
#    cuda-2-2-rocky9-2024-10-06-23-52
#    --image-project ${PROJECT_ID} \
#    --image="${IMAGE_WITH_CERTS}"

  sleep 30
fi

gcloud compute scp \
       "lib/conda-mirror/sync-mirror.sh" \
       --zone "${ZONE}" \
       "${INSTANCE_NAME}:/root/" \
       --project "${PROJECT_ID}" \
       --tunnel-through-iap


# https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot
# bootctl
# od --address-radix=n --format=u1 /sys/firmware/efi/efivars/SecureBoot-*
#    6   0   0   0   1
# for var in PK KEK db dbx ; do efi-readvar -v $var -o old_${var}.esl ; done

# Verify cert was installed:
# sudo apt-get install efitools
# sudo efi-readvar -v db
DEBIAN_SOURCES="/etc/apt/sources.list.d/debian.sources"
COMPONENTS="main contrib non-free non-free-firmware"
gcloud compute ssh \
       --zone "${ZONE}" \
       "${INSTANCE_NAME}" \
       --project "${PROJECT_ID}" \
       --tunnel-through-iap

       # --command "
       # mokutil --sb-state
       # sudo sed -i -e 's/Components: .*$/Components: ${COMPONENTS}/' ${DEBIAN_SOURCES} && echo 'sources updated' &&
       # sudo apt-get -qq update && echo 'package cache updated' &&
       # sudo apt-get -qq -y install dkms linux-headers-\$(uname -r) > /dev/null 2>&1 && echo 'dkms and kernel headers installed' &&
       # sudo cp /tmp/tls/db.rsa /var/lib/dkms/mok.key &&
       # sudo cp /tmp/tls/db.der /var/lib/dkms/mok.pub &&
       # echo 'mok files created' &&
       # sudo apt-get -qq -y install nvidia-open-kernel-dkms && echo 'nvidia open kernel package built' &&
       # sudo modprobe nvidia-current-open &&
       # echo 'kernel module loaded'"

       # gcloud secrets versions access 1 --project=${PROJECT_ID} --secret=efi-db-priv-key | base64 --decode | sudo dd of=/var/lib/dkms/mok.key &&
       # gcloud secrets versions access 1 --project=${PROJECT_ID} --secret=efi-db-pub-key | base64 --decode | sudo dd of=/var/lib/dkms/mok.pub &&


       # --command "
       # mokutil --sb-state
       # sudo sed -i -e 's/Components: .*$/Components: ${COMPONENTS}/' ${DEBIAN_SOURCES} && echo 'sources updated' &&
       # sudo apt-get -qq update && echo 'package cache updated' &&
       # sudo apt-get -qq -y install dkms linux-headers-cloud-amd64 && echo 'dkms and kernel headers installed' &&
       # gcloud secrets versions access 1 --project=${PROJECT_ID} --secret=efi-${EFI_VAR_NAME}-priv-key | dd of=/var/lib/dkms/mok.key
       # sudo cp /tmp/tls/db.rsa /var/lib/dkms/mok.key &&
       # gcloud secrets versions access 1 --project=${PROJECT_ID} --secret=efi-${EFI_VAR_NAME}-pub-key | dd of=/var/lib/dkms/mok.pub
       # sudo cp /tmp/tls/db.der /var/lib/dkms/mok.pub && echo 'signing cert/key assigned' &&
       # sudo apt-get -qq -y install nvidia-open-kernel-dkms && echo 'nvidia open kernel package built' &&
       # sudo modprobe nvidia-current-open && echo 'kernel module loaded' &&
       # sudo rm -rf /var/lib/dkms/mok.* && echo "removed key material"
       # "

#       sudo dkms build nvidia-current-open/525.147.05

set +x
