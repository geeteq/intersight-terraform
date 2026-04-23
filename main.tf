terraform {
  required_version = ">= 1.3"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.54"
    }
  }
}

provider "openstack" {
  insecure    = true
  use_octavia = false
}

# ---------------------------------------------------------------------------
# Intersight Appliance image (pre-imported into OpenStack)
# ---------------------------------------------------------------------------

data "openstack_images_image_v2" "disks" {
  count       = length(var.disk_sizes)
  name        = "${var.image_name}-${count.index + 1}"
  visibility  = "private"
  most_recent = true
}

data "openstack_compute_flavor_v2" "intersight" {
  name = var.flavor_name
}

data "openstack_networking_network_v2" "mgmt" {
  name = var.management_network
}

# ---------------------------------------------------------------------------
# Security group for Intersight Appliance
# ---------------------------------------------------------------------------

data "openstack_networking_secgroup_v2" "existing" {
  count = var.create_security_group ? 0 : 1
  name  = var.security_group_name
}

resource "openstack_networking_secgroup_v2" "intersight" {
  count       = var.create_security_group ? 1 : 0
  name        = var.security_group_name
  description = "Intersight Virtual Appliance security group"
}

# Inbound — management UI
resource "openstack_networking_secgroup_rule_v2" "https_ingress" {
  count             = var.create_security_group ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.intersight[0].id
}

resource "openstack_networking_secgroup_rule_v2" "http_ingress" {
  count             = var.create_security_group ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.intersight[0].id
}

resource "openstack_networking_secgroup_rule_v2" "ssh_ingress" {
  count             = var.create_security_group ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.intersight[0].id
}

# Outbound — allow all (Intersight needs to reach Cisco cloud for licensing)
resource "openstack_networking_secgroup_rule_v2" "egress_all" {
  count             = var.create_security_group ? 1 : 0
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.intersight[0].id
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  security_group_name = var.create_security_group ? openstack_networking_secgroup_v2.intersight[0].name : data.openstack_networking_secgroup_v2.existing[0].name

  # Intersight appliance initial configuration passed via user-data
  user_data = templatefile("${path.module}/appliance_config.tftpl", {
    hostname        = var.hostname
    dns_servers     = var.dns_servers
    ntp_servers     = var.ntp_servers
    admin_password  = var.admin_password
    proxy_host      = var.proxy_host
    proxy_port      = var.proxy_port
    proxy_username  = var.proxy_username
    proxy_password  = var.proxy_password
  })
}

# ---------------------------------------------------------------------------
# Cinder volumes — created from Glance images before instance boot
# ---------------------------------------------------------------------------

resource "openstack_blockstorage_volume_v3" "disks" {
  count    = length(var.disk_sizes)
  name     = "${var.hostname}-disk-${count.index + 1}"
  size     = var.disk_sizes[count.index]
  image_id = data.openstack_images_image_v2.disks[count.index].id
}

# ---------------------------------------------------------------------------
# Intersight Virtual Appliance instance
# ---------------------------------------------------------------------------

resource "openstack_compute_instance_v2" "intersight" {
  name              = var.hostname
  flavor_id         = data.openstack_compute_flavor_v2.intersight.id
  availability_zone = var.availability_zone
  user_data         = local.user_data

  dynamic "block_device" {
    for_each = range(length(var.disk_sizes))
    content {
      uuid                  = openstack_blockstorage_volume_v3.disks[block_device.value].id
      source_type           = "volume"
      destination_type      = "volume"
      boot_index            = block_device.value == 0 ? 0 : -1
      disk_bus              = "scsi"
      device_type           = "disk"
      delete_on_termination = true
    }
  }

  network {
    uuid = data.openstack_networking_network_v2.mgmt.id
  }

  security_groups = [local.security_group_name]

  metadata = {
    provisioned_by = "intersight-terraform"
    managed        = "true"
  }
}

# ---------------------------------------------------------------------------
# Floating IP (optional)
# ---------------------------------------------------------------------------

resource "openstack_networking_floatingip_v2" "intersight" {
  count = var.floating_ip_pool != "" ? 1 : 0
  pool  = var.floating_ip_pool
}

resource "openstack_compute_floatingip_associate_v2" "intersight" {
  count       = var.floating_ip_pool != "" ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.intersight[0].address
  instance_id = openstack_compute_instance_v2.intersight.id
}
