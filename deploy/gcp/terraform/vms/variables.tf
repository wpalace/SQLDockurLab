variable "project_id" {
  description = "GCP project (same as the shared root)."
  type        = string
}

variable "zone" {
  description = "Zone for the lab VMs. Must be in the region of the shared subnet and offer the machine series."
  type        = string
  default     = "us-central1-a"
}

variable "name_prefix" {
  description = "Same name_prefix as the shared root (service accounts are looked up by it)."
  type        = string
  default     = "sqlag"
}

variable "network_name" {
  type    = string
  default = "sqlag-net"
}

variable "subnet_name" {
  type    = string
  default = "sqlag-subnet"
}

variable "network_tag" {
  type    = string
  default = "sqlag-lab"
}

variable "bucket_name" {
  description = "Shared artifact bucket (output bucket_name of the shared root)."
  type        = string
}

variable "public_ip" {
  description = "Give VMs an external IP. Default false: reach them through IAP only."
  type        = bool
  default     = false
}

# Defaults for every VM; each entry in var.vms can override them.
variable "default_machine_type" {
  description = "Must support nested virtualization: Intel series (N2, N4, C3, C4, N1, C2...) or AMD N4D. Not E2, Arm, other AMD, or memory-optimized."
  type        = string
  default     = "n2-standard-16"
  validation {
    condition     = !can(regex("^(e2|n2d|c2d|c3d|c4d|t2d|t2a|c4a|m1|m2|m3|m4|x4)-", var.default_machine_type))
    error_message = "This machine series does not support nested virtualization."
  }
}

variable "default_min_cpu_platform" {
  description = "Pin the CPU generation. Memory checkpoints restore only on the same CPU model, so all team VMs that share checkpoints must use the same value."
  type        = string
  default     = "Intel Ice Lake"
}

variable "default_disk_type" {
  description = "pd-ssd for N2/C2/N1; hyperdisk-balanced for N4/C3/C4 (they do not support pd-*)."
  type        = string
  default     = "pd-ssd"
}

variable "default_disk_size_gb" {
  description = "Boot disk size. The lab needs about 120 GB; more gives better pd-ssd throughput (it scales with size)."
  type        = number
  default     = 300
}

variable "default_image" {
  description = "Boot image. Any Linux image the startup script supports (it uses the official Docker installer), or a custom image family made by ./lab gcp image."
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "default_cpu_model" {
  description = "Written to lab.local.env as LAB_CPU_MODEL on the VM. 'host' is fastest; a named QEMU model (for example Icelake-Server) makes checkpoints portable across hosts."
  type        = string
  default     = "host"
}

variable "default_spot" {
  description = "Spot VMs (about 60-90% cheaper). On preemption the VM STOPS and keeps its disk; rerun ./lab gcp start + deploy to resume."
  type        = bool
  default     = true
}

variable "vms" {
  description = "Lab VMs keyed by '<owner>-<n>' (for example bill-1). One or two per team member."
  type = map(object({
    owner            = string
    machine_type     = optional(string)
    min_cpu_platform = optional(string)
    disk_type        = optional(string)
    disk_size_gb     = optional(number)
    image            = optional(string)
    cpu_model        = optional(string)
    spot             = optional(bool)
    publisher        = optional(bool, false)
  }))
  default = {}
  validation {
    condition     = alltrue([for k, v in var.vms : can(regex("^[a-z][a-z0-9]*-[0-9]+$", k))])
    error_message = "VM keys must look like '<owner>-<n>', for example bill-1."
  }
  validation {
    condition     = alltrue([for v in values(var.vms) : !can(regex("^(e2|n2d|c2d|c3d|c4d|t2d|t2a|c4a|m1|m2|m3|m4|x4)-", coalesce(v.machine_type, "n2-")))])
    error_message = "A VM uses a machine series without nested virtualization support."
  }
}
