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
  cloud       = var.cloud_name
  insecure    = true
}

data "openstack_images_image_v2" "rhel9" {
  name        = var.image_name
  most_recent = true
}

data "openstack_compute_flavor_v2" "jumpbox" {
  name = var.flavor_name
}

data "openstack_networking_network_v2" "jumpbox" {
  name = var.network_name
}

locals {
  cloud_init = templatefile("${path.module}/cloud_init.tftpl", {
    baremetal_user = var.baremetal_user
    ssh_public_key = var.ssh_public_key
    packages       = var.packages
  })
}

resource "openstack_compute_instance_v2" "jumpbox" {
  name              = var.vm_name
  image_id          = data.openstack_images_image_v2.rhel9.id
  flavor_id         = data.openstack_compute_flavor_v2.jumpbox.id
  availability_zone = var.availability_zone
  user_data         = local.cloud_init

  network {
    uuid = data.openstack_networking_network_v2.jumpbox.id
  }

  dynamic "security_groups" {
    for_each = var.security_groups
    content {
      name = security_groups.value
    }
  }

  metadata = {
    provisioned_by = "intersight-terraform"
    managed        = "true"
  }

  lifecycle {
    ignore_changes = [image_id]
  }
}

resource "openstack_networking_floatingip_v2" "jumpbox" {
  count = var.floating_ip_pool != "" ? 1 : 0
  pool  = var.floating_ip_pool
}

resource "openstack_compute_floatingip_associate_v2" "jumpbox" {
  count       = var.floating_ip_pool != "" ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.jumpbox[0].address
  instance_id = openstack_compute_instance_v2.jumpbox.id
}
