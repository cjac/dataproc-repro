#!/usr/bin/perl -w
use strict;
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
# This script installs creates a debian mirror

my( @files ) = split($/,qx(find /etc/apt/sources.list.d -type f));

use Data::Dumper;

die Data::Dumper::Dumper( \@files );

# TODO: For each file found, create a ftpsync.conf or create a list of
# URLs to feed to the mirror script
