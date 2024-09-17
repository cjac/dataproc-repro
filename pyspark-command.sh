#!/bin/bash
#
# Copyright 2024 Google LLC
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
source env.sh
set -x
gsutil cp test.py gs://${BUCKET}/
gcloud dataproc jobs submit pyspark \
  --properties="spark:spark.executor.resource.gpu.amount=1" \
  --properties="spark:spark.task.resource.gpu.amount=1" \
  --properties="spark.executorEnv.YARN_CONTAINER_RUNTIME_DOCKER_IMAGE=${YARN_DOCKER_IMAGE}" \
  --cluster=${CLUSTER_NAME} \
  --region ${REGION} gs://${BUCKET}/test.py
set +x
