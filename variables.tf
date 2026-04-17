variable "cloud_name" {
  description = "Cloud name as defined in clouds.yaml"
  type        = string
  default     = "openstack"
}

variable "vm_name" {
  description = "Name of the VM to provision"
  type        = string
  default     = "jumpbox"
}

variable "image_name" {
  description = "Name of the RHEL9 image in OpenStack"
  type        = string
  default     = "rhel9"
}

variable "flavor_name" {
  description = "Flavor name for the VM"
  type        = string
  default     = "m1.medium"
}

variable "network_name" {
  description = "Network name to attach the VM to"
  type        = string
}

variable "security_groups" {
  description = "List of security groups to assign to the VM"
  type        = list(string)
  default     = ["default"]
}

variable "availability_zone" {
  description = "Availability zone for the VM"
  type        = string
  default     = "nova"
}

variable "floating_ip_pool" {
  description = "External network name for floating IP allocation. Leave empty to skip."
  type        = string
  default     = ""
}

variable "baremetal_user" {
  description = "Username to create via cloud-init"
  type        = string
  default     = "baremetal"
}

variable "ssh_public_key" {
  description = "SSH public key to inject into the baremetal user"
  type        = string
  sensitive   = true
}

variable "packages" {
  description = "Packages to install via cloud-init"
  type        = list(string)
  default     = ["mtr"]
}
