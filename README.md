<!--

Copyright 2024 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS-IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

-->

## Introduction

This README file describes how to use the dataproc-repro scripts to reproduce
common Dataproc cluster creation problems relating to the GCE startup script,
Dataproc startup script, and Dataproc initialization-actions scripts.

## Dataproc on GCE Environment configuration

```
$ git clone https://github.com/LLC-Technologies-Collier/dataproc-repro.git
$ cd dataproc-repro
$ git checkout rapids-mirror-20241115
$ cp env.json.sample env.json
$ vi env.json
$ bash create-dpgce.sh
```

First, copy env.json.sample to env.json and modify the environment variable
names and their values in `env.json` to match your environment:

```
{
  "PROJECT_ID":"ldap-example-yyyy-nn",
  "ORG_NUMBER":"100000000001",
  "DOMAIN": "your-domain-goes-here.com",
  "BILLING_ACCOUNT":"100000-000000-000001",
  "FOLDER_NUMBER":"100000000001",
  "REGION":"us-west4",
  "RANGE":"10.00.01.0/24",
  "IDLE_TIMEOUT":"30m",
  "ASN_NUMBER":"65531",
  "IMAGE_VERSION":"2.2,
  "BIGTABLE_INSTANCE":"my-bigtable"
}
```

The values that you enter here will be used to build reasonable
defaults in env.sh ; you can view and modify env.sh to more finely
tune your environment.  The code in env.sh is sourced and executed at
the head of many scripts in this suite to ensure that the environment
is tuned for use with this reproduction.

#### Dataproc on GCE

To tune the reproduction environment for your (customer's) GCE use case, review
the `create_dpgce_cluster` bash function in the `shared-functions.sh` file.
This is where you can select which arguments are passed to `gcloud dataproc
clusters create ${CLUSTER_NAME}` command.  There exist many examples in the
comments of common use cases below the call to gcloud itself.

## creation phase

When reviewing shared-functions.sh, pay attention to the `--metadata
startup-script="..."` and `--initialization-actions
${INIT_ACTIONS_ROOT}/<script-name>` arguments.  These can be used to execute
arbitrary code during the creation of Dataproc clusters.  Many of our cases
relate to failures during either a) Dataproc's internal startup script, which
runs after the `--metadata startup-script="..."`, or b) scripts passed using the
`--initialization-actions` cluster creation argument.

## creating the environment and cluster

Once you have altered `env.json` and have reviewed the function names in
`shared-functions.sh`, you can create your cluster environment and launch your
cluster by running `bash create-command.sh`.  Do not plan to run this more than
once for a single reproduction.

This will create the staging bucket, enable the required services, create a
dedicated VPC network, router, NAT, subnet, firewall rules, and finally, the
cluster itself.

By default, your cluster will time out and be destroyed after 30 minutes of
inactivity.  You can change this by altering the value of IDLE_TIMEOUT in
`env.json`.  This saves our org operating costs on reproduction clusters which are
not being used to actively reproduce problems.  It also gives you a half of an
hour to do your work before worrying that your cluster will be brought down.

## recreating the cluster

If your cluster has been destroyed, you can re-create it by running `bash
recreate-only.sh`.  This script does not re-create any of the resources the
cluster depends on such as network, router, staging bucket, etc.  It only
deletes and re-creates the cluster that's already been defined in `env.json`.

## deleting the environment and cluster

If you ever need to delete the environment, you can run `bash
destroy-command.sh` ; this will delete the cluster, remove the firewall rules,
subnet, NAT, router, VPC network, and staging bucket.  You can plan to run `bash
create-command.sh` once more after `destroy-command.sh` completes successfully.

### Metadata store

All startup-scripts run on GCE instances, including Dataproc GCE cluster nodes,
may make use of the `/usr/share/google/get_metadata_value` script to look up
information in the metadata store.  The information available in the metadata
server includes the arguments passed when creating the cluster using the
`--metadata` argument.

For instance, if you were to call `gcloud dataproc clusters create
${CLUSTER_NAME}` with the argument `--metadata
init-actions-repo=${INIT_ACTIONS_ROOT}`, then you can find this value by running
`/usr/share/google/get_metadata_value "attributes/init-actions-repo"`.  By
default, there are some attributes which are set for dataproc.  Some important
ones follow:

* attributes/dataproc-role
- value: `Master` for master nodes
- value: `Worker` for primary and secondary worker nodes
* attributes/dataproc-cluster-name
* attributes/dataproc-bucket
* attributes/dataproc-cluster-uuid
* attributes/dataproc-region
* hostname (FQDN)
* name (short hostname)
* machine-type

### GCE Startup script

There is documentation in the GCE library for the
[startup-script](https://cloud.google.com/compute/docs/instances/startup-scripts/linux)
metadata argument

The content of the startup-script, if passed as a string, is stored as
`attributes/startup-script` in the metadata store.  If passed as a url, the url
can be found as `attributes/startup-script-url`.

The GCE startup script runs prior to the Dataproc Agent.  This script can be
used to make small modifications to the environment prior to starting Dataproc
services on the host.

### Dataproc Startup script

The Dataproc agent is responsible for launching the [Dataproc startup
script](https://cs/piper///depot/google3/cloud/hadoop/services/images/startup-script.sh)
and the [initialization
actions](https://github.com/GoogleCloudDataproc/initialization-actions) in order
of specification.

The Dataproc startup script runs before the initialization actions, and logs its
output to `/var/log/dataproc-startup-script.log`.  It is linked to by
`/usr/local/share/google/dataproc/startup-script.sh` on all dataproc nodes.  The
tasks which the startup script run are influenced by the following arguments.
This is not an exhaustive list.  If you are troubleshooting startup errors,
check whether the customer is passing any arguments or setting any properties,
especially any similar to the following.

```
* `--optional-components`
* `--enable-component-gateway`
* `--properties 'dataproc:conda.*=...'`
* `--properties 'dataproc:pip.*=...'`
* `--properties 'dataproc:kerberos.*=...'`
* `--properties 'dataproc:ranger.*=...'`
* `--properties 'dataproc:druid.*=...'`
* `--properties 'dataproc:kafka.*=...'`
* `--properties 'dataproc:yarn.docker.*=...'`
* `--properties 'dataproc:solr.*=...'`
* `--properties 'dataproc:jupyter.*=...'`
* `--properties 'dataproc:zeppelin.*=...'`
```

The Startup script is responsible for configuring the optional components which
the customer has selected in the way that the customer has specified with
properties.  Errors indicating dataproc-startup-script.log often have to do with
configuration of optional components and their services.

### Dataproc Initialization Actions scripts

Documentation for the
[initialization-actions](https://cloud.google.com/dataproc/docs/concepts/configuring-clusters/init-actions)
argument to the `gcloud dataproc clusters create` command can be found in the
Dataproc library.  You may also want to review the
[README.md](https://github.com/GoogleCloudDataproc/initialization-actions/blob/master/README.md)
from the public initialization-actions repo on GitHub.

Do note that you can specify multiple initialization actions scripts.  They will
be executed in the order of specification.  The initialization-actions scripts
are stored to
`/etc/google-dataproc/startup-scripts/dataproc-initialization-script-${INDEX}`
on the filesystem of each cluster node, where ${INDEX} is the script number,
starting with 0, and incrementing for each additional script.  The URL of the
script can be found by querying the metadata server for
`attributes/dataproc-initialization-action-script-${INDEX}`.  From within the
script itself, you can refer to `attributes/$0`.

Logs for each initialization action script are created under /var/log

