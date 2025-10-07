#!/bin/bash
#
slack_webhook=$(jq -c -r .slack_webhook $jsonFile)
google_webhook=$(jq -c -r .google_webhook $jsonFile)
DEPOT_USERNAME=$(jq -c -r .depot.username $jsonFile)
DEPOT_PASSWORD=$(jq -c -r .depot.password $jsonFile)
folder=$(jq -c -r .vsphere_underlay.folder $jsonFile)
gw_name="$(jq -c -r .sddc.basename $jsonFile)-external-gw"
basename=$(jq -c -r .esxi.basename $jsonFile)
basename_sddc=$(jq -c -r .sddc.basename $jsonFile)
basename_nsx_manager="-nsx-manager-"
basename_avi_ctrl="-avi-ctrl-"
ip_gw_last_octet="1"
ubuntu_ova_url=$(jq -c -r .gw.ova_url $jsonFile)
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
domain=$(jq -c -r .domain $jsonFile)
ip_gw=$(jq -c -r .gw.ip $jsonFile)
ip_vcsa="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.vcenter.ip ${jsonFile})"
name_cb=$(jq -c -r .cloud_builder.name $jsonFile)
name_vcf_installer=$(jq -c -r .vcf_installer.name $jsonFile)
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
iso_url=$(jq -c -r .esxi.iso_url $jsonFile)
vcf_installer_token=$(jq -c -r .vcf_installer.token $jsonFile)
vcf_automation_node_prefix="$(jq -c -r .vcf_automation.node_prefix ${jsonFile})"
ip_vcf_automation="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_automation.ip ${jsonFile})"
ip_vcf_automation_start="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_automation.ip_pool ${jsonFile}| cut -f1 -d'-')"
ip_vcf_automation_end="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_automation.ip_pool ${jsonFile}| cut -f2 -d'-')"
ip_vcf_operation="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation.ip ${jsonFile})"
ip_vcf_operation_fleet="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation_fleet.ip ${jsonFile})"
ip_vcf_operation_collector="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation_collector.ip ${jsonFile})"
folders_to_copy=$(jq -c -r '.folders_to_copy' ${jsonFile})
ssoDomain=$(jq -c -r '.sddc.vcenter.ssoDomain' ${jsonFile})
vsphere_nested_username=$(jq -c -r '.vsphere_nested_username' ${jsonFile})
vsphere_cl_name=$(jq -c -r '.vsphere_cl_name' ${jsonFile})
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
nsx_amount_of_segment=$((${nsx_supernet_overlay_third_octet} + $(jq '.nsx.config.segments_overlay | length' $jsonFile) - 1))
for seg_index in $(seq ${nsx_supernet_overlay_third_octet} ${nsx_amount_of_segment})
do
  cidr="${nsx_supernet_overlay_first_two_octets}.${seg_index}.0/24"
  cidr_three_octets="${nsx_supernet_overlay_first_two_octets}.${seg_index}"
  segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"cidr": "'${cidr}'",
                                                   "display_name": "'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].display_name' $jsonFile)'",
                                                   "transport_zone": "'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].transport_zone' $jsonFile)'",
                                                   "tier1": "'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].tier1' $jsonFile)'",
                                                   "cidr_three_octets": "'${cidr_three_octets}'",
                                                   "gateway_address": "'${cidr_three_octets}'.1/24",
                                                   "dhcp_ranges": ["'${cidr_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].dhcp_ranges[0]' $jsonFile | cut -d'-' -f1)'-'${cidr_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].dhcp_ranges[0]' $jsonFile | cut -d'-' -f2)'"]
                                                   }')

  if $(echo $(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}']' $jsonFile) | jq -e '.tanzu_supervisor_starting_ip' > /dev/null) ; then
    segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"tanzu_supervisor_starting_ip": "'${cidr_three_octets}'.'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].tanzu_supervisor_starting_ip' $jsonFile)'"}')
  fi
  if $(echo $(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}']' $jsonFile) | jq -e '.tanzu_supervisor_count' > /dev/null) ; then
    segments_overlay=$(echo ${segments_overlay} | jq '.['${nsx_segment_count}'] += {"tanzu_supervisor_count": "'$(jq -c -r '.nsx.config.segments_overlay['${nsx_segment_count}'].tanzu_supervisor_count' $jsonFile)'"}')
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
avi_ova_url=$(jq -c -r '.sddc.avi.ova_url' $jsonFile)
folder_avi=$(jq -c -r '.avi.folder' $jsonFile)
vcsa_mgmt_cluster="${basename_sddc}-cluster"
vcsa_fqdn="${basename_sddc}-vcsa.${domain}"
vcsa_mgmt_dc="${basename_sddc}-dc"
avi_ctrl_name=$(jq -c -r '.avi.ctrl_name' $jsonFile)
ip_avi=$(echo ${ips_avi} | jq -c -r '.[0]')
networks=$(jq -c -r '.sddc.vcenter.networks' $jsonFile)
network_vm_management_name="${basename_sddc}-pg-vm-mgmt"
ip_gw_vm_management="$(echo ${networks} | jq -c -r --arg arg "VM_MANAGEMENT" '.[] | select(.type == $arg).cidr' | awk -F'0/' '{print $1}')${ip_gw_last_octet}"


