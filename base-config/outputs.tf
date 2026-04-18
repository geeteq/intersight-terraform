output "ip_pool_moid"                { value = local.ip_pool_moid }
output "mac_pool_moid"               { value = local.mac_pool_moid }
output "uuid_pool_moid"              { value = local.uuid_pool_moid }
output "ntp_policy_moid"             { value = local.ntp_policy_moid }
output "network_policy_moid"         { value = local.network_policy_moid }
output "syslog_policy_moid"          { value = local.syslog_policy_moid }
output "bios_policy_moid"            { value = local.bios_policy_moid }
output "boot_policy_moid"            { value = local.boot_policy_moid }
output "imc_policy_moid"             { value = local.imc_policy_moid }
output "local_user_policy_moid"      { value = local.local_user_moid }
output "lan_policy_moid"             { value = local.lan_policy_moid }

output "server_profile_template_moid" {
  value = var.create_server_template ? intersight_server_profile_template.base[0].moid : data.intersight_server_profile_template.existing[0].moid
}

output "server_profile_moids" {
  value = { for k, v in intersight_server_profile.servers : k => v.moid }
}
