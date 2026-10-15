terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
  }
  # Optional remote state: copy backend.tf.example to backend.tf and run ./lab gcp init.
}

provider "google" {
  project = var.project_id
  region  = var.region
}
