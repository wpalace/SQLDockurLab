data "google_service_account" "vm" {
  account_id = "${var.name_prefix}-lab-vm"
}

data "google_service_account" "publisher" {
  account_id = "${var.name_prefix}-lab-publisher"
}

data "google_compute_subnetwork" "lab" {
  name   = var.subnet_name
  region = local.region
}

resource "google_compute_instance" "lab" {
  for_each         = local.vms
  name             = each.value.name
  zone             = var.zone
  machine_type     = each.value.machine_type
  min_cpu_platform = each.value.min_cpu_platform
  tags             = [var.network_tag]
  labels = merge({
    app   = "sql-ag-lab"
    owner = each.value.owner
    key   = each.key
  }, each.value.spawned ? { spawned = "true" } : {})

  # KVM inside the VM: the whole lab depends on this.
  advanced_machine_features {
    enable_nested_virtualization = true
  }

  # Shielded VM: Secure Boot, vTPM and integrity monitoring of the host (Debian) boot.
  # It does not affect nested KVM: the lab VMs inside run on QEMU's own firmware.
  # A VM entry with shielded_vm = false turns all three off (for example a custom image without UEFI).
  shielded_instance_config {
    enable_secure_boot          = each.value.shielded_vm && var.shielded_vm.enable_secure_boot
    enable_vtpm                 = each.value.shielded_vm && var.shielded_vm.enable_vtpm
    enable_integrity_monitoring = each.value.shielded_vm && var.shielded_vm.enable_integrity_monitoring
  }

  boot_disk {
    auto_delete = true
    initialize_params {
      image    = each.value.image
      snapshot = each.value.source_snapshot
      size     = each.value.disk_size_gb
      type     = each.value.disk_type
      labels   = { app = "sql-ag-lab", owner = each.value.owner }
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.lab.self_link
    dynamic "access_config" {
      for_each = var.public_ip ? [1] : []
      content {}
    }
  }

  service_account {
    email  = each.value.publisher ? data.google_service_account.publisher.email : data.google_service_account.vm.email
    scopes = ["cloud-platform"] # access is limited by IAM roles, not scopes
  }

  scheduling {
    provisioning_model          = each.value.spot ? "SPOT" : "STANDARD"
    preemptible                 = each.value.spot
    automatic_restart           = !each.value.spot
    on_host_maintenance         = each.value.spot ? "TERMINATE" : "MIGRATE"
    instance_termination_action = each.value.spot ? "STOP" : null
  }

  metadata = {
    enable-oslogin = "TRUE"
    lab-bucket     = var.bucket_name
    lab-cpu-model  = each.value.cpu_model
    lab-timezone   = var.timezone
    lab-owner      = each.value.owner
    lab-key-secret = "${var.name_prefix}-lab-ssh-key" # Secret Manager secret of the shared root
    startup-script = file("${path.module}/startup.sh")
  }

  allow_stopping_for_update = true
}
