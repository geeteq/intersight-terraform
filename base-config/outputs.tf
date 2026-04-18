output "ip_pool_moid" {
  description = "MOID of the created IP pool"
  value       = intersight_ippool_pool.mgmt.moid
}

output "mac_pool_moid" {
  description = "MOID of the created MAC pool"
  value       = intersight_macpool_pool.main.moid
}

output "server_profile_template_moid" {
  description = "MOID of the base server profile template"
  value       = intersight_server_profile_template.base.moid
}

output "server_profile_moids" {
  description = "MOIDs of the created server profiles"
  value       = { for k, v in intersight_server_profile.servers : k => v.moid }
}
