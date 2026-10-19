# ------------------------------------------------------------- lab SSH key (Secret Manager) --
# The private key of the lab (secrets/id_ed25519 on a lab host) lets a host SSH into DC1 and
# SQL1-4. Its public key is baked into the base image, so all hosts that use the same base
# image, checkpoints or golden snapshot need the same key.
# Terraform makes only the secret and its IAM. The key itself (the secret VERSION) is NOT
# managed here, so it never enters the Terraform state:
#   add:   ./lab gcp key push VM      (from a lab host that has the key; publishers only)
#   read:  gcloud secrets versions access latest --secret sqlag-lab-ssh-key
resource "google_secret_manager_secret" "lab_ssh_key" {
  secret_id = "${var.name_prefix}-lab-ssh-key"
  labels    = { app = "sql-ag-lab", kind = "ssh-key" }
  replication {
    auto {}
  }
  depends_on = [google_project_service.api]
}

locals {
  # Read the key: every lab VM (fetch at deploy/spawn), team members (they operate lab hosts),
  # and the principals in lab_key_readers. lab_users do not need it: their lab VM reads it
  # with its service account.
  key_readers = toset(concat(
    ["serviceAccount:${google_service_account.vm.email}", "serviceAccount:${google_service_account.publisher.email}"],
    var.team_members, var.lab_key_readers,
  ))
  # Add key versions: publisher VMs and publishers (the same principals that write the bucket).
  key_writers = toset(concat(["serviceAccount:${google_service_account.publisher.email}"], var.publishers))
}

resource "google_secret_manager_secret_iam_member" "key_readers" {
  for_each  = local.key_readers
  secret_id = google_secret_manager_secret.lab_ssh_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

resource "google_secret_manager_secret_iam_member" "key_writers" {
  for_each  = local.key_writers
  secret_id = google_secret_manager_secret.lab_ssh_key.id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = each.value
}

# ---------------------------------------------------------------------- lab users --
# lab_users get a lab VM that somebody else made (for example a clone from ./lab gcp spawn)
# and use it: SSH and tunnels through IAP, ./lab on the VM. They cannot create, start, stop or
# delete VMs, and they get no bucket or secret access of their own: the VM reads the
# artifacts and the key with its service account.
resource "google_project_iam_member" "lab_users" {
  for_each = local.user_roles
  project  = var.project_id
  member   = split("|", each.value)[0]
  role     = split("|", each.value)[1]
}

# OS Login requires serviceAccountUser on the service account of the VM (lab VMs that are
# not publishers use the lab-vm account).
resource "google_service_account_iam_member" "lab_users_act_as" {
  for_each           = toset(var.lab_users)
  service_account_id = google_service_account.vm.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}
