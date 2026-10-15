variable "project_id" {
  description = "GCP project that hosts the lab."
  type        = string
}

variable "region" {
  description = "Region for the subnet, Cloud NAT and the bucket (when bucket_location is empty)."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Prefix for all shared resource names."
  type        = string
  default     = "sqlag"
}

variable "enable_apis" {
  description = "Enable the Compute, IAP, Storage and IAM APIs in the project."
  type        = bool
  default     = true
}

variable "create_network" {
  description = "Create a dedicated VPC and subnet. Set false to use an existing network (network_name/subnet_name)."
  type        = bool
  default     = true
}

variable "network_name" {
  description = "VPC name (created when create_network = true)."
  type        = string
  default     = "sqlag-net"
}

variable "subnet_name" {
  description = "Subnet name (created when create_network = true)."
  type        = string
  default     = "sqlag-subnet"
}

variable "subnet_cidr" {
  description = "Subnet range for the lab VMs. Must not overlap the in-VM lab networks 10.50.0.0/24 and 10.51.0.0/24."
  type        = string
  default     = "10.200.0.0/24"
}

variable "enable_nat" {
  description = "Cloud NAT for egress (Docker install, Windows/SQL downloads) when VMs have no public IP."
  type        = bool
  default     = true
}

variable "iap_ssh_source_ranges" {
  description = "Source ranges allowed to reach SSH. 35.235.240.0/20 is Google's IAP TCP forwarding range."
  type        = list(string)
  default     = ["35.235.240.0/20"]
}

variable "network_tag" {
  description = "Network tag that the lab VMs carry; firewall rules target it."
  type        = string
  default     = "sqlag-lab"
}

variable "bucket_name" {
  description = "Globally unique name of the shared artifact bucket."
  type        = string
}

variable "bucket_location" {
  description = "Bucket location. Empty = same as region (lowest latency and no inter-region egress)."
  type        = string
  default     = ""
}

variable "bucket_force_destroy" {
  description = "Allow terraform destroy to delete a non-empty bucket."
  type        = bool
  default     = false
}

variable "artifact_retention_days" {
  description = "Delete noncurrent object versions after this many days (0 = keep forever)."
  type        = number
  default     = 30
}

variable "team_members" {
  description = "Principals (user:alice@example.com, group:...) that may create lab VMs, SSH via IAP and read the bucket."
  type        = list(string)
  default     = []
}

variable "publishers" {
  description = "Principals that may write artifacts to the bucket from their own credentials."
  type        = list(string)
  default     = []
}

variable "grant_project_roles" {
  description = "Grant team_members the project roles they need (IAP tunnel, OS Login admin, instance admin). Needs project IAM admin."
  type        = bool
  default     = true
}
