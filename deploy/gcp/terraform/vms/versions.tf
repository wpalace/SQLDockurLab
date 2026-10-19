terraform {
  # >= 1.5 rather than ~> 1.16 (docs/style/terraform.md): operators and the lab hosts run Terraform 1.5+;
  # the configuration uses no newer language features.
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
  # Optional remote state: copy backend.tf.example to backend.tf and run ./lab gcp init.
}
