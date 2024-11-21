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
this_file=$0;

#
# This script is copied to the conda mirror synchronization host.  The
# host must have ${RAPIDS_DISK_FQN} attached in rw mode. After running
# this script, the attached disk will have an ext4 filesystem written
# directy to it, no partitions.  On this filesystem, conda channels
# will be mirrored to the / directory
#
# In addition, the content will be served from http://$(hostname -s)/
#

function execute_with_retries() (
  set +x
  local -r cmd="$*"

  if [[ "$cmd" =~ "^apt-get install" ]] ; then
    apt-get -y clean
    apt-get -y autoremove
  fi
  for ((i = 0; i < 3; i++)); do
    set -x
    time eval "$cmd" > "${install_log}" 2>&1 && retval=$? || { retval=$? ; cat "${install_log}" ; }
    set +x
    if [[ $retval == 0 ]] ; then return 0 ; fi
    sleep 5
  done
  return 1
)

function install_apache(){
  which a2ensite || \
  apt-get install -y -qq apache2 > /dev/null 2>&1
  a2enmod authz_core
  systemctl enable apache2
  rm -f "${mirror_mountpoint}/index.html"
  APACHE_INSTALLED=1
}

function install_thin_proxy(){
  dpkg -l libapache2-mod-perl2 > /dev/null 2>&1 \
        || apt-get -y -qq install \
         libplack-perl \
	 libfile-libmagic-perl \
         libapache2-mod-perl2 \
	 libwww-mechanize-perl \
	 libcoro-perl \
	 libev-perl \
	 libdatetime-perl \
	 > /dev/null 2>&1
  APACHE_LOG_DIR="/var/log/apache2"
  cat > /etc/apache2/sites-available/thin-proxy.conf <<EOF
<VirtualHost 10.42.79.42:80>
  ServerName thin-proxy

  ServerAdmin webmaster@localhost
  DocumentRoot /var/www/html/

  <Location />
    SetHandler perl-script
    PerlResponseHandler Plack::Handler::Apache2
    PerlSetVar psgi_app /var/www/thin-proxy.psgi
  </Location>
  # perform some startup operations
  PerlPostConfigRequire /var/www/startup.pl

  ErrorLog ${APACHE_LOG_DIR}/thin-proxy/error.log
  CustomLog ${APACHE_LOG_DIR}/thin-proxy/access.log combined

</VirtualHost>
EOF
  cat > /var/www/thin-proxy.psgi <<'EOF'
#!/usr/bin/perl -w
use strict;

package GoogleCloudDataproc::CondaMirror::ThinProxy;
use Plack::Handler::Apache2;
use Plack::Request;
use Data::Dumper;
use File::LibMagic;
use WWW::Mechanize;
use APR::Const -compile => qw(:error SUCCESS);

my $app = sub {
  my $env = shift; # PSGI env
  my $req = Plack::Request->new($env);
  my $path_info = $req->path_info;
  my $requested_file=join('','/var/www/html/conda.anaconda.org',$path_info);

  my $s = $GoogleCloudDataproc::CondaMirror::ThinProxy::svr;
  my $mech = $GoogleCloudDataproc::CondaMirror::ThinProxy::mech;

  # When requesting repodata.json, always fetch from upstream
  if ( $path_info =~ /repodata\.json(\.zst|\.gz|\.xz|.zip)?$/ ){
    my $suffix = $1;
    $requested_file='/tmp/repodata.json' . ( $suffix ? $suffix : '' );
    unlink $requested_file if -f $requested_file;
  }

  if( ! -f $requested_file ) {
    $s->log_serror(Apache2::Log::LOG_MARK, Apache2::Const::LOG_INFO,
                     APR::Const::SUCCESS, "requested file ${path_info}");
    # Unless the file already exists, fetch it from upstream
    my $src_url = join('','https://conda.anaconda.org', $path_info);

    if ( my $response = $mech->get( $src_url )->is_success() ) {
      $mech->save_content( $requested_file );
    } else {
      my $res = $req->new_response($response->code); # new Plack::Response
      $res->body("file [$path_info] found neither under file://$requested_file nor on ${src_url}$/");
      return $res->finalize;
    }
  }

  my $size = (stat($requested_file))[7];

  my $res = $req->new_response(200); # new Plack::Response
  $res->headers({ 'Content-Type' => File::LibMagic->new->info_from_filename(qq{$requested_file})->{mime_type} });
  $res->content_length($size);
  open(my($fh), q{<}, $requested_file);
  $res->body($fh);

  $res->finalize;
};
EOF
  cat > /var/www/startup.pl <<'EOF'
#!/usr/bin/env perl

use strict;
use warnings;
use Apache2::ServerUtil ();
use Apache2::Log;
use Cpanel::JSON::XS;
use WWW::Mechanize ();

use vars qw($repodata $mech $svr);

package GoogleCloudDataproc::CondaMirror::ThinProxy;

BEGIN {
  use Apache2::Const -compile => qw(LOG_DEBUG LOG_INFO);
  return unless Apache2::ServerUtil::restart_count() > 1;

  require Plack::Handler::Apache2;
  our $mech = WWW::Mechanize->new();
  our $svr = Apache2::ServerUtil->server;
  $svr->loglevel(Apache2::Const::LOG_INFO);
  our $repodata = {};
#  my $response = $mech->get('https://conda.anaconda.org/conda-forge/linux-64/repodata.json');
#  if( $response->is_success ){
#    $repodata->{'linux-64'}  = decode_json $response->decoded_content;
#  }
#  $mech->get('https://conda.anaconda.org/conda-forge/noarch/repodata.json');
#  if( $response->is_success ){
#    $repodata->{'noarch'}  = decode_json $response->decoded_content;
#  }
}

1; # file must return true!
EOF
  chown www-data:www-data /var/www/thin-proxy.psgi
  a2ensite thin-proxy
  mkdir -p /var/log/apache2/thin-proxy
  if [[ "${APACHE_INSTALLED}" == "1" ]]; then
    systemctl restart apache2 || echo "could not restart apache2"
  fi
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
  sync
  sleep 3s
  sync
  if grep -q "${tmp_dir}" /proc/mounts ; then
    umount "${tmp_dir}"
  fi
}

function install_conda_mirror(){
  if [[ ! -f "${CONDA_MIRROR}" ]] ; then
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
    --disk        "${RAPIDS_DISK_FQN}" \
    --device-name "${RAPIDS_MIRROR_DISK_NAME}" \
    --disk-scope  "regional" \
    --zone        "${ZONE}"  \
    --mode        "${mode}"
}

function detach_conda_mirror_disk(){
  # Clean the filesystem
  current_mount_mode=$(perl -e '@f=(split(/\s+/, $ARGV[0]));print($f[3]=~/(ro|rw)/);' "$(grep "${mirror_mountpoint}" /proc/mounts)")
  if [[ "${current_mount_mode}" == "rw" ]] ; then
    execute_with_retries e2fsck -fy "${mirror_block}"
  fi

  gcloud compute instances detach-disk "$(hostname -s)" \
    --disk       "${RAPIDS_DISK_FQN}" \
    --zone       "${ZONE}" \
    --disk-scope regional
}

function exit_handler(){
  echo "exit handler invoked"
  set +e
  local cleanup_after="$(/usr/share/google/get_metadata_value attributes/cleanup-after || echo '')"
  echo "cleanup_after=${cleanup_after}"

  # If the mirror was not built, do not perform clean up steps
  if [[ "${MIRROR_BUILT}" != "1" ]]; then return 0 ; fi
  
  case "${cleanup_after}" in
    "y" | "yes" | "true" )
      echo "cleaning up"
    ;;
    "*" )
      echo "no clean-up"
      return 0
    ;;
  esac

  # When the script finishes, detach and re-attach the disk in read-only mode

  # stop apache, since it serves http from the mount point
  if [[ "${APACHE_INSTALLED}" == "1" ]]; then
    systemctl stop apache2 || echo "could not stop apache2"
  fi
  # unmount the rw disk, detach the virtual device
  umount_mirror_block_device
  detach_conda_mirror_disk
  # attach a new device with the same name in ro mode
  attach_conda_mirror_disk ro
  mount_mirror_block_device ro
  # unmount the tmpfs temp directory
  umount_tmp_dir
  # bring apache back online to serve a ro copy of the archive via http
  if [[ "${APACHE_INSTALLED}" == "1" ]]; then
    systemctl restart apache2 || echo "could not restart apache2"
  fi
  # Take a snapshot of the archive
  replica_zones="$(gcloud compute zones list | \
    perl -e '@l=sort map{/^([^\s]+)/}grep{ /^$ARGV[0]/ } <STDIN>; print(join(q{,},@l[0,1]),$/)' ${REGION})"
  gcloud compute disks create "${RAPIDS_MIRROR_DISK_NAME}-${timestamp}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --source-disk "${RAPIDS_MIRROR_DISK_NAME}" \
    --source-disk-region="${REGION}" \
    --replica-zones="${replica_zones}"
  umount_mirror_block_device
  detach_conda_mirror_disk
  attach_conda_mirror_disk rw
  mount_mirror_block_device rw
  if [[ "${APACHE_INSTALLED}" == "1" ]]; then
    systemctl start apache2 || echo "could not start apache2"
  fi
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

  if [[ ! -e "${mirror_block}" ]] ; then
    gcloud compute instances attach-disk "$(hostname -s)" \
      --disk        "${RAPIDS_DISK_FQN}" \
      --device-name "${RAPIDS_MIRROR_DISK_NAME}" \
      --disk-scope  "regional" \
      --zone        "${ZONE}"  \
      --mode        "${mode}"
  fi

  if [[ "${mode}" == "rw" ]] ; then
    # The following command checks whether an ext4 filesystem exists
    # on the mirror block device
    if e2fsck -n "${mirror_block}" > /dev/null 2>&1 ; then
      if grep -q "${mirror_mountpoint}" /proc/mounts ; then umount_mirror_block_device || echo "could not umount" ; fi
    else
      echo "creating filesystem on mirror block device"
      mkfs.ext4 "${mirror_block}"
    fi
  fi

  #/dev/sdb /var/www/html ext4 rw,relatime 0 0
  if grep -q "${mirror_mountpoint}" /proc/mounts ; then
    # If already mounted, find out the mode
    current_mount_mode=$(perl -e '@f=(split(/\s+/, $ARGV[0]));print($f[3]=~/(ro|rw)/);' "$(grep "${mirror_mountpoint}" /proc/mounts)")
    if [[ "${mode}" == "rw" && "${current_mount_mode}" == "ro" ]] ; then
      echo "remounting in read/write mode"
      if [[ "${APACHE_INSTALLED}" == "1" ]]; then
        systemctl stop apache2 || echo "could not stop apache2"
      fi
      umount_mirror_block_device
      detach_conda_mirror_disk
      attach_conda_mirror_disk rw

      # If the above fails, it's sometimes because there are VMs which
      # have attached to the block device in ro mode
    elif [[ "${mode}" == "ro" && "${current_mount_mode}" == "ro" ]] ; then
      echo "remounting in read/write mode"
      if [[ "${APACHE_INSTALLED}" == "1" ]]; then
        systemctl stop apache2 || echo "could not stop apache2"
      fi
      umount_mirror_block_device
      detach_conda_mirror_disk
      attach_conda_mirror_disk ro

    fi
  else
    echo "mounting ${mirror_block} on ${mirror_mountpoint}"
    mkdir -p "${mirror_mountpoint}"
  fi
  mount -o "${mode}" "${mirror_block}" "${mirror_mountpoint}"

  current_mount_mode=$(perl -e '@f=(split(/\s+/, $ARGV[0]));print($f[3]=~/(ro|rw)/);' "$(grep "${mirror_mountpoint}" /proc/mounts)")
}
function umount_mirror_block_device(){
  sync
  sleep 3s
  sync
  umount "${mirror_block}" || echo "unable to umount ${mirror_block}"
}

function prepare_conda_mirror(){
  zone="$(/usr/share/google/get_metadata_value zone)"
  ZONE="$(echo $zone | sed -e 's:.*/::')"
  REGION="$(echo ${ZONE} | perl -pe 's/^(.+)-[^-]+$/$1/')"
  PROJECT_ID="$(gcloud config get project)"
  CONDA_PFX="/opt/conda/miniconda3"
  CONDA="${CONDA_PFX}/bin/conda"
  MAMBA="${CONDA_PFX}/bin/mamba"
  CONDA_MIRROR="${CONDA}-mirror"
  RAPIDS_MIRROR_DISK_NAME="rapids-mirror-${REGION}"
  RAPIDS_DISK_FQN="projects/${PROJECT_ID}/regions/${REGION}/disks/${RAPIDS_MIRROR_DISK_NAME}"
  MIRROR_BUILT=0
  APACHE_INSTALLED=0

  mirror_block="/dev/disk/by-id/google-${RAPIDS_MIRROR_DISK_NAME}"
  mirror_mountpoint="/var/www/html"
  conda_cache_dir="${mirror_mountpoint}/conda_cache"
  tmp_dir="/mnt/shm"
  install_log="${tmp_dir}/install.log"

  # clean up after
  trap exit_handler EXIT

  # Allow processes to use a lot of filehandles
  ulimit -n 4096

  mount_mirror_block_device rw
  install_apache
  install_thin_proxy
  install_screen
  mount_tmp_dir
  # Cache results of build on mirror disk
  mkdir -p "${conda_cache_dir}"
  "${CONDA}" config --add pkgs_dirs "${conda_cache_dir}" > /dev/null 2>&1
  # Unpin conda
#  sed -i -e 's/^conda .*$//' /opt/conda/miniconda3/conda-meta/pinned
  #   Maybe update the conda install before starting
#  "${MAMBA}" update -n base -c defaults conda mamba libmamba libmambapy conda-libmamba-solver

  #install_conda_mirror
}

function rm_conda_env(){
  env_name="$1"
  env_dir="/opt/conda/miniconda3/envs/${env_name}"
  if test -d "${env_dir}" ; then
    "${CONDA}" remove -n "${env_name}" --all > /dev/null 2>&1 || rm -rf "${env_dir}"
  fi
}

function create_build_cache(){

  CONDA_EXE="${CONDA_PFX}/bin/conda"
  CONDA_PYTHON_EXE="${CONDA_PFX}/bin/python"
  PATH="${CONDA_PFX}/bin/condabin:${CONDA_PFX}/bin:${PATH}"

  declare -A specs_to_cache=(
    "dask-bigquery dask-ml dask-sql 'cuda-version>=12,<13' 'dask<2022.2' 'dask-yarn=0.9' 'distributed<2022.2'"
    "dask-bigquery dask-ml dask-sql 'cuda-version>=12,<13' 'dask<2022.2' 'dask-yarn=0.9' 'distributed<2022.2' fiona<1.8.22"
    "dask-bigquery dask-ml dask-sql 'cuda-version>=11,<12' 'dask<2022.2' 'python>=3.9' 'dask-yarn=0.9' 'distributed<2022.2'"
    "dask-bigquery dask-ml dask-sql 'cuda-version>=11,<12' 'dask<2022.2' 'python>=3.9' 'dask-yarn=0.9' 'distributed<2022.2' 'fiona<1.8.22'"
    "dask-bigquery dask-ml dask-sql 'cuda-version>=12,<13' 'dask>=2024.5' 'python>=3.11'"
    "dask-bigquery dask-ml dask-sql 'cuda-version>=11,<12' dask 'python>=3.9'"
    "'cuda-version>=12,<13' 'rapids>=23.11' dask cudf numba 'python>=3.11'"
    "pytorch tensorflow"
  )

  rm_conda_env myenv

  for spec in "${specs_to_cache[@]}"; do
    time "${MAMBA}" create -q -m -n "myenv" -y --no-channel-priority -c conda-forge -c nvidia -c rapidsai ${spec}
    rm_conda_env myenv
  done
}

function create_conda_mirror(){
  time perl '/tmp/mirror/sync-conda.pl'
}

#time "${CONDA_MIRROR}" -v -D \
#    --upstream-channel=defaults    \
#    --upstream-channel=https://repo.anaconda.cloud/pkgs/main \
#    --upstream-channel=https://repo.anaconda.cloud/pkgs/r \
# https://conda.anaconda.org/main/linux-64/repodata.json is the correct repodata URL for Anaconda Distribution

function validate_conda_mirror(){
  mirror_config="conda-mirror.yaml"
  cat > "${mirror_config}" <<EOF
platforms:
    - "linux-64"
    - "noarch"
whitelist:
    - name: "rapids"
    - name: "rapids-dask-dependency"
    - name: "rapids-xgboost"
    - name: "libxgboost"
    - name: "xgboost"
    - name: "dask"
    - name: "dask-bigquery"
    - name: "dask-cuda"
    - name: "dask-ml"
    - name: "dask-glm"
    - name: "dask-sql"
    - name: "dask-yarn"
    - name: "distributed"
    - name: "fiona"
    - name: "cudf"
    - name: "dlpack"
    - name: "cupy"
    - name: "numba"
    - name: "networkx"
    - name: "nx-cugraph"
    - name: "nvtx"
    - name: "rmm"
    - name: "python"
    - name: "python_abi"
    - name: "tzdata"
    - name: "pip"
    - name: "pyarrow"
    - name: "libcudf_cffi"
    - name: "cachetools"
    - name: "fastavro"
EOF

  i=10
  for channel in 'nvidia' 'rapidsai' 'r' 'main' 'conda-forge' ; do
    num_threads="$(nproc)"
    channel_path="${mirror_mountpoint}/${channel}"
    for platform in 'noarch' 'linux-64' ; do
      screen_title="conda-mirror-${channel}-${platform}"
      mirror_screenrc="/tmp/${screen_title}.screenrc"
      echo "# $screen_title}.screenrc" > "${mirror_screenrc}"
      # consider -vvv for debugging
      cmd=$( echo \
    "${CONDA_MIRROR}"                          \
        --upstream-channel="${channel}"        \
                --platform="${platform}"       \
          --temp-directory="${tmp_dir}"        \
        --target-directory="${channel_path}"   \
             --num-threads="${num_threads}"    \
                  --config="${mirror_config}"
#	      --no-progres
#     --no-validate-target \
	 )
      # run the mirror sync command in a screen session until it is successful
      echo "screen -L -t ${channel}-${platform} ${i} bash -c '/bin/false ; while [[ '\$?' != '0' ]] ; do $cmd ; done'" \
	   > "${mirror_screenrc}"
      time screen -US "${screen_title}" -c "${mirror_screenrc}"
#      eval "$cmd"

    done
    i="$(expr $i + 1)"
  done

  # Verifying that the mirror disk is mounted
  if ! grep -q "${mirror_mountpoint}" /proc/mounts ; then
    echo "mirror did not get mounted"
    return -1
  fi

  # block until all channel mirrors are built and verified
  echo "building channel mirrors"
#  date
#  time screen -US "conda-mirror" -c "${mirror_screenrc}"
#  date
}

readonly timestamp="$(date +%F-%H-%M)"

prepare_conda_mirror
#create_conda_mirror
create_build_cache
#validate_conda_mirror

MIRROR_BUILT=1
