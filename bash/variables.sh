#!/bin/bash
#
slack_webhook=$(jq -c -r .slack_webhook $jsonFile)
google_webhook=$(jq -c -r .google_webhook $jsonFile)
DEPOT_USERNAME=$(jq -c -r .depot.username $jsonFile)
DEPOT_PASSWORD=$(jq -c -r .depot.password $jsonFile)
folder=$(jq -c -r .vsphere_underlay.folder $jsonFile)
basename=$(jq -c -r '.esxi.basename' $jsonFile)
basename_sddc=$(jq -c -r '.sddc.basename' $jsonFile)
gw_name="${basename_sddc}-external-gw"
domain=$(jq -c -r '.domain' $jsonFile)
fqdn_vcfa="${basename_sddc}-vcfa.${domain}"
cluster_name="${basename_sddc}-cluster"
dc_name="${basename_sddc}-dc"
ds_name="${basename_sddc}-vsan"
default_storage_class="${cluster_name} vSAN Storage Policy"
basename_nsx_manager="-nsx-manager-"
basename_avi_ctrl="-avi-ctrl-"
ip_gw_last_octet="1"
ubuntu_ova_url=$(jq -c -r .gw.ova_url $jsonFile)
#
# Vault variables
#
vault_secret_file_path=$(jq -c -r '.vault.secret_file_path' $jsonFile)
vault_pki_name=$(jq -c -r '.vault.pki.name' $jsonFile)
vault_pki_max_lease_ttl=$(jq -c -r '.vault.pki.max_lease_ttl' $jsonFile)
vault_pki_cert_common_name=$(jq -c -r '.vault.pki.cert.common_name' $jsonFile)
vault_pki_cert_issuer_name=$(jq -c -r '.vault.pki.cert.issuer_name' $jsonFile)
vault_pki_cert_ttl=$(jq -c -r '.vault.pki.cert.ttl' $jsonFile)
vault_pki_cert_path=$(jq -c -r '.vault.pki.cert.path' $jsonFile)
vault_pki_role_name=$(jq -c -r '.vault.pki.role.name' $jsonFile)
vault_pki_intermediate_name=$(jq -c -r '.vault.pki_intermediate.name' $jsonFile)
vault_pki_intermediate_max_lease_ttl=$(jq -c -r '.vault.pki_intermediate.max_lease_ttl' $jsonFile)
vault_pki_intermediate_cert_common_name=$(jq -c -r '.vault.pki_intermediate.cert.common_name' $jsonFile)
vault_pki_intermediate_cert_issuer_name=$(jq -c -r '.vault.pki_intermediate.cert.issuer_name' $jsonFile)
vault_pki_intermediate_cert_path=$(jq -c -r '.vault.pki_intermediate.cert.path' $jsonFile)
vault_pki_intermediate_cert_path_signed=$(jq -c -r '.vault.pki_intermediate.cert.path_signed' $jsonFile)
vault_pki_intermediate_role_name=$(jq -c -r '.vault.pki_intermediate.role.name' $jsonFile)
vault_pki_intermediate_role_allow_subdomains=$(jq -c -r '.vault.pki_intermediate.role.allow_subdomains' $jsonFile)
vault_pki_intermediate_role_max_ttl=$(jq -c -r '.vault.pki_intermediate.role.max_ttl' $jsonFile)
#
#
#
ips_nsx=$(jq -c -r .sddc.nsx.ips $jsonFile | jq ". | map(\"$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')\" + (. | tostring))")
ip_nsx_vip="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.nsx.vip ${jsonFile})"
ips_avi=$(jq -c -r .sddc.avi.ips $jsonFile | jq ". | map(\"$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')\" + (. | tostring))")
ip_avi_vip="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.avi.vip ${jsonFile})"
ip_sddc_manager="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.manager.ip ${jsonFile})"
mgmt_prefix_length=$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -f2 -d"/")
ip_gw_mgmt="$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}"
ip_gw_external="$(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}"
nsx_pool_range_start="$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.nsx.vtep_pool ${jsonFile}| cut -f1 -d'-')"
nsx_pool_range_end="$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.nsx.vtep_pool ${jsonFile}| cut -f2 -d'-')"
starting_ip_vsan="$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.vcenter.vsanPool ${jsonFile}| cut -f1 -d'-')"
ending_ip_vsan="$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.vcenter.vsanPool ${jsonFile}| cut -f2 -d'-')"
starting_ip_vmotion="$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.vcenter.vmotionPool ${jsonFile}| cut -f1 -d'-')"
ending_ip_vmotion="$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.vcenter.vmotionPool ${jsonFile}| cut -f2 -d'-')"
ip_gw=$(jq -c -r .gw.ip $jsonFile)
gw_vcf_cli_url=$(jq -c -r .gw.vcf_cli_url $jsonFile)
ip_vcsa="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.vcenter.ip ${jsonFile})"
name_cb=$(jq -c -r .cloud_builder.name $jsonFile)
name_vcf_installer=$(jq -c -r .vcf_installer.name $jsonFile)
iso_url=$(jq -c -r .esxi.iso_url $jsonFile)
if [[ ${name_vcf_installer} != "null" ]]; then
  vcf_version=$(echo ${iso_url} | cut -d"-" -f4 | cut -d"." -f1-3)
  vcf_version_full=$(echo ${iso_url} | cut -d"-" -f4 | cut -d"." -f1-4)
fi
cidr_mgmt=$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -d"/" -f1)
if [[ ${cidr_mgmt} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}$ ]] ; then
  cidr_mgmt_three_octets="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
fi
cidr_external=$(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -d"/" -f1)
if [[ ${cidr_external} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}$ ]] ; then
  cidr_external_three_octets="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
fi
external_prefix_length=$(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -f2 -d"/")
ips_esxi=$(jq -c -r .esxi.ips $jsonFile | jq ". | map(\"$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')\" + (. | tostring))")
esxi_trunk=$(jq -c -r .esxi.trunk $jsonFile)
cloud_builder_ova_url=$(jq -c -r .cloud_builder.ova_url $jsonFile)
cloud_builder_network_ref=$(jq -c -r .cloud_builder.network_ref $jsonFile)
vcf_installer_ova_url=$(jq -c -r .vcf_installer.ova_url $jsonFile)
vcf_installer_network_ref=$(jq -c -r .vcf_installer.network_ref $jsonFile)
ip_cb=$(jq -c -r .cloud_builder.ip $jsonFile)
ip_vcf_installer=$(jq -c -r .vcf_installer.ip $jsonFile)
vcf_installer_token=$(jq -c -r .vcf_installer.token $jsonFile)
vcf_automation_node_prefix="$(jq -c -r .vcf_automation.node_prefix ${jsonFile})"
ip_vcf_automation="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_automation.ip ${jsonFile})"
ip_vcf_automation_start="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_automation.ip_pool ${jsonFile}| cut -f1 -d'-')"
ip_vcf_automation_end="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_automation.ip_pool ${jsonFile}| cut -f2 -d'-')"
ip_vcf_operation="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation.ip ${jsonFile})"
ip_vcf_operation_fleet="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation_fleet.ip ${jsonFile})"
ip_vcf_operation_collector="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation_collector.ip ${jsonFile})"
folders_to_copy=$(jq -c -r '.folders_to_copy' ${jsonFile})
vcfi_scripts=$(jq -c -r '.vcfi_scripts' ${jsonFile})
K8s_version_short=$(jq -c -r '.K8s_version_short' ${jsonFile})
ssoDomain=$(jq -c -r '.sddc.vcenter.ssoDomain' ${jsonFile})
vsphere_nested_username=$(jq -c -r '.vsphere_nested_username' ${jsonFile})
vsphere_cl_name=$(jq -c -r '.vsphere_cl_name' ${jsonFile})
content_library_subscription_url=$(jq -c -r '.content_library_subscription_url' ${jsonFile})
generic_password=$(jq -c -r '.generic_password' $jsonFile)
nsx_config_transport_zones=$(jq -c -r .nsx.config.transport_zones $jsonFile)
nsx_config_ip_pools=$(jq -c -r .nsx.config.ip_pools $jsonFile)
ip_gw_edge_overlay="$(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}"
cidr_edge_overlay=$(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)
network_edge_overlay=$(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -f1 -d"/")
if [[ ${network_edge_overlay} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}$ ]] ; then
  cidr_edge_overlay_three_octets="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
fi
ip_start_nsx_edge_overlay="${cidr_edge_overlay_three_octets}.$(jq -c -r .nsx.pool_start $jsonFile)"
ip_end_nsx_edge_overlay="${cidr_edge_overlay_three_octets}.$(jq -c -r .nsx.pool_end $jsonFile)"
nsx_config_segments=$(jq -c -r .nsx.config.segments $jsonFile)
nsx_config_uplink_profiles=$(jq -c -r .nsx.config.uplink_profiles $jsonFile)
nsx_config_ips_edge=$(jq -c -r .nsx.config.ips_edge $jsonFile)
nsx_config_edge_node_basename=$(jq -c -r .nsx.config.edge_node.basename $jsonFile)
nsx_config_edge_node_host_switch_spec_host_switches=$(jq -c -r .nsx.config.edge_node.host_switch_spec.host_switches $jsonFile)
nsx_config_edge_node_cpu=$(jq -c -r .nsx.config.edge_node.cpu $jsonFile)
nsx_config_edge_node_memory=$(jq -c -r .nsx.config.edge_node.memory $jsonFile)
nsx_config_edge_clusters=$(jq -c -r .nsx.config.edge_clusters $jsonFile)
nsx_config_tier0s=$(jq -c -r .nsx.config.tier0s $jsonFile)
nsx_tier0_starting_ip=$(jq -c -r .nsx.tier0_starting_ip $jsonFile)
nsx_tier0_tier0_vip_starting_ip=$(jq -c -r .nsx.tier0_vip_starting_ip $jsonFile)
nsx_config_dhcp_servers=$(jq -c -r '.nsx.config.dhcp_servers' $jsonFile)
nsx_config_tier1s=$(jq -c -r .nsx.config.tier1s $jsonFile)
nsx_supernet_overlay=$(jq -c -r '.sddc.nsx.supernet_overlay' ${jsonFile})
nsx_supernet_overlay_third_octet=$(echo "${nsx_supernet_overlay}" | cut -d'.' -f3)
nsx_supernet_overlay_first_two_octets=$(echo "${nsx_supernet_overlay}" | cut -d'.' -f1-2)
segments_overlay="[]"
nsx_segment_count=0
vip_subnet_index=0
supernet_vip=$(jq -c -r '.sddc.avi.supernet_vip' $jsonFile)
supernet_vip_first_two_octets=$(echo "${supernet_vip}" | cut -d'.' -f1-2)
supernet_vip_third_octet=$(echo "${supernet_vip}" | cut -d'.' -f3)
nsx_amount_of_segment=$((${nsx_supernet_overlay_third_octet} + $(jq '.nsx.config.segments_overlay | length' $jsonFile) - 1))
for seg_index in $(seq ${nsx_supernet_overlay_third_octet} ${nsx_amount_of_segment})
do
  cidr="${nsx_supernet_overlay_first_two_octets}.${seg_index}.0/24"
  cidr_three_octets="${nsx_supernet_overlay_first_two_octets}.${seg_index}"
  cidr_vip_subnet="${supernet_vip_first_two_octets}.$(($supernet_vip_third_octet+$vip_subnet_index)).0/24"
  cidr_vip_three_octets="${supernet_vip_first_two_octets}.$(($supernet_vip_third_octet+$vip_subnet_index))"
  segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"cidr": "'${cidr}'",
                                                   "display_name": "'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].display_name' $jsonFile)'",
                                                   "transport_zone": "'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].transport_zone' $jsonFile)'",
                                                   "tier1": "'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].tier1' $jsonFile)'",
                                                   "cidr_three_octets": "'${cidr_three_octets}'",
                                                   "gateway_address": "'${cidr_three_octets}'.1/24",
                                                   "dhcp_ranges": ["'${cidr_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].dhcp_ranges[0]' $jsonFile | cut -d'-' -f1)'-'${cidr_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].dhcp_ranges[0]' $jsonFile | cut -d'-' -f2)'"]
                                                   }')

  if $(echo $(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}']' $jsonFile) | jq -e '.supervisor_starting_ip' > /dev/null) ; then
    segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"supervisor_starting_ip": "'${cidr_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].supervisor_starting_ip' $jsonFile)'"}')
  fi
  if $(echo $(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}']' $jsonFile) | jq -e '.supervisor_count' > /dev/null) ; then
    segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"supervisor_count": "'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].supervisor_count' $jsonFile)'"}')
  fi
  if $(echo $(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}']' $jsonFile) | jq -e '.supervisor_mgmt' > /dev/null) ; then
    segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"supervisor_mgmt": '$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].supervisor_mgmt' $jsonFile)'}')
  fi
  if $(echo $(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}']' $jsonFile) | jq -e '.avi_mgmt' > /dev/null) ; then
    segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"avi_mgmt": '$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].avi_mgmt' $jsonFile)'}')
  fi
  if $(echo $(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}']' $jsonFile) | jq -e '.avi_ipam_pool_se' > /dev/null) ; then
    segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"avi_ipam_pool_se": "'${cidr_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].avi_ipam_pool_se' $jsonFile | cut -d"-" -f1)'-'${cidr_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].avi_ipam_pool_se' $jsonFile | cut -d"-" -f2)'"}')
  fi
  if $(echo $(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}']' $jsonFile) | jq -e '.avi_ipam_pool_vip' > /dev/null) ; then
    segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"avi_ipam_vip": {"cidr": "'${cidr_vip_subnet}'", "pool": "'${cidr_vip_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].avi_ipam_pool_vip' $jsonFile | cut -d"-" -f1)'-'${cidr_vip_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].avi_ipam_pool_vip' $jsonFile | cut -d"-" -f2)'"}}')
    ((vip_subnet_index++))
  fi
  ((nsx_segment_count++))
done
nsx_config_segment_overlay_file=$(jq -c -r '.nsx.config.segment_overlay_file' $jsonFile)
echo ${segments_overlay} | tee ${nsx_config_segment_overlay_file} > /dev/null 2>&1
nsx_segments_overlay=$(jq -c -r . ${nsx_config_segment_overlay_file})
ip_blocks_json="[]"
# private pool
supernet_vpc_private=$(jq -c -r '.sddc.nsx.supernet_vpc_private' $jsonFile)
supernet_vpc_private_third_octet=$(echo "${supernet_vpc_private}" | cut -d'.' -f3)
supernet_vpc_private_two_octets=$(echo "${supernet_vpc_private}" | cut -d'.' -f1-2)
private_count=0
global_count=0
last_private_third_octet=$((${supernet_vpc_private_third_octet} + $(jq '[.nsx.config.ip_blocks[] | select(.visibility == "PRIVATE") ] | length' $jsonFile) - 1))
for third_octet in $(seq ${supernet_vpc_private_third_octet} ${last_private_third_octet})
do
  cidr="${supernet_vpc_private_two_octets}.${third_octet}.0/24"
  # cidr_private_three_octets="${supernet_vpc_private_two_octets}.${third_octet}"
  ip_blocks_json=$(echo ${ip_blocks_json} | jq '.['${global_count}'] += {"name": "'$(jq -c -r '[.nsx.config.ip_blocks[] | select(.visibility == "PRIVATE") ]' $jsonFile | jq -c -r .[${private_count}].name)'",
                                                   "cidr": "'${cidr}'",
                                                   "visibility": "'$(jq -c -r '[.nsx.config.ip_blocks[] | select(.visibility == "PRIVATE") ]' $jsonFile | jq -c -r .[${private_count}].visibility)'",
                                                   "scope": "'$(jq -c -r '[.nsx.config.ip_blocks[] | select(.visibility == "PRIVATE") ]' $jsonFile | jq -c -r .[${private_count}].scope)'",
                                                   "project_ref": "'$(jq -c -r '[.nsx.config.ip_blocks[] | select(.visibility == "PRIVATE") ]' $jsonFile | jq -c -r .[${private_count}].project_ref)'"}')
  ((private_count++))
  ((global_count++))
done
# public pool
supernet_vpc_public=$(jq -c -r '.sddc.nsx.supernet_vpc_public' $jsonFile)
supernet_vpc_public_third_octet=$(echo "${supernet_vpc_public}" | cut -d'.' -f3)
supernet_vpc_public_two_octets=$(echo "${supernet_vpc_public}" | cut -d'.' -f1-2)
public_count=0
last_public_third_octet=$((${supernet_vpc_public_third_octet} + $(jq '[.nsx.config.ip_blocks[] | select(.visibility == "EXTERNAL" and .project_ref == "default") ] | length' $jsonFile) - 1))
for third_octet in $(seq ${supernet_vpc_public_third_octet} ${last_public_third_octet})
do
  cidr="${supernet_vpc_public_two_octets}.${third_octet}.0/24"
  # cidr_public_three_octets="${supernet_vpc_public_two_octets}.${third_octet}"
  ip_blocks_json=$(echo ${ip_blocks_json} | jq '.['${global_count}'] += {"name": "'$(jq -c -r '[.nsx.config.ip_blocks[] | select(.visibility == "EXTERNAL") ]' $jsonFile | jq -c -r .[${public_count}].name)'",
                                                   "cidr": "'${cidr}'",
                                                   "project_ref": "'$(jq -c -r '[.nsx.config.ip_blocks[] | select(.visibility == "EXTERNAL") ]' $jsonFile | jq -c -r .[${public_count}].project_ref)'",
                                                   "visibility": "'$(jq -c -r '[.nsx.config.ip_blocks[] | select(.visibility == "EXTERNAL") ]' $jsonFile | jq -c -r .[${public_count}].visibility)'"}')
  ((public_count++))
  ((global_count++))
done
nsx_config_ip_blocks=$(echo ${ip_blocks_json} | jq -c -r '.')
nsx_config_gw_connections=$(jq -c -r .nsx.config.gw_connections $jsonFile)
nsx_config_projects=$(jq -c -r .nsx.config.projects $jsonFile)
nsx_config_transit_gateways=$(jq -c -r .nsx.config.transit_gateways $jsonFile)
nsx_config_vpc_connectivity_profiles=$(jq -c -r .nsx.config.vpc_connectivity_profiles $jsonFile)
nsx_config_vpc_service_profiles=$(jq -c -r .nsx.config.vpc_service_profiles $jsonFile)
nsx_config_vpcs=$(jq -c -r .nsx.config.vpcs $jsonFile)
avi_ova_url=$(jq -c -r '.sddc.avi.ova_url' $jsonFile)
avi_ova_url_sddc_manager=$(jq -c -r '.sddc.avi.ova_url_sddc_manager' $jsonFile)
avi_product_version_sddc_manager=$(jq -c -r '.sddc.avi.product_version_sddc_manager' $jsonFile)
folder_avi=$(jq -c -r '.avi.folder' $jsonFile)
vcsa_mgmt_cluster="${basename_sddc}-cluster"
vcsa_fqdn="${basename_sddc}-vcsa.${domain}"
vcsa_mgmt_dc="${basename_sddc}-dc"
vcsa_mgmt_datastore="${basename_sddc}-vsan"
avi_ctrl_name=${basename_sddc}${basename_avi_ctrl}1
ip_avi=$(echo ${ips_avi} | jq -c -r '.[0]')
networks=$(jq -c -r '.sddc.vcenter.networks' $jsonFile)
network_vm_management_name="${basename_sddc}-pg-vm-mgmt"
ip_gw_vm_management="$(echo ${networks} | jq -c -r --arg arg "VM_MANAGEMENT" '.[] | select(.type == $arg).cidr' | awk -F'0/' '{print $1}')${ip_gw_last_octet}"
folder_avi=$(jq -c -r '.avi.folder' $jsonFile)
avi_content_library_name=$(jq -c -r '.avi.content_library_name' $jsonFile)
avi_old_password=$(jq -c -r '.sddc.avi.avi_old_password' $jsonFile)
avi_version=$(basename ${avi_ova_url} | cut -d"-" -f2)
import_sslkeyandcertificate_ca="[]"
certificatemanagementprofile="[]"
alertscriptconfig="[]"
actiongroupconfig="[]"
alertconfig="[]"
sslkeyandcertificate='[
                        {
                          "name": "my-new-self-signed",
                          "format": "SSL_PEM",
                          "certificate_base64": true,
                          "enable_ocsp_stapling": false,
                          "import_key_to_hsm": false,
                          "is_federated": false,
                          "key_base64": true,
                          "type": "SSL_CERTIFICATE_TYPE_SYSTEM",
                          "certificate": {
                            "days_until_expire": 365,
                            "self_signed": true,
                            "version": "2",
                            "signature_algorithm": "sha256WithRSAEncryption",
                            "subject_alt_names": ["'${ip_avi}'"],
                            "issuer": {
                              "common_name": "https://'${avi_ctrl_name}.${domain}'",
                              "distinguished_name": "CN='${avi_ctrl_name}.${domain}'"
                            },
                            "subject": {
                              "common_name": "'${avi_ctrl_name}.${domain}'",
                              "distinguished_name": "CN='${avi_ctrl_name}.${domain}'"
                            }
                          },
                          "key_params": {
                            "algorithm": "SSL_KEY_ALGORITHM_RSA",
                            "rsa_params": {
                              "exponent": 65537,
                              "key_size": "SSL_KEY_2048_BITS"
                            }
                          },
                          "ocsp_config": {
                            "failed_ocsp_jobs_retry_interval": 3600,
                            "max_tries": 10,
                            "ocsp_req_interval": 86400,
                            "url_action": "OCSP_RESPONDER_URL_FAILOVER"
                          }
                         }
                      ]'
applicationprofile="[]"
vsdatascriptset="[]"
httppolicyset="[]"
roles="[]"
tenants="[]"
users="[]"
nsx_cloud_name=$(jq -c -r '.avi.nsx_cloud_name' $jsonFile)
cloud_obj_name_prefix=$(jq -c -r '.avi.cloud_obj_name_prefix' $jsonFile)
avi_subdomain=$(jq -c -r '.avi.avi_subdomain' $jsonFile)
avi_nsx_transport_zone="VCF-Created-Overlay-Zone"
service_engine_groups=$(jq -c -r '.avi.service_engine_groups' $jsonFile)
network_services="[]"
pools="[]"
pool_groups="[]"
avi_vip_tier1_name=$(echo ${nsx_segments_overlay} | jq -c -r '[.[] | select(has("avi_ipam_vip"))]' | jq -c -r '.[0].tier1')
avi_vip_cidr=$(echo ${nsx_segments_overlay} | jq -c -r '[.[] | select(has("avi_ipam_vip"))]' | jq -c -r '.[0].avi_ipam_vip.cidr')
avi_vip_network_ref=$(echo ${nsx_segments_overlay} | jq -c -r '[.[] | select(has("avi_ipam_vip"))]' | jq -c -r '.[0].display_name')
virtual_services='{"dns": [
                            {
                              "name": "dns-vs",
                              "type": "V4",
                              "tier1": "'${avi_vip_tier1_name}'",
                              "cidr": "'${avi_vip_cidr}'",
                              "network_ref": "'${avi_vip_network_ref}'",
                              "se_group_ref": "Default-Group",
                              "services": [{"port": 53}]
                            }
                          ], "http": []}'
avi_ansible_config_repo=$(jq -c -r '.avi.ansible_config_repo' $jsonFile)
avi_ansible_config_tag=$(jq -c -r '.avi.ansible_config_tag' $jsonFile)
avi_ansible_playbook=$(jq -c -r '.avi.ansible_playbook' $jsonFile)
ip_avi_dns=$(echo ${nsx_segments_overlay} | jq -c -r '[.[] | select(has("avi_ipam_vip"))]' | jq -c -r '.[0].avi_ipam_vip.pool' | cut -d"-" -f1)
supervisor_cluster_size=$(jq -c -r '.supervisor_cluster.size' $jsonFile)
supervisor_cluster_name=$(jq -c -r '.supervisor_cluster.name' $jsonFile)
supervisor_cluster_project_ref=$(jq -c -r '.supervisor_cluster.project_ref' $jsonFile)
supervisor_cluster_storage_policy_ref=$(jq -c -r '.supervisor_cluster.storage_policy_ref' $jsonFile)
supervisor_cluster_service_address=$(jq -c -r '.supervisor_cluster.service_address' $jsonFile)
supervisor_cluster_service_address_count=$(jq -c -r '.supervisor_cluster.service_address_count' $jsonFile)
supervisor_cluster_vpc_profile=$(jq -c -r '.supervisor_cluster.vpc_profile_ref' $jsonFile)
supervisor_cluster_vpc_private_cidr_address=$(jq -c -r '.supervisor_cluster.vpc_private_cidr_address' $jsonFile)
supervisor_cluster_vpc_private_cidr_prefix=$(jq -c -r '.supervisor_cluster.vpc_private_cidr_prefix' $jsonFile)