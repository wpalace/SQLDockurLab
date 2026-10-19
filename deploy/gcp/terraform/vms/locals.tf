locals {
  region = join("-", slice(split("-", var.zone), 0, 2))
  # vms (managed by hand in terraform.tfvars) + spawned (clones from ./lab gcp spawn)
  all_vms = merge(
    { for k, v in var.vms : k => {
      name      = v.name, owner = v.owner, machine_type = v.machine_type, min_cpu_platform = v.min_cpu_platform,
      disk_type = v.disk_type, disk_size_gb = v.disk_size_gb, image = v.image, source_snapshot = v.source_snapshot,
      cpu_model = v.cpu_model, spot = v.spot, publisher = v.publisher, shielded_vm = v.shielded_vm, spawned = false
    } },
    { for k, v in var.spawned : k => {
      name      = k, owner = v.owner, machine_type = v.machine_type, min_cpu_platform = v.min_cpu_platform,
      disk_type = v.disk_type, disk_size_gb = v.disk_size_gb, image = null, source_snapshot = v.source_snapshot,
      cpu_model = v.cpu_model, spot = v.spot, publisher = v.publisher, shielded_vm = v.shielded_vm, spawned = true
    } },
  )
  vms = { for k, v in local.all_vms : k => {
    name             = coalesce(v.name, "${var.name_prefix}-${k}")
    owner            = v.owner
    machine_type     = coalesce(v.machine_type, var.default_machine_type)
    min_cpu_platform = coalesce(v.min_cpu_platform, var.default_min_cpu_platform)
    disk_type        = coalesce(v.disk_type, v.spawned ? var.default_spawned_disk_type : var.default_disk_type)
    disk_size_gb     = coalesce(v.disk_size_gb, var.default_disk_size_gb)
    image            = v.source_snapshot == null ? coalesce(v.image, var.default_image) : null
    source_snapshot  = v.source_snapshot
    cpu_model        = coalesce(v.cpu_model, var.default_cpu_model)
    spot             = coalesce(v.spot, var.default_spot)
    publisher        = v.publisher
    shielded_vm      = coalesce(v.shielded_vm, true)
    spawned          = v.spawned
  } }
}
