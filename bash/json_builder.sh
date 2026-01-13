#!/bin/bash
jsonFile=${1}
source /home/ubuntu/bash/variables.sh
#
#
#
echo '------------------------------------------------------------'
echo "Cloud Builder JSON file creation"
hostSpecs="[]"
hosts_validation_json="[]"
for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
do
  if [[ $(((${esxi}-1)/4+1)) -eq 1 ]] ; then
    name_esxi="${basename_sddc}-mgmt-esxi0${esxi}"
  fi
  if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
    name_esxi="${basename_sddc}-wld$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4))"
  fi
    ip_esxi="$(echo ${ips_esxi} | jq -r .[$(expr ${esxi} - 1)])"
    count=1
    until $(curl --output /dev/null --silent --head -k https://${ip_esxi})
    do
      echo "Attempt ${count}: Waiting for ESXi host at https://${ip_esxi} to be reachable..."
      sleep 10
      count=$((count+1))
        if [[ "${count}" -eq 60 ]]; then
          echo "ERROR: Unable to connect to ESXi host at https://${ip_esxi}"
          if [ -z "${slack_webhook}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-${basename_sddc}: nested ESXi '${ip_esxi}' unable to reach"}' ${slack_webhook} >/dev/null 2>&1; fi
          exit
        fi
    done
    if [[ ${name_cb} != "null" ]]; then
      hostSpec='{"association":"'${folder}'-dc","ipAddressPrivate":{"ipAddress":"'${ip_esxi}'"},"hostname":"'${name_esxi}'","credentials":{"username":"root","password":"'$(jq -c -r .generic_password $jsonFile)'"},"vSwitch":"vSwitch0"}'
      #host_validation_json='{"fqdn":"'${name_esxi}'.'${domain}'","username":"root","password" :"'$(jq -c -r .generic_password $jsonFile)'","storageType":"VSAN","vvolStorageProtocolType":null,"networkPoolId" : "58d74167-ee80-4eb8-90d9-cdfb3c1cd9f3","networkPoolName":"engineering-networkpool","sshThumbprint":null,"sslThumbprint":null}'
      #hosts_validation_json=$(echo ${hosts_validation_json} | jq '. += ['${host_validation_json}']')
    fi
    if [[ ${name_vcf_installer} != "null" ]]; then
      sleep 60
      esxi_sslThumbprint=$(echo | openssl s_client -servername ${ip_esxi} -connect ${ip_esxi}:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | awk -F'Fingerprint=' '{print $2}')
      hostSpec='{"hostname":"'${name_esxi}'","credentials":{"username":"root","password":"'$(jq -c -r .generic_password $jsonFile)'"},"sslThumbprint":"'${esxi_sslThumbprint}'"}'
    fi
    hostSpecs=$(echo ${hostSpecs} | jq '. += ['${hostSpec}']')
done
#
#
#
nsxtManagers="[]"
for nsx_count in $(seq 1 $(echo ${ips_nsx} | jq -c -r '. | length'))
do
  nsxtManager='{"hostname":"'${basename_sddc}''${basename_nsx_manager}''${nsx_count}'","ip":"'$(echo ${ips_nsx} | jq -c -r '.['$((nsx_count - 1))']')'"}'
  nsxtManagers=$(echo ${nsxtManagers} | jq '. += ['${nsxtManager}']')
done
#
#
#
if [[ ${esxi_trunk} == "true" && ${name_vcf_installer} != "null" ]] ; then
  sed -e "s/\${basename_sddc}/${basename_sddc}/" \
      -e "s/\${SDDC_MANAGER_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
      -e "s/\${VCFA_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
      -e "s/\${ip_vcf_automation_start}/${ip_vcf_automation_start}/" \
      -e "s/\${ip_vcf_automation_end}/${ip_vcf_automation_end}/" \
      -e "s/\${vcf_automation_node_prefix}/${vcf_automation_node_prefix}/" \
      -e "s/\${vcf_version_full}/${vcf_version_full}/" \
      -e "s/\${basename_sddc}/${basename_sddc}/" \
      -e "s/\${domain}/${domain}/" \
      -e "s/\${hostSpecs}/$(echo ${hostSpecs} | jq -c -r .)/" \
      -e "s/\${VCFO_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
      -e "s/\${ip_gw}/${ip_gw}/" \
      -e "s/\${VCS_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
      -e "s/\${ssoDomain}/$(jq -c -r .sddc.vcenter.ssoDomain ${jsonFile})/" \
      -e "s/\${nsxtManagerSize}/$(jq -c -r .sddc.nsx.size ${jsonFile})/" \
      -e "s/\${NSX_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
      -e "s/\${nsx_pool_range_start}/${nsx_pool_range_start}/" \
      -e "s/\${nsx_pool_range_end}/${nsx_pool_range_end}/" \
      -e "s@\${nsx_subnet_cidr}@$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${nsx_subnet_gw}/$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_host_overlay}/$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s/\${basename_nsx_manager}/${basename_nsx_manager}/" \
      -e "s/\${gw_mgmt}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_mgmt}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s@\${cidr_mgmt}@$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s@\${cidr_vm_mgmt}@$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${gw_vm_mgmt}/$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_vm_mgmt}/$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s@\${cidr_vmotion}@$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${gw_vmotion}/$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_vmotion}/$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s/\${ending_ip_vmotion}/${ending_ip_vmotion}/" \
      -e "s/\${starting_ip_vmotion}/${starting_ip_vmotion}/" \
      -e "s@\${cidr_vsan}@$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${gw_vsan}/$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_vsan}/$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s/\${ending_ip_vsan}/${ending_ip_vsan}/" \
      -e "s/\${starting_ip_vsan}/${starting_ip_vsan}/" /home/ubuntu/templates/sddc_vcf_installer_trunk.json.template | tee /home/ubuntu/json/${basename_sddc}.json > /dev/null
fi
#
#
#
if [[ ${esxi_trunk} == "true" && ${name_cb} != "null" ]] ; then
  sed -e "s/\${basename_sddc}/${basename_sddc}/" \
      -e "s/\${SDDC_MANAGER_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
      -e "s/\${ip_sddc_manager}/${ip_sddc_manager}/" \
      -e "s/\${basename_sddc}/${basename_sddc}/" \
      -e "s/\${ip_gw}/${ip_gw}/" \
      -e "s/\${domain}/${domain}/" \
      -e "s@\${subnet_mgmt}@$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${gw_mgmt}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_mgmt}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s@\${subnet_vmotion}@$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${gw_vmotion}/$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_vmotion}/$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s/\${ending_ip_vmotion}/${ending_ip_vmotion}/" \
      -e "s/\${starting_ip_vmotion}/${starting_ip_vmotion}/" \
      -e "s@\${subnet_vsan}@$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${gw_vsan}/$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_vsan}/$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s/\${ending_ip_vsan}/${ending_ip_vsan}/" \
      -e "s/\${starting_ip_vsan}/${starting_ip_vsan}/" \
      -e "s@\${subnet_vm_mgmt}@$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${gw_vm_mgmt}/$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${vlan_id_vm_mgmt}/$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s/\${nsxtManagerSize}/$(jq -c -r .sddc.nsx.size ${jsonFile})/" \
      -e "s/\${nsxtManagers}/$(echo ${nsxtManagers} | jq -c -r .)/" \
      -e "s/\${NSX_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
      -e "s/\${ip_nsx_vip}/${ip_nsx_vip}/" \
      -e "s/\${basename_nsx_manager}/${basename_nsx_manager}/" \
      -e "s/\${transportVlanId}/$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
      -e "s/\${nsx_pool_range_start}/${nsx_pool_range_start}/" \
      -e "s/\${nsx_pool_range_end}/${nsx_pool_range_end}/" \
      -e "s@\${nsx_subnet_cidr}@$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
      -e "s/\${nsx_subnet_gw}/$(jq -c -r --arg arg "HOST_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
      -e "s/\${VCENTER_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
      -e "s/\${ssoDomain}/$(jq -c -r .sddc.vcenter.ssoDomain ${jsonFile})/" \
      -e "s/\${ip_vcsa}/${ip_vcsa}/" \
      -e "s/\${vmSize}/$(jq -c -r .sddc.vcenter.vmSize ${jsonFile})/" \
      -e "s/\${hostSpecs}/$(echo ${hostSpecs} | jq -c -r .)/" /home/ubuntu/templates/sddc_cb_v5_trunk.json.template | tee /home/ubuntu/json/${basename_sddc}.json > /dev/null
fi
#
#
#
if [[ ${name_vcf_installer} != "null" ]]; then
  template_html_file="/home/ubuntu/templates/index-vcfi.html.template"
  sed -e "s/\${basename_sddc}/${basename_sddc}/" \
      -e "s/\${name_vcf_installer}/${name_vcf_installer}/" \
      -e "s/\${basename_avi_ctrl}/${basename_avi_ctrl}/" \
      -e "s/\${domain}/${domain}/" ${template_html_file} | tee /home/ubuntu/html/index.html > /dev/null
else
  template_html_file="/home/ubuntu/templates/index.html.template"
  sed -e "s/\${basename_sddc}/${basename_sddc}/" \
      -e "s/\${domain}/${domain}/" ${template_html_file} | tee /home/ubuntu/html/index.html > /dev/null
fi
sudo mv /home/ubuntu/html/index.html /var/www/html/index.html
sudo chown root /var/www/html/index.html
sudo chgrp root /var/www/html/index.html
sudo mv /home/ubuntu/vcf-automation/blueprint.yaml /var/www/html/blueprint.yaml
sudo chown root /var/www/html/blueprint.yaml
sudo chgrp root /var/www/html/blueprint.yaml
sudo mv /home/ubuntu/vcf-automation/blueprint-cert-manager.yaml /var/www/html/blueprint-cert-manager.yaml
sudo chown root /var/www/html/blueprint-cert-manager.yaml
sudo chgrp root /var/www/html/blueprint-cert-manager.yaml
sudo cat /var/lib/bind/db.${domain} | grep avi | sudo tee /var/www/html/avi_raw.html
while read -r line; do echo \"\$line<br>\" ; done < /var/www/html/avi_raw.html | sudo tee /var/www/html/avi.html
sudo cat /var/lib/bind/db.${domain} | grep wld | sudo tee /var/www/html/esxi_raw.html
while read -r line; do echo \"$line<br>\" ; done < /var/www/html/esxi_raw.html | sudo tee /var/www/html/esxi.html
sudo cp /home/ubuntu/json/${basename_sddc}.json /var/www/html/${basename_sddc}.json
sudo chown root /var/www/html/${basename_sddc}.json
sudo chgrp root /var/www/html/${basename_sddc}.json
if [ -z "${slack_webhook}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': Details for cloud deployment available at http://'${ip_gw}'/"}' ${slack_webhook} >/dev/null 2>&1; fi