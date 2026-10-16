locals {
  region = join("-", slice(split("-", var.zone), 0, 2))
  vms = { for k, v in var.vms : k => {
    name             = coalesce(v.name, "${var.name_prefix}-${k}")
    owner            = v.owner
    machine_type     = coalesce(v.machine_type, var.default_machine_type)
    min_cpu_platform = coalesce(v.min_cpu_platform, var.default_min_cpu_platform)
    disk_type        = coalesce(v.disk_type, var.default_disk_type)
    disk_size_gb     = coalesce(v.disk_size_gb, var.default_disk_size_gb)
    image            = v.source_snapshot == null ? coalesce(v.image, var.default_image) : null
    source_snapshot  = v.source_snapshot
    cpu_model        = coalesce(v.cpu_model, var.default_cpu_model)
    spot             = coalesce(v.spot, var.default_spot)
    publisher        = v.publisher
  } }
}

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
  labels = {
    app   = "sql-ag-lab"
    owner = each.value.owner
    key   = each.key
  }

  # KVM inside the VM: the whole lab depends on this.
  advanced_machine_features {
    enable_nested_virtualization = true
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
    startup-script = file("${path.module}/startup.sh")
  }

  allow_stopping_for_update = true
}
