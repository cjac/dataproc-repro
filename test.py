#!/usr/bin/env python3
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
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("torch - tensorflow").getOrCreate()

import torch
print("get CUDA details : == : ")
use_cuda = torch.cuda.is_available()
if use_cuda:
    print('__CUDNN VERSION:', torch.backends.cudnn.version())
    print('__Number CUDA Devices:', torch.cuda.device_count())
    print('__CUDA Device Name:',torch.cuda.get_device_name(0))
    print('__CUDA Device Total Memory [GB]:',torch.cuda.get_device_properties(0).total_memory/1e9)

import tensorflow as tf
print("Get GPU Details : ")
print(tf.test.is_gpu_available())

if tf.test.gpu_device_name():
    print('Default GPU Device:{}'.format(tf.test.gpu_device_name()))
    print("Please install GPU version of TF")

gpu_available = tf.test.is_gpu_available()
print("gpu_available : " + str(gpu_available))

is_cuda_gpu_available = tf.test.is_gpu_available(cuda_only=True)
print("is_cuda_gpu_available : " + str(is_cuda_gpu_available))

is_cuda_gpu_min_3 = tf.test.is_gpu_available(True, (3,0))
print("is_cuda_gpu_min_3 : " + str(is_cuda_gpu_min_3))

from tensorflow.python.client import device_lib

def get_available_gpus():
    local_device_protos = device_lib.list_local_devices()
    return [x.name for x in local_device_protos if x.device_type == 'GPU']


print("Run GPU Funtions Below : ")
print(get_available_gpus())
