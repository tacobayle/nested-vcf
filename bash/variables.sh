#!/bin/bash
#
SLACK_WEBHOOK_URL=$(jq -c -r .slack_webhook $jsonFile)
DEPOT_USERNAME=$(jq -c -r .depot.username $jsonFile)
DEPOT_PASSWORD=$(jq -c -r .depot.password $jsonFile)
folder=$(jq -c -r .vsphere_underlay.folder $jsonFile)
gw_name="$(jq -c -r .sddc.basename $jsonFile)-external-gw"
basename=$(jq -c -r .esxi.basename $jsonFile)
basename_sddc=$(jq -c -r .sddc.basename $jsonFile)
basename_nsx_manager="-nsx-manager-"
basename_avi_ctrl="-avi-ctrl-"
ip_gw_last_octet="1"
ips_nsx=$(jq -c -r .sddc.nsx.ips $jsonFile | jq ". | map(\"$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')\" + (. | tostring))")
ip_nsx_vip="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.nsx.vip ${jsonFile})"
ips_avi=$(jq -c -r .sddc.avi.ips $jsonFile | jq ". | map(\"$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')\" + (. | tostring))")
ip_avi_vip="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.avi.vip ${jsonFile})"
ip_sddc_manager="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.manager.ip ${jsonFile})"
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
ip_vcf_automation_start="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_automation.ip_pool {jsonFile}| cut -f1 -d'-')"
ip_vcf_automation_end="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_automation.ip_pool ${jsonFile}| cut -f2 -d'-')"
ip_vcf_operation="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation.ip ${jsonFile})"
ip_vcf_operation_fleet="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation_fleet.ip ${jsonFile})"
ip_vcf_operation_collector="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .vcf_operation_collector.ip ${jsonFile})"
folders_to_copy=$(jq -c -r '.folders_to_copy' $jsonFile)

