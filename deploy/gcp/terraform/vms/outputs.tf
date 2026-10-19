output "project_id" {
  description = "GCP project of the lab VMs."
  value       = var.project_id
}
output "zone" {
  description = "Zone of the lab VMs."
  value       = var.zone
}
output "bucket_name" {
  description = "Shared artifact bucket."
  value       = var.bucket_name
}

output "vms" {
  description = "Lab VMs and their expected settings (./lab gcp check compares the live VM to these)."
  value = { for k, v in local.vms : k => {
    name             = v.name
    owner            = v.owner
    machine_type     = v.machine_type
    min_cpu_platform = v.min_cpu_platform
    nested           = true
    publisher        = v.publisher
  } }
}

# One line per VM for shell scripts: key name machine_type min_cpu_platform(with _ for spaces)
output "vm_lines" {
  description = "One line per VM for the front ends: key name machine_type min_cpu_platform (spaces as _)."
  value       = join("\n", [for k, v in local.vms : "${k} ${v.name} ${v.machine_type} ${replace(v.min_cpu_platform, " ", "_")}"])
}
