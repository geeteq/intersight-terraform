# ---------------------------------------------------------------------------
# Intersight provider
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

# ---------------------------------------------------------------------------
# Organization
# ---------------------------------------------------------------------------

variable "organization" {
  description = "Intersight organization name"
  type        = string
  default     = "default"
}

# ---------------------------------------------------------------------------
# IP Pool
# ---------------------------------------------------------------------------

variable "ip_pool_name" {
  description = "Name of the IP pool"
  type        = string
  default     = "mgmt-ip-pool"
}

variable "ip_gateway" {
  description = "Default gateway for the IP pool"
  type        = string
}

variable "ip_netmask" {
  description = "Subnet mask for the IP pool"
  type        = string
  default     = "255.255.255.0"
}

variable "dns_primary" {
  description = "Primary DNS server"
  type        = string
  default     = "8.8.8.8"
}

variable "dns_secondary" {
  description = "Secondary DNS server"
  type        = string
  default     = "8.8.4.4"
}

variable "ip_ranges" {
  description = "List of IP ranges for the pool"
  type = list(object({
    from = string
    size = number
  }))
  default = [
    {
      from = "10.0.0.10"
      size = 100
    }
  ]
}

# ---------------------------------------------------------------------------
# MAC Pool
# ---------------------------------------------------------------------------

variable "mac_pool_name" {
  description = "Name of the MAC address pool"
  type        = string
  default     = "mac-pool"
}

variable "mac_ranges" {
  description = "List of MAC address ranges for the pool"
  type = list(object({
    from = string
    size = number
  }))
  default = [
    {
      from = "00:25:B5:00:00:00"
      size = 256
    }
  ]
}

# ---------------------------------------------------------------------------
# Server profiles
# ---------------------------------------------------------------------------

variable "target_platform" {
  description = "Target platform for server profiles (FIAttached or Standalone)"
  type        = string
  default     = "FIAttached"
}

variable "server_profile_template_name" {
  description = "Name of the base server profile template"
  type        = string
  default     = "base-server-template"
}

variable "server_profiles" {
  description = "List of server profiles to create from the base template"
  type = list(object({
    name        = string
    description = optional(string, "")
  }))
  default = []
}
