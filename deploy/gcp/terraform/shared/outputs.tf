output "project_id" {
  description = "GCP project of the lab."
  value       = var.project_id
}
output "region" {
  description = "Region of the shared subnet and bucket."
  value       = var.region
}
output "network_name" {
  description = "VPC network of the lab VMs."
  value       = var.network_name
}
output "subnet_name" {
  description = "Subnet of the lab VMs (vms root: subnet_name)."
  value       = var.subnet_name
}
output "network_tag" {
  description = "Network tag that the IAP SSH firewall rule targets (vms root: network_tag)."
  value       = var.network_tag
}
output "bucket_name" {
  description = "Shared artifact bucket (vms root: bucket_name)."
  value       = google_storage_bucket.artifacts.name
}
output "vm_service_account" {
  description = "Service account of the lab VMs (reads artifacts and the lab SSH key)."
  value       = google_service_account.vm.email
}
output "publisher_service_account" {
  description = "Service account of publisher VMs (writes artifacts and key versions)."
  value       = google_service_account.publisher.email
}
output "lab_ssh_key_secret" {
  description = "Secret Manager secret that holds the lab SSH key."
  value       = google_secret_manager_secret.lab_ssh_key.secret_id
}
