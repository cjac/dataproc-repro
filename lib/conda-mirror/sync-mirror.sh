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

function install_thin_proxy(){
  dpkg -l libapache2-mod-perl2 > /dev/null 2>&1 \
        || apt-get -y -qq install \
         libplack-perl \
	 libfile-libmagic-perl \
         libapache2-mod-perl2 \
	 libwww-mechanize-perl \
	 libcoro-perl \
	 libev-perl \
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
  my $requested_file=join('','/var/www/html',$path_info);

  my $s = $GoogleCloudDataproc::CondaMirror::ThinProxy::svr;

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
    my $response = $GoogleCloudDataproc::CondaMirror::ThinProxy::mech->get( $src_url );

    if ( $response->is_success ) {
      $GoogleCloudDataproc::CondaMirror::ThinProxy::mech->save_content( $requested_file );
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
  systemctl restart apache2
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
#   Maybe update the conda repo before starting
#    "${CONDA}" update -n base -c defaults conda
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
  echo "exit handler invoked"
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
      echo gcloud compute disks create "${CONDA_MIRROR_DISK_NAME}-${timestamp}" \
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
    
  if [[ ! -e "${mirror_block}" ]] ; then
    gcloud compute instances attach-disk "$(hostname -s)" \
      --disk        "${CONDA_DISK_FQN}" \
      --device-name "${CONDA_MIRROR_DISK_NAME}" \
      --disk-scope  "regional" \
      --zone        "${ZONE}"  \
      --mode        "${mode}"
  fi

  if [[ "${mode}" == "rw" ]] ; then
    if e2fsck -n "${mirror_block}" > /dev/null 2>&1 ; then
      if grep -q "${mirror_mountpoint}" /proc/mounts ; then umount_mirror_block_device || return -1 ; fi
      e2fsck -fy "${mirror_block}"
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
      systemctl stop apache2
      umount_mirror_block_device
      detach_conda_mirror_disk
      attach_conda_mirror_disk rw
      # If the above fails, it's sometimes because there are VMs which
      # have attached to the block device in ro mode
      options="${mode}"
      if grep -q "${mirror_mountpoint}" /proc/mounts ; then
	"options=remount,${mode}"
      fi
      mount -o "${options}" "${mirror_block}" "${mirror_mountpoint}"
    fi
  else
    echo "mounting ${mirror_block} on ${mirror_mountpoint}"
    mkdir -p "${mirror_mountpoint}"
#    mount "${mirror_block}" "${mirror_mountpoint}"
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
  install_thin_proxy
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
platforms:
    - "linux-64"
    - "noarch"
blacklist:
    - name: "*"
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
    - name: "dask-sql"
    - name: "dask-yarn"
    - name: "distributed"
    - name: "fiona"
    - name: "cudf"
    - name: "numba"
    - name: "rmm"
EOF

  echo "# conda-mirror.screenrc" > "${mirror_screenrc}"
  i=1
#  for channel in 'conda-forge' 'rapidsai' 'nvidia' ; do
  for channel in 'rapidsai' 'nvidia' ; do
    #  + 'conda-forge' # Mirroring this at the current rate of 1.2 seconds per package may take 1.5 years
    #num_threads="$(expr $(expr $(nproc) / ${num_channels})  - 1)"
    num_threads=30
    channel_path="${mirror_mountpoint}/${channel}"
    for platform in 'noarch' 'linux-64' ; do
      if [[ "${channel}" == "conda-forge" ]] ; then
        if [[ "${platform}" == "noarch" ]] ; then continue ; fi
        CONFIG_PARAM="--config=${mirror_config}"
      else
        CONFIG_PARAM=""
      fi
      cmd=$(echo "${CONDA_MIRROR}" -vvv -D     \
        --upstream-channel="${channel}"        \
                --platform="${platform}"       \
          --temp-directory="${tmp_dir}"        \
        --target-directory="${channel_path}"   \
             --num-threads="${num_threads}"    \
                  "${CONFIG_PARAM}"
#     --no-validate-target \
       )
      # run the mirror sync command until it is successful
      echo "screen -L -t ${channel}-${platform} ${i} bash -c '/bin/false ; while [[ '\$?' != '0' ]] ; do $cmd ; done'" >> "${mirror_screenrc}"
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
  date
  time screen -US "conda-mirror" -c "${mirror_screenrc}"
  date
}

readonly timestamp="$(date +%F-%H-%M)"

prepare_conda_mirror
create_conda_mirror
