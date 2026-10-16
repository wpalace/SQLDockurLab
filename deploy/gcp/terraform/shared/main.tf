locals {
  apis            = ["compute.googleapis.com", "iap.googleapis.com", "storage.googleapis.com", "iam.googleapis.com", "oslogin.googleapis.com"]
  bucket_location = var.bucket_location != "" ? var.bucket_location : upper(var.region)
  network_id      = var.create_network ? google_compute_network.lab[0].id : data.google_compute_network.existing[0].id
  member_roles = var.grant_project_roles ? toset(flatten([
    for m in var.team_members : [
      for r in ["roles/iap.tunnelResourceAccessor", "roles/compute.osAdminLogin", "roles/compute.instanceAdmin.v1"] : "${m}|${r}"
    ]
  ])) : toset([])
}

resource "google_project_service" "api" {
  for_each           = var.enable_apis ? toset(local.apis) : toset([])
  service            = each.value
  disable_on_destroy = false
}

# --------------------------------------------------------------------------- network --
resource "google_compute_network" "lab" {
  count                   = var.create_network ? 1 : 0
  name                    = var.network_name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.api]
}

data "google_compute_network" "existing" {
  count = var.create_network ? 0 : 1
  name  = var.network_name
}

resource "google_compute_subnetwork" "lab" {
  count                    = var.create_network ? 1 : 0
  name                     = var.subnet_name
  region                   = var.region
  network                  = google_compute_network.lab[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true # bucket access without a public IP
}

resource "google_compute_firewall" "iap_ssh" {
  name          = "${var.name_prefix}-allow-iap-ssh"
  network       = local.network_id
  direction     = "INGRESS"
  source_ranges = var.iap_ssh_source_ranges
  target_tags   = [var.network_tag]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_router" "nat" {
  count   = var.enable_nat ? 1 : 0
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = local.network_id
}

resource "google_compute_router_nat" "nat" {
  count                              = var.enable_nat ? 1 : 0
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.nat[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ----------------------------------------------------------------- service accounts --
# lab-vm: attached to every lab VM. Read-only on the bucket, plus logging/monitoring.
resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-lab-vm"
  display_name = "sql-ag-lab VM (bucket read)"
  depends_on   = [google_project_service.api]
}

# lab-publisher: attached only to VMs marked publisher = true. Can write artifacts.
resource "google_service_account" "publisher" {
  account_id   = "${var.name_prefix}-lab-publisher"
  display_name = "sql-ag-lab publisher VM (bucket write)"
  depends_on   = [google_project_service.api]
}

resource "google_project_iam_member" "sa_logs" {
  for_each = {
    vm_log  = [google_service_account.vm.email, "roles/logging.logWriter"]
    vm_mon  = [google_service_account.vm.email, "roles/monitoring.metricWriter"]
    pub_log = [google_service_account.publisher.email, "roles/logging.logWriter"]
    pub_mon = [google_service_account.publisher.email, "roles/monitoring.metricWriter"]
  }
  project = var.project_id
  role    = each.value[1]
  member  = "serviceAccount:${each.value[0]}"
}

# Team members attach the service accounts to the VMs they create.
resource "google_service_account_iam_member" "act_as" {
  for_each           = toset(flatten([for m in var.team_members : ["vm|${m}", "publisher|${m}"]]))
  service_account_id = split("|", each.value)[0] == "vm" ? google_service_account.vm.name : google_service_account.publisher.name
  role               = "roles/iam.serviceAccountUser"
  member             = split("|", each.value)[1]
}

resource "google_project_iam_member" "team" {
  for_each = local.member_roles
  project  = var.project_id
  member   = split("|", each.value)[0]
  role     = split("|", each.value)[1]
}

# ------------------------------------------------------------------ artifact bucket --
resource "google_storage_bucket" "artifacts" {
  name                        = var.bucket_name
  location                    = local.bucket_location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.bucket_force_destroy
  versioning {
    enabled = true
  }
  dynamic "lifecycle_rule" {
    for_each = var.artifact_retention_days > 0 ? [1] : []
    content {
      condition {
        days_since_noncurrent_time = var.artifact_retention_days
      }
      action {
        type = "Delete"
      }
    }
  }
  depends_on = [google_project_service.api]
}

resource "google_storage_bucket_iam_member" "readers" {
  for_each = toset(concat(["serviceAccount:${google_service_account.vm.email}"], var.team_members))
  bucket   = google_storage_bucket.artifacts.name
  role     = "roles/storage.objectViewer"
  member   = each.value
}

resource "google_storage_bucket_iam_member" "writers" {
  for_each = toset(concat(["serviceAccount:${google_service_account.publisher.email}"], var.publishers))
  bucket   = google_storage_bucket.artifacts.name
  role     = "roles/storage.objectAdmin"
  member   = each.value
}

# storage.buckets.get lets gcloud use parallel composite uploads (much faster for the
# multi-GB base image and checkpoint archives).
resource "google_storage_bucket_iam_member" "writers_bucket_read" {
  for_each = toset(concat(["serviceAccount:${google_service_account.publisher.email}"], var.publishers))
  bucket   = google_storage_bucket.artifacts.name
  role     = "roles/storage.legacyBucketReader"
  member   = each.value
}
