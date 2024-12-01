#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS-IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This script creates a debian mirror under /var/www/html

readonly timestamp="$(date +%F)"

# https://www.debian.org/mirror/ftpmirror#how
git clone 'https://salsa.debian.org/mirror-team/archvsync.git'
cd archvsync

RSYNC_HOST="deb.debian.org"
RSYNC_PATH="debian"
TO="/var/www/html/${RSYNC_HOST}/${RSYNC_PATH}"
mkdir -p "${TO}"

cat > ~/.config/ftpsync/ftpsync.conf <<EOF
MIRRORNAME=`hostname -f`
TO="${TO}"
RSYNC_HOST="${RSYNC_HOST}"
RSYNC_PATH="${RSYNC_PATH}"
INFO_THROUGHPUT=100Gb
EOF


time bash -x bin/ftpsync "${RSYNC_HOST}-${timestamp}"
