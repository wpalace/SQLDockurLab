locals {
  apis            = ["compute.googleapis.com", "iap.googleapis.com", "storage.googleapis.com", "iam.googleapis.com", "oslogin.googleapis.com", "secretmanager.googleapis.com"]
  bucket_location = var.bucket_location != "" ? var.bucket_location : upper(var.region)
  network_id      = var.create_network ? google_compute_network.lab[0].id : data.google_compute_network.existing[0].id
  member_roles = var.grant_project_roles ? toset(flatten([
    for m in var.team_members : [
      for r in ["roles/iap.tunnelResourceAccessor", "roles/compute.osAdminLogin", "roles/compute.instanceAdmin.v1"] : "${m}|${r}"
    ]
  ])) : toset([])
  # lab_users: use an existing lab VM (SSH, tunnel, ./lab on it); not create/delete VMs.
  user_roles = var.grant_project_roles ? toset(flatten([
    for m in var.lab_users : [
      for r in ["roles/iap.tunnelResourceAccessor", "roles/compute.osAdminLogin", "roles/compute.viewer"] : "${m}|${r}"
    ]
  ])) : toset([])
}
