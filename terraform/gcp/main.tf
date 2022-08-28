terraform {
  backend "gcs" {
    prefix = "gitpod-k3s"
    # Set TF_STATE_BUCKET_NAME_GCS or set
    # bucket = "name"
  }
}
