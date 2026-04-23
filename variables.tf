# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

variable "cloud_name" {
  description = "Cloud name as defined in clouds.yaml"
  type        = string
  default     = "openstack"
}

# ---------------------------------------------------------------------------
# Appliance identity
# ---------------------------------------------------------------------------

variable "hostname" {
  description = "Hostname for the Intersight Virtual Appliance"
  type        = string
  default     = "intersight-appliance"
}

variable "admin_password" {
  description = "Initial admin password for the Intersight appliance web UI"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "management_network" {
  description = "OpenStack network name for the appliance management interface"
  type        = string
}

variable "floating_ip_pool" {
  description = "External network name for floating IP. Leave empty to skip."
  type        = string
  default     = ""
}

variable "dns_servers" {
  description = "DNS servers for the appliance"
  type        = list(string)
  default     = ["8.8.8.8", "8.8.4.4"]
}

variable "ntp_servers" {
  description = "NTP servers for the appliance"
  type        = list(string)
  default     = ["pool.ntp.org"]
}

# ---------------------------------------------------------------------------
# Proxy (optional)
# ---------------------------------------------------------------------------

variable "proxy_host" {
  description = "HTTP proxy host for Intersight to reach Cisco cloud. Leave empty to disable."
  type        = string
  default     = ""
}

variable "proxy_port" {
  description = "HTTP proxy port"
  type        = number
  default     = 3128
}

variable "proxy_username" {
  description = "Proxy username (if required)"
  type        = string
  default     = ""
}

variable "proxy_password" {
  description = "Proxy password (if required)"
  type        = string
  sensitive   = true
  default     = ""
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "image_name" {
  description = "Intersight Virtual Appliance image name in OpenStack"
  type        = string
  default     = "intersight-appliance"
}

variable "flavor_name" {
  description = "Flavor for the appliance — minimum 8 vCPU / 32GB RAM recommended"
  type        = string
  default     = "8cpu-32G-0G"
}

variable "disk_count" {
  description = "Number of disk images in the Intersight VA package"
  type        = number
  default     = 8
}

variable "disk_sizes" {
  description = "Volume size in GB for each disk, in boot order. Must have disk_count entries."
  type        = list(number)
  default     = [500, 500, 500, 500, 500, 500, 500, 500]
}

variable "availability_zone" {
  description = "OpenStack availability zone"
  type        = string
  default     = "nova"
}

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------

variable "create_security_group" {
  description = "Set to true to create the security group. Set to false to use an existing one."
  type        = bool
  default     = true
}

variable "security_group_name" {
  description = "Security group name to create or look up"
  type        = string
  default     = "intersight-sg"
}
