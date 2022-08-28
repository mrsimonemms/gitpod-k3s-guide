#!/bin/bash

set -e

terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET_NAME_GCS}" || true
