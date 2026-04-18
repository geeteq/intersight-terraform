# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

variable "intersight_api_key_id" {
  description = "Intersight API key ID"
  type        = string
  sensitive   = true
}

variable "intersight_secret_key_file" {
  description = "Path to the Intersight API secret key file"
  type        = string
  default     = "secret_key.txt"
}

variable "intersight_endpoint" {
  description = "Intersight API endpoint"
  type        = string
  default     = "https://intersight.com"
}

variable "organization" {
  description = "Intersight organization name"
  type        = string
  default     = "default"
}

variable "target_platform" {
  description = "Target platform: FIAttached or Standalone"
  type        = string
  default     = "FIAttached"
}

# ---------------------------------------------------------------------------
# IP Pool
# ---------------------------------------------------------------------------

variable "create_ip_pool" {
  type    = bool
  default = true
}

variable "ip_pool_name" {
  type    = string
  default = "mgmt-ip-pool"
}

variable "ip_gateway" {
  type = string
}

variable "ip_netmask" {
  type    = string
  default = "255.255.255.0"
}

variable "dns_primary" {
  type    = string
  default = "8.8.8.8"
}

variable "dns_secondary" {
  type    = string
  default = "8.8.4.4"
}

variable "ip_ranges" {
  type = list(object({
    from = string
    size = number
  }))
  default = [{ from = "10.0.0.10", size = 100 }]
}

# ---------------------------------------------------------------------------
# MAC Pool
# ---------------------------------------------------------------------------

variable "create_mac_pool" {
  type    = bool
  default = true
}

variable "mac_pool_name" {
  type    = string
  default = "mac-pool"
}

variable "mac_ranges" {
  type = list(object({
    from = string
    size = number
  }))
  default = [{ from = "00:25:B5:00:00:00", size = 256 }]
}

# ---------------------------------------------------------------------------
# UUID Pool
# ---------------------------------------------------------------------------

variable "create_uuid_pool" {
  type    = bool
  default = true
}

variable "uuid_pool_name" {
  type    = string
  default = "uuid-pool"
}

variable "uuid_prefix" {
  description = "UUID prefix in format XXXXXXXX-XXXX-XXXX"
  type        = string
  default     = "000025B5-0000-0000"
}

variable "uuid_ranges" {
  type = list(object({
    from = string
    size = number
  }))
  default = [{ from = "0000-000000000000", size = 256 }]
}

# ---------------------------------------------------------------------------
# NTP Policy
# ---------------------------------------------------------------------------

variable "create_ntp_policy" {
  type    = bool
  default = true
}

variable "ntp_policy_name" {
  type    = string
  default = "ntp-policy"
}

variable "ntp_servers" {
  type    = list(string)
  default = ["pool.ntp.org"]
}

variable "timezone" {
  type    = string
  default = "America/New_York"
}

# ---------------------------------------------------------------------------
# Network Connectivity (DNS) Policy
# ---------------------------------------------------------------------------

variable "create_network_policy" {
  type    = bool
  default = true
}

variable "network_policy_name" {
  type    = string
  default = "network-connectivity-policy"
}

# ---------------------------------------------------------------------------
# Syslog Policy
# ---------------------------------------------------------------------------

variable "create_syslog_policy" {
  type    = bool
  default = true
}

variable "syslog_policy_name" {
  type    = string
  default = "syslog-policy"
}

variable "syslog_host" {
  type    = string
  default = ""
}

variable "syslog_port" {
  type    = number
  default = 514
}

variable "syslog_local_severity" {
  type    = string
  default = "warning"
}

variable "syslog_remote_severity" {
  type    = string
  default = "information"
}

# ---------------------------------------------------------------------------
# BIOS Policy
# ---------------------------------------------------------------------------

variable "create_bios_policy" {
  type    = bool
  default = true
}

variable "bios_policy_name" {
  type    = string
  default = "bios-policy"
}

# ---------------------------------------------------------------------------
# Boot Order Policy
# ---------------------------------------------------------------------------

variable "create_boot_policy" {
  type    = bool
  default = true
}

variable "boot_policy_name" {
  type    = string
  default = "boot-local-disk"
}

# ---------------------------------------------------------------------------
# IMC Access Policy
# ---------------------------------------------------------------------------

variable "create_imc_policy" {
  type    = bool
  default = true
}

variable "imc_policy_name" {
  type    = string
  default = "imc-access-policy"
}

variable "imc_vlan" {
  description = "In-band management VLAN ID"
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Local User Policy
# ---------------------------------------------------------------------------

variable "create_local_user_policy" {
  type    = bool
  default = true
}

variable "local_user_policy_name" {
  type    = string
  default = "local-user-policy"
}

# ---------------------------------------------------------------------------
# LAN Connectivity Policy
# ---------------------------------------------------------------------------

variable "create_lan_policy" {
  type    = bool
  default = true
}

variable "lan_policy_name" {
  type    = string
  default = "lan-connectivity-policy"
}

# ---------------------------------------------------------------------------
# Server Profile Template
# ---------------------------------------------------------------------------

variable "create_server_template" {
  type    = bool
  default = true
}

variable "server_profile_template_name" {
  type    = string
  default = "base-server-template"
}

# ---------------------------------------------------------------------------
# Server Profiles
# ---------------------------------------------------------------------------

variable "server_profiles" {
  type = list(object({
    name        = string
    description = optional(string, "")
  }))
  default = []
}
