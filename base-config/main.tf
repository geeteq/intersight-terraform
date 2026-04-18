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

locals {
  org = {
    object_type = "organization.Organization"
    moid        = data.intersight_organization_organization.default.moid
  }
}

# ---------------------------------------------------------------------------
# IP Pool
# ---------------------------------------------------------------------------

data "intersight_ippool_pool" "existing" {
  count = var.create_ip_pool ? 0 : 1
  name  = var.ip_pool_name
}

resource "intersight_ippool_pool" "mgmt" {
  count       = var.create_ip_pool ? 1 : 0
  name        = var.ip_pool_name
  description = "Management IP pool"

  ip_v4_config {
    gateway       = var.ip_gateway
    netmask       = var.ip_netmask
    primary_dns   = var.dns_primary
    secondary_dns = var.dns_secondary
  }

  dynamic "ip_v4_blocks" {
    for_each = var.ip_ranges
    content {
      from = ip_v4_blocks.value.from
      size = ip_v4_blocks.value.size
    }
  }

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# MAC Pool
# ---------------------------------------------------------------------------

data "intersight_macpool_pool" "existing" {
  count = var.create_mac_pool ? 0 : 1
  name  = var.mac_pool_name
}

resource "intersight_macpool_pool" "main" {
  count       = var.create_mac_pool ? 1 : 0
  name        = var.mac_pool_name
  description = "MAC address pool for vNICs"

  dynamic "mac_blocks" {
    for_each = var.mac_ranges
    content {
      from = mac_blocks.value.from
      size = mac_blocks.value.size
    }
  }

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# UUID Pool
# ---------------------------------------------------------------------------

data "intersight_uuidpool_pool" "existing" {
  count = var.create_uuid_pool ? 0 : 1
  name  = var.uuid_pool_name
}

resource "intersight_uuidpool_pool" "main" {
  count       = var.create_uuid_pool ? 1 : 0
  name        = var.uuid_pool_name
  description = "UUID pool for server profiles"
  prefix      = var.uuid_prefix

  dynamic "uuid_suffix_blocks" {
    for_each = var.uuid_ranges
    content {
      from = uuid_suffix_blocks.value.from
      size = uuid_suffix_blocks.value.size
    }
  }

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# NTP Policy
# ---------------------------------------------------------------------------

data "intersight_ntp_policy" "existing" {
  count = var.create_ntp_policy ? 0 : 1
  name  = var.ntp_policy_name
}

resource "intersight_ntp_policy" "main" {
  count       = var.create_ntp_policy ? 1 : 0
  name        = var.ntp_policy_name
  description = "NTP policy"
  enabled     = true
  ntp_servers = var.ntp_servers
  timezone    = var.timezone

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# Network Connectivity (DNS) Policy
# ---------------------------------------------------------------------------

data "intersight_networkconfig_policy" "existing" {
  count = var.create_network_policy ? 0 : 1
  name  = var.network_policy_name
}

resource "intersight_networkconfig_policy" "main" {
  count                   = var.create_network_policy ? 1 : 0
  name                    = var.network_policy_name
  description             = "DNS and network connectivity policy"
  preferred_ipv4dns_server = var.dns_primary
  alternate_ipv4dns_server = var.dns_secondary
  enable_ipv6             = false

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# Syslog Policy
# ---------------------------------------------------------------------------

data "intersight_syslog_policy" "existing" {
  count = var.create_syslog_policy ? 0 : 1
  name  = var.syslog_policy_name
}

resource "intersight_syslog_policy" "main" {
  count       = var.create_syslog_policy ? 1 : 0
  name        = var.syslog_policy_name
  description = "Syslog forwarding policy"

  local_clients {
    min_severity = var.syslog_local_severity
  }

  dynamic "remote_clients" {
    for_each = var.syslog_host != "" ? [1] : []
    content {
      enabled      = true
      hostname     = var.syslog_host
      port         = var.syslog_port
      protocol     = "udp"
      min_severity = var.syslog_remote_severity
    }
  }

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# BIOS Policy
# ---------------------------------------------------------------------------

data "intersight_bios_policy" "existing" {
  count = var.create_bios_policy ? 0 : 1
  name  = var.bios_policy_name
}

resource "intersight_bios_policy" "main" {
  count                        = var.create_bios_policy ? 1 : 0
  name                         = var.bios_policy_name
  description                  = "Base BIOS policy"
  cpu_performance              = "enterprise"
  cpu_power_management         = "performance"
  cpu_energy_performance       = "performance"
  intel_hyper_threading_tech   = "enabled"
  intel_virtualization_technology = "enabled"
  numa_optimized               = "enabled"
  lv_ddr_mode                  = "auto"

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# Boot Order Policy (local disk)
# ---------------------------------------------------------------------------

data "intersight_boot_precision_policy" "existing" {
  count = var.create_boot_policy ? 0 : 1
  name  = var.boot_policy_name
}

resource "intersight_boot_precision_policy" "main" {
  count                    = var.create_boot_policy ? 1 : 0
  name                     = var.boot_policy_name
  description              = "Boot from local disk"
  configured_boot_mode     = "Uefi"
  enforce_uefi_secure_boot = false

  boot_devices {
    object_type = "boot.LocalDisk"
    name        = "local-disk"
    enabled     = true
  }

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# IMC Access Policy
# ---------------------------------------------------------------------------

data "intersight_access_policy" "existing" {
  count = var.create_imc_policy ? 0 : 1
  name  = var.imc_policy_name
}

resource "intersight_access_policy" "main" {
  count       = var.create_imc_policy ? 1 : 0
  name        = var.imc_policy_name
  description = "IMC out-of-band access policy"

  inband_ip_pool {
    object_type = "ippool.Pool"
    moid        = var.create_ip_pool ? intersight_ippool_pool.mgmt[0].moid : data.intersight_ippool_pool.existing[0].moid
  }

  inband_vlan = var.imc_vlan

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# Local User Policy
# ---------------------------------------------------------------------------

data "intersight_iam_end_point_user_policy" "existing" {
  count = var.create_local_user_policy ? 0 : 1
  name  = var.local_user_policy_name
}

resource "intersight_iam_end_point_user_policy" "main" {
  count       = var.create_local_user_policy ? 1 : 0
  name        = var.local_user_policy_name
  description = "Local user policy"

  password_properties {
    enforce_strong_password  = true
    enable_password_expiry   = false
    password_expiry_duration = 90
    password_history         = 5
    notification_period      = 15
    grace_period             = 0
  }

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# LAN Connectivity Policy
# ---------------------------------------------------------------------------

data "intersight_vnic_lan_connectivity_policy" "existing" {
  count = var.create_lan_policy ? 0 : 1
  name  = var.lan_policy_name
}

resource "intersight_vnic_lan_connectivity_policy" "main" {
  count           = var.create_lan_policy ? 1 : 0
  name            = var.lan_policy_name
  description     = "LAN connectivity policy"
  target_platform = var.target_platform
  placement_mode  = "auto"
  iqn_allocation_type = "None"

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

resource "intersight_vnic_eth_if" "eth0" {
  count = var.create_lan_policy ? 1 : 0
  name  = "eth0"
  order = 0

  placement {
    id      = "MLOM"
    pci_link = 0
    uplink   = 0
  }

  mac_address_type = "POOL"
  mac_pool {
    object_type = "macpool.Pool"
    moid        = var.create_mac_pool ? intersight_macpool_pool.main[0].moid : data.intersight_macpool_pool.existing[0].moid
  }

  lan_connectivity_policy {
    object_type = "vnic.LanConnectivityPolicy"
    moid        = intersight_vnic_lan_connectivity_policy.main[0].moid
  }

  cdn {
    value     = "eth0"
    nr_source = "user"
  }

  usnic_settings {
    cos        = 5
    nr_count   = 0
    usnic_adapter_policy = ""
  }

  vmq_settings {
    enabled              = false
    multi_queue_support  = false
    num_interrupts       = 16
    num_vmqs             = 4
    num_sub_vnics        = 64
    vmmq_adapter_policy  = ""
  }
}

# ---------------------------------------------------------------------------
# Locals — resolve moids from created or existing resources
# ---------------------------------------------------------------------------

locals {
  ip_pool_moid         = var.create_ip_pool         ? intersight_ippool_pool.mgmt[0].moid                       : data.intersight_ippool_pool.existing[0].moid
  mac_pool_moid        = var.create_mac_pool        ? intersight_macpool_pool.main[0].moid                      : data.intersight_macpool_pool.existing[0].moid
  uuid_pool_moid       = var.create_uuid_pool       ? intersight_uuidpool_pool.main[0].moid                     : data.intersight_uuidpool_pool.existing[0].moid
  ntp_policy_moid      = var.create_ntp_policy      ? intersight_ntp_policy.main[0].moid                        : data.intersight_ntp_policy.existing[0].moid
  network_policy_moid  = var.create_network_policy  ? intersight_networkconfig_policy.main[0].moid              : data.intersight_networkconfig_policy.existing[0].moid
  syslog_policy_moid   = var.create_syslog_policy   ? intersight_syslog_policy.main[0].moid                     : data.intersight_syslog_policy.existing[0].moid
  bios_policy_moid     = var.create_bios_policy     ? intersight_bios_policy.main[0].moid                       : data.intersight_bios_policy.existing[0].moid
  boot_policy_moid     = var.create_boot_policy     ? intersight_boot_precision_policy.main[0].moid             : data.intersight_boot_precision_policy.existing[0].moid
  imc_policy_moid      = var.create_imc_policy      ? intersight_access_policy.main[0].moid                     : data.intersight_access_policy.existing[0].moid
  local_user_moid      = var.create_local_user_policy ? intersight_iam_end_point_user_policy.main[0].moid       : data.intersight_iam_end_point_user_policy.existing[0].moid
  lan_policy_moid      = var.create_lan_policy      ? intersight_vnic_lan_connectivity_policy.main[0].moid      : data.intersight_vnic_lan_connectivity_policy.existing[0].moid
}

# ---------------------------------------------------------------------------
# Server Profile Template
# ---------------------------------------------------------------------------

data "intersight_server_profile_template" "existing" {
  count = var.create_server_template ? 0 : 1
  name  = var.server_profile_template_name
}

resource "intersight_server_profile_template" "base" {
  count           = var.create_server_template ? 1 : 0
  name            = var.server_profile_template_name
  description     = "Base UCS server profile template"
  target_platform = var.target_platform

  policy_bucket {
    object_type = "bios.Policy"
    moid        = local.bios_policy_moid
  }
  policy_bucket {
    object_type = "boot.PrecisionPolicy"
    moid        = local.boot_policy_moid
  }
  policy_bucket {
    object_type = "access.Policy"
    moid        = local.imc_policy_moid
  }
  policy_bucket {
    object_type = "iam.EndPointUserPolicy"
    moid        = local.local_user_moid
  }
  policy_bucket {
    object_type = "ntp.Policy"
    moid        = local.ntp_policy_moid
  }
  policy_bucket {
    object_type = "networkconfig.Policy"
    moid        = local.network_policy_moid
  }
  policy_bucket {
    object_type = "syslog.Policy"
    moid        = local.syslog_policy_moid
  }
  policy_bucket {
    object_type = "vnic.LanConnectivityPolicy"
    moid        = local.lan_policy_moid
  }

  organization { object_type = local.org.object_type; moid = local.org.moid }
}

# ---------------------------------------------------------------------------
# Server Profiles (derived from template)
# ---------------------------------------------------------------------------

resource "intersight_server_profile" "servers" {
  for_each        = { for s in var.server_profiles : s.name => s }
  name            = each.value.name
  description     = lookup(each.value, "description", "")
  target_platform = var.target_platform

  src_template {
    object_type = "server.ProfileTemplate"
    moid        = var.create_server_template ? intersight_server_profile_template.base[0].moid : data.intersight_server_profile_template.existing[0].moid
  }

  organization { object_type = local.org.object_type; moid = local.org.moid }
}
