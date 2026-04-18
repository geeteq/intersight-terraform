output "instance_id" {
  description = "OpenStack instance UUID"
  value       = openstack_compute_instance_v2.intersight.id
}

output "management_ip" {
  description = "Management IP address of the Intersight appliance"
  value       = openstack_compute_instance_v2.intersight.access_ip_v4
}

output "floating_ip" {
  description = "Floating IP address (if assigned)"
  value       = var.floating_ip_pool != "" ? openstack_networking_floatingip_v2.intersight[0].address : null
}

output "appliance_url" {
  description = "URL to access the Intersight appliance web UI"
  value = format(
    "https://%s",
    var.floating_ip_pool != "" ? openstack_networking_floatingip_v2.intersight[0].address : openstack_compute_instance_v2.intersight.access_ip_v4
  )
}
