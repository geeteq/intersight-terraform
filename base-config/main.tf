terraform {
  required_version = ">= 1.3"
  required_providers {
    intersight = {
      source  = "CiscoDevNet/intersight"
      version = "~> 1.0"
    }
  }
}

provider "intersight" {
  apikey    = var.intersight_api_key_id
  secretkey = var.intersight_secret_key_file
  endpoint  = var.intersight_endpoint
}

# ---------------------------------------------------------------------------
# Organization
# ---------------------------------------------------------------------------

data "intersight_organization_organization" "default" {
  name = var.organization
}

# ---------------------------------------------------------------------------
# IP Pool
# ---------------------------------------------------------------------------

resource "intersight_ippool_pool" "mgmt" {
  name        = var.ip_pool_name
  description = "Management IP pool"

  ip_v4_config {
    gateway     = var.ip_gateway
    netmask     = var.ip_netmask
    primary_dns = var.dns_primary
    secondary_dns = var.dns_secondary
  }

  dynamic "ip_v4_blocks" {
    for_each = var.ip_ranges
    content {
      from = ip_v4_blocks.value.from
      size = ip_v4_blocks.value.size
    }
  }

  organization {
    object_type = "organization.Organization"
    moid        = data.intersight_organization_organization.default.moid
  }
}

# ---------------------------------------------------------------------------
# MAC Pool
# ---------------------------------------------------------------------------

resource "intersight_macpool_pool" "main" {
  name        = var.mac_pool_name
  description = "MAC address pool for vNICs"

  dynamic "mac_blocks" {
    for_each = var.mac_ranges
    content {
      from = mac_blocks.value.from
      size = mac_blocks.value.size
    }
  }

  organization {
    object_type = "organization.Organization"
    moid        = data.intersight_organization_organization.default.moid
  }
}

# ---------------------------------------------------------------------------
# Server Profile Template
# ---------------------------------------------------------------------------

resource "intersight_server_profile_template" "base" {
  name        = var.server_profile_template_name
  description = "Base server profile template"
  target_platform = var.target_platform

  organization {
    object_type = "organization.Organization"
    moid        = data.intersight_organization_organization.default.moid
  }
}

# ---------------------------------------------------------------------------
# Server Profiles (derived from template)
# ---------------------------------------------------------------------------

resource "intersight_server_profile" "servers" {
  for_each = { for s in var.server_profiles : s.name => s }

  name        = each.value.name
  description = lookup(each.value, "description", "")
  target_platform = var.target_platform

  src_template {
    object_type = "server.ProfileTemplate"
    moid        = intersight_server_profile_template.base.moid
  }

  organization {
    object_type = "organization.Organization"
    moid        = data.intersight_organization_organization.default.moid
  }
}
