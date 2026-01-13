#!/bin/bash
#
source /nested-vcf/bash/download_file.sh
source /nested-vcf/bash/ip.sh
source /nested-vcf/bash/log_message.sh
source /nested-vcf/bash/sddc_manager/sddc_manager_api.sh
source /nested-vcf/bash/vcenter/vcenter_api.sh
source /nested-vcf/bash/test_remote_script.sh
#
log_file=${2}
rm -f /root/govc.error
jsonFile_kube="${1}"
if [ -s "${jsonFile_kube}" ]; then
  jq . ${jsonFile_kube} > /dev/null
else
  echo "ERROR: ${jsonFile_kube} file is not present" >> ${log_file}
  exit 255
fi
jsonFile_local="/nested-vcf/json/variables.json"
basename_sddc=$(jq -c -r .sddc.basename $jsonFile_kube)
operation=$(jq -c -r .operation $jsonFile_kube)
jsonFile="/root/${basename_sddc}_${operation}.json"
jsonFile_remote="/home/ubuntu/json/${basename_sddc}_${operation}.json"
jq -s '.[0] * .[1]' ${jsonFile_kube} ${jsonFile_local} | tee ${jsonFile}
#
#
operation=$(jq -c -r .operation $jsonFile)
#
source /nested-vcf/bash/variables.sh
#
echo "Starting timestamp: $(date)" >> ${log_file}
source /nested-vcf/bash/govc/load_govc_external.sh
govc about
if [ $? -ne 0 ] ; then touch /root/govc.error ; fi
list_folder=$(govc find -json . -type f)
list_gw=$(govc find -json vm -name "${gw_name}")
#
#
# Apply use case
#
#
if [[ ${operation} == "apply" ]] ; then
  #
  if [[ ${name_vcf_installer} != "null" ]]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: creation of nested VCF v${vcf_version}" ${log_file} ${slack_webhook} ${google_webhook}
  fi
  #
  echo "Creation of a folder on the underlay infrastructure - This should take less than a minute" >> ${log_file}
  if $(echo ${list_folder} | jq -e '. | any(. == "./vm/'${folder}'")' >/dev/null ) ; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: unable to create folder ${folder}: it already exists" ${log_file} ${slack_webhook} ${google_webhook}
  else
    govc folder.create /${vsphere_dc}/vm/${folder} > /dev/null 2>&1
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vsphere external folder ${folder} created" ${log_file} ${slack_webhook} ${google_webhook}
  fi
  #
  #
  echo '------------------------------------------------------------' >> ${log_file}
  echo "Creation of an external gw on the underlay infrastructure - This should take 10 minutes" >> ${log_file}
  # ova download
  download_file_from_url_to_location "${ubuntu_ova_url}" "/root/$(basename ${ubuntu_ova_url})" "Ubuntu OVA"
  download_file_from_url_to_location "${avi_ova_url}" "/root/$(basename ${avi_ova_url})" "Avi OVA"
  download_file_from_url_to_location "${avi_ova_url_sddc_manager}" "/root/$(basename ${avi_ova_url_sddc_manager})" "Avi OVA"
  download_file_from_url_to_location "${iso_url}" "/root/$(basename ${iso_url})" "ESXi ISO" &
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Ubuntu OVA downloaded" ${log_file} ${slack_webhook} ${google_webhook}
  #
  if [[ ${list_gw} != "null" ]] ; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: unable to create VM ${gw_name}: it already exists" ${log_file} ${slack_webhook} ${google_webhook}
  else
    network_ref=$(jq -c -r .gw.network_ref $jsonFile)
    prefix=$(jq -c -r --arg arg "${network_ref}" '.vsphere_underlay.networks[] | select( .ref == $arg).cidr' $jsonFile | cut -d"/" -f2)
    default_gw=$(jq -c -r --arg arg "${network_ref}" '.vsphere_underlay.networks[] | select( .ref == $arg).gw' $jsonFile)
    ntp_masters=$(jq -c -r .gw.ntp_masters $jsonFile)
    forwarders_netplan=$(jq -c -r '.gw.dns_forwarders | join(",")' $jsonFile)
    forwarders_bind=$(jq -c -r '.gw.dns_forwarders | join(";")' $jsonFile)
    cidr=$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -d"/" -f1)
    IFS="." read -r -a octets <<< "$cidr"
    count=0
    for octet in "${octets[@]}"; do if [ $count -eq 3 ]; then break ; fi ; addr_mgmt=$octet"."$addr_mgmt ;((count++)) ; done
    reverse_mgmt=${addr_mgmt%.}
    cidr=$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -d"/" -f1)
    IFS="." read -r -a octets <<< "$cidr"
    count=0
    for octet in "${octets[@]}"; do if [ $count -eq 3 ]; then break ; fi ; addr_vm_network=$octet"."$addr_vm_network ;((count++)) ; done
    reverse_vm_network=${addr_vm_network%.}
    basename=$(jq -c -r .esxi.basename $jsonFile)
    if [[ ${esxi_trunk} == "true" ]] ; then
      template_userdata_file="userdata_external-gw-trunk.yaml.template"
    fi
    if [[ ${esxi_trunk} == "false" ]] ; then
      template_userdata_file="userdata_external-gw-multi-nic.yaml.template"
    fi
    sed -e "s/\${password}/$(jq -c -r .generic_password $jsonFile)/" \
        -e "s/\${ip_gw}/${ip_gw}/g" \
        -e "s/\${prefix}/${prefix}/" \
        -e "s/\${default_gw}/${default_gw}/" \
        -e "s/\${ntp_masters}/${ntp_masters}/" \
        -e "s/\${forwarders_netplan}/${forwarders_netplan}/" \
        -e "s/\${domain}/${domain}/g" \
        -e "s/\${reverse_mgmt}/${reverse_mgmt}/g" \
        -e "s/\${reverse_vm_network}/${reverse_vm_network}/g" \
        -e "s/\${ips_esxi}/$(echo ${ips_esxi} | jq -c -r .)/" \
        -e "s@\${name_vcf_installer}@${name_vcf_installer}@" \
        -e "s@\${name_cb}@${name_cb}@" \
        -e "s/\${packages}/$(jq -c -r '.apt_packages' $jsonFile)/" \
        -e "s@\${directories}@$(jq -c -r '.directories' $jsonFile)@" \
        -e "s@\${nsx_segments_overlay}@${nsx_segments_overlay}@" \
        -e "s@\${cidr_external_three_octets}@${cidr_external_three_octets}@" \
        -e "s@\${nsx_tier0_tier0_vip_starting_ip}@${nsx_tier0_tier0_vip_starting_ip}@" \
        -e "s@\${nsx_config_ip_blocks}@${nsx_config_ip_blocks}@" \
        -e "s@\${K8s_version_short}@${K8s_version_short}@" \
        -e "s@\${gw_vcf_cli_url}@${gw_vcf_cli_url}@g" \
        -e "s/\${basename_sddc}/${basename_sddc}/" \
        -e "s/\${basename_nsx_manager}/${basename_nsx_manager}/" \
        -e "s/\${basename_avi_ctrl}/${basename_avi_ctrl}/" \
        -e "s/\${ip_nsx_vip}/${ip_nsx_vip}/" \
        -e "s/\${ip_avi_dns}/${ip_avi_dns}/" \
        -e "s/\${avi_subdomain}/${avi_subdomain}/" \
        -e "s/\${ips_nsx}/$(echo ${ips_nsx} | jq -c -r .)/" \
        -e "s/\${ip_avi_vip}/${ip_avi_vip}/" \
        -e "s/\${ips_avi}/$(echo ${ips_avi} | jq -c -r .)/" \
        -e "s/\${ip_sddc_manager}/${ip_sddc_manager}/" \
        -e "s/\${ip_vcsa}/${ip_vcsa}/" \
        -e "s/\${pip3_packages}/$(jq -c -r '.pip3_packages' $jsonFile)/" \
        -e "s/\${ip_vcf_automation}/${ip_vcf_automation}/" \
        -e "s/\${ip_vcf_installer}/${ip_vcf_installer}/" \
        -e "s/\${ip_vcf_operation}/${ip_vcf_operation}/" \
        -e "s/\${ip_vcf_operation_fleet}/${ip_vcf_operation_fleet}/" \
        -e "s/\${ip_vcf_operation_collector}/${ip_vcf_operation_collector}/" \
        -e "s@\${networks}@${networks}@" \
        -e "s@\${ip_gw_last_octet}@${ip_gw_last_octet}@" \
        -e "s/\${forwarders_bind}/${forwarders_bind}/" \
        -e "s@\${vault_secret_file_path}@${vault_secret_file_path}@" \
        -e "s@\${vault_pki_name}@${vault_pki_name}@" \
        -e "s@\${vault_pki_max_lease_ttl}@${vault_pki_max_lease_ttl}@" \
        -e "s@\${vault_pki_cert_common_name}@${vault_pki_cert_common_name}@" \
        -e "s@\${vault_pki_cert_issuer_name}@${vault_pki_cert_issuer_name}@" \
        -e "s@\${vault_pki_cert_ttl}@${vault_pki_cert_ttl}@" \
        -e "s@\${vault_pki_cert_path}@${vault_pki_cert_path}@" \
        -e "s@\${vault_pki_role_name}@${vault_pki_role_name}@g" \
        -e "s@\${vault_pki_intermediate_name}@${vault_pki_intermediate_name}@" \
        -e "s@\${vault_pki_intermediate_max_lease_ttl}@${vault_pki_intermediate_max_lease_ttl}@" \
        -e "s@\${vault_pki_intermediate_cert_common_name}@${vault_pki_intermediate_cert_common_name}@" \
        -e "s@\${vault_pki_intermediate_cert_issuer_name}@${vault_pki_intermediate_cert_issuer_name}@" \
        -e "s@\${vault_pki_intermediate_cert_path}@${vault_pki_intermediate_cert_path}@" \
        -e "s@\${vault_pki_intermediate_cert_path_signed}@${vault_pki_intermediate_cert_path_signed}@" \
        -e "s@\${vault_pki_intermediate_role_name}@${vault_pki_intermediate_role_name}@g" \
        -e "s@\${vault_pki_intermediate_role_allow_subdomains}@${vault_pki_intermediate_role_allow_subdomains}@" \
        -e "s@\${vault_pki_intermediate_role_max_ttl}@${vault_pki_intermediate_role_max_ttl}@" \
        -e "s/\${hostname}/${gw_name}/" /nested-vcf/templates/${template_userdata_file} | tee /root/${gw_name}_userdata.yaml > /dev/null
    #
    sed -e "s#\${public_key}#$(awk '{printf "%s\\n", $0}' /root/.ssh/id_rsa.pub | awk '{length=$0; print substr($0, 1, length-2)}')#" \
        -e "s@\${base64_userdata}@$(base64 /root/${gw_name}_userdata.yaml -w 0)@" \
        -e "s/\${EXTERNAL_GW_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
        -e "s@\${network_ref}@${network_ref}@" \
        -e "s/\${gw_name}/${gw_name}/" /nested-vcf/templates/options-gw.json.template | tee "/tmp/options-${gw_name}.json" > /dev/null
    #
    govc import.ova --options="/tmp/options-${gw_name}.json" -folder "${folder}" "/root/$(basename ${ubuntu_ova_url})" > /dev/null 2>&1
    govc vm.change -vm "${folder}/${gw_name}" -c $(jq -c -r .gw.cpu $jsonFile) -m $(jq -c -r .gw.memory $jsonFile) > /dev/null 2>&1
    govc vm.disk.change -vm "${folder}/${gw_name}" -size $(jq -c -r .gw.disk $jsonFile) > /dev/null 2>&1
    if [[ ${esxi_trunk} == "true" ]] ; then
      nic_to_esxi=$(jq -c -r .esxi.nics[0] $jsonFile)
      govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3
    fi
    govc vm.power -on=true "${gw_name}" > /dev/null 2>&1
    echo "   +++ Updating /etc/hosts..." >> ${log_file}
    contents=$(cat /etc/hosts | grep -v ${ip_gw})
    echo "${contents}" | tee /etc/hosts > /dev/null
    contents="${ip_gw} gw"
    echo "${contents}" | tee -a /etc/hosts > /dev/null
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: external-gw ${gw_name} VM created" ${log_file} ${slack_webhook} ${google_webhook}
    # ssh check
    retry=60 ; pause=10 ; attempt=1
    while true ; do
      echo "attempt $attempt to verify gw ${gw_name} is ready" >> ${log_file}
      ssh -o StrictHostKeyChecking=no "ubuntu@${ip_gw}" -q >/dev/null 2>&1
      if [[ $? -eq 0 ]]; then
        echo "Gw ${gw_name} is reachable." >> ${log_file}
        ssh -o StrictHostKeyChecking=no "ubuntu@${ip_gw}" "test -f /tmp/cloudInitDone.log" 2>/dev/null
        if [[ $? -eq 0 ]]; then
          echo "Gw ${gw_name} is ready." >> ${log_file}
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: external-gw ${gw_name} VM reachable and configured" ${log_file} ${slack_webhook} ${google_webhook}
          if [[ ${esxi_trunk} == "false" ]] ; then
            count=3
            count_nic=0
            ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.old"
            ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "cat /etc/netplan/50-cloud-init.yaml.old | head -n -1 | sudo tee /etc/netplan/50-cloud-init.yaml"
            echo ${networks} | jq -c -r .[] | while read net
            do
              nic_to_esxi=$(jq -c -r .esxi.nics[${count_nic}] $jsonFile)
              govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3 > /dev/null 2>&1
              ssh -n -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "echo \"        \$(ip -o link show | awk -F': ' '{print \$2}' | head -${count} | tail -1):\" | sudo tee -a /etc/netplan/50-cloud-init.yaml"
              ssh -n -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "echo \"            dhcp4: false\" | sudo tee -a /etc/netplan/50-cloud-init.yaml"
              ssh -n -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "echo \"            addresses: [$(echo $net | jq -c -r .cidr | awk -F'0/' '{print $1}')${ip_gw_last_octet}/$(echo $net | jq -c -r .cidr | cut -f2 -d'/')]\" | sudo tee -a /etc/netplan/50-cloud-init.yaml"
              ssh -n -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "echo \"            match:\" | sudo tee -a /etc/netplan/50-cloud-init.yaml"
              ssh -n -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "echo \"                macaddress: \$(ip -o link show | awk -F'link/ether ' '{print \$2}' | awk -F' ' '{print \$1}' | head -${count} | tail -1)\" | sudo tee -a /etc/netplan/50-cloud-init.yaml"
              ssh -n -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "echo \"            set-name: \$(ip -o link show | awk -F': ' '{print \$2}' | head -${count} | tail -1)\" | sudo tee -a /etc/netplan/50-cloud-init.yaml"
              count=$((count+1))
              count_nic=$((count_nic+1))
            done
            ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "echo \"    version: 2\" | sudo tee -a /etc/netplan/50-cloud-init.yaml"
            ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo netplan apply"
          fi
          sed -e "s@\${avi_subdomain}@${avi_subdomain}@" \
              -e "s/\${domain}/${domain}/" /nested-vcf/templates/blueprint.yaml.template | tee "/nested-vcf/vcf-automation/blueprint.yaml" > /dev/null
          sed -e "s@\${avi_subdomain}@${avi_subdomain}@" \
              -e "s/\${domain}/${domain}/" /nested-vcf/templates/blueprint-cert-manager.yaml.template | tee "/nested-vcf/vcf-automation/blueprint-cert-manager.yaml" > /dev/null
          echo $folders_to_copy | jq -c -r .[] | while read folder
          do
            scp -o StrictHostKeyChecking=no -r /nested-vcf/${folder} ubuntu@${ip_gw}:/home/ubuntu
          done
          ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo mv /home/ubuntu/html/* /var/www/html/" >> ${log_file}
          ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo chown root /var/www/html/*" >> ${log_file}
          ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo chgrp root /var/www/html/*" >> ${log_file}
          scp -o StrictHostKeyChecking=no "/root/$(basename ${ubuntu_ova_url})" ubuntu@${ip_gw}:/home/ubuntu/bin/$(basename ${ubuntu_ova_url})
          scp -o StrictHostKeyChecking=no "/root/$(basename ${avi_ova_url})" ubuntu@${ip_gw}:/home/ubuntu/bin/$(basename ${avi_ova_url})
          scp -o StrictHostKeyChecking=no "/root/$(basename ${avi_ova_url_sddc_manager})" ubuntu@${ip_gw}:/home/ubuntu/sddc-manager/$(basename ${avi_ova_url_sddc_manager})
          scp -o StrictHostKeyChecking=no -r /root/${basename_sddc}_${operation}.json ubuntu@${ip_gw}:/home/ubuntu/json/${basename_sddc}_${operation}.json
          for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
          do
            ip_esxi="$(echo ${ips_esxi} | jq -r .[$(expr ${esxi} - 1)])"
            if [[ $(((${esxi}-1)/4+1)) -eq 1 ]] ; then
              name_esxi="${basename_sddc}-mgmt-esxi0${esxi}"
            fi
            if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
              name_esxi="${basename_sddc}-wld$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4))"
            fi
#            sed -e "s/\${ip_esxi}/${ip_esxi}/" \
#                -e "s/\${nested_esxi_root_password}/$(jq -c -r .generic_password $jsonFile)/" /nested-vcf/templates/esxi_cert.expect.template | tee /root/cert-esxi-$esxi.expect > /dev/null
#            scp -o StrictHostKeyChecking=no /root/cert-esxi-$esxi.expect ubuntu@${ip_gw}:/home/ubuntu/cert-esxi-$esxi.expect
            #
            sed -e "s/\${ip_esxi}/${ip_esxi}/" \
                -e "s@\${slack_webhook}@${slack_webhook}@" \
                -e "s/\${esxi}/${esxi}/" \
                -e "s/\${name_esxi}/${name_esxi}/" \
                -e "s/\${basename_sddc}/${basename_sddc}/" \
                -e "s/\${ESXI_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" /nested-vcf/templates/esxi_customization.sh.template | tee /root/esxi_customization-$esxi.sh > /dev/null
            chmod u+x /root/esxi_customization-$esxi.sh
            scp -o StrictHostKeyChecking=no /root/esxi_customization-$esxi.sh ubuntu@${ip_gw}:/home/ubuntu/esxi/esxi_customization-$esxi.sh
          done
          break
        else
          echo "Gw ${gw_name}: cloud init is not finished." >> ${log_file}
        fi
      fi
      ((attempt++))
      if [ $attempt -eq $retry ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Gw ${gw_name} is unreachable after $attempt attempt" ${log_file} ${slack_webhook} ${google_webhook}
        exit
      fi
      sleep $pause
    done
  fi
  affinity_members="${gw_name}"
  #
  #
  echo '------------------------------------------------------------' >> ${log_file}
  echo "Creation of an ESXi hosts on the underlay infrastructure - This should take 10 minutes" >> ${log_file}
  wait
  if [[ ${cloud_builder_ova_url} != "null" ]]; then
    download_file_from_url_to_location "${cloud_builder_ova_url}" "/root/$(basename ${cloud_builder_ova_url})" "VFC-Cloud_Builder OVA" &
  fi
  if [[ ${vcf_installer_ova_url} != "null" ]]; then
    download_file_from_url_to_location "${vcf_installer_ova_url}" "/root/$(basename ${vcf_installer_ova_url})" "VFC Installer OVA" &
  fi
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ISO ESXI downloaded" ${log_file} ${slack_webhook} ${google_webhook}
  #
  iso_mount_location="/tmp/esxi_cdrom_mount"
  iso_build_location="/tmp/esxi_cdrom"
  boot_cfg_location="efi/boot/boot.cfg"
  iso_location="/tmp/esxi"
  xorriso -ecma119_map lowercase -osirrox on -indev "/root/$(basename ${iso_url})" -extract / ${iso_mount_location}
  echo "Copying source ESXi ISO to Build directory" >> ${log_file}
  rm -fr ${iso_build_location}
  mkdir -p ${iso_build_location}
  cp -r ${iso_mount_location}/* ${iso_build_location}
  rm -fr ${iso_mount_location}
  echo "Modifying ${iso_build_location}/${boot_cfg_location}" >> ${log_file}
  echo "kernelopt=runweasel ks=cdrom:/KS_CUST.CFG" | tee -a ${iso_build_location}/${boot_cfg_location}
  #
  for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
  do
    if [[ $(((${esxi}-1)/4+1)) -eq 1 ]] ; then
      name_esxi="${basename_sddc}-mgmt-esxi0${esxi}"
    fi
    if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
      name_esxi="${basename_sddc}-wld0$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4))"
    fi
    if [[ $(govc find -json vm | jq '[.[] | select(. == "vm/'${folder}'/'${name_esxi}'")] | length') -eq 1 ]]; then
      echo "ERROR: unable to create nested ESXi ${name_esxi}: it already exists" >> ${log_file}
      exit
    else
      net=$(jq -c -r .esxi.nics[0] $jsonFile)
      ip_esxi="$(echo ${ips_esxi} | jq -r .[$(expr ${esxi} - 1)])"
      hostSpec='{"association":"'${folder}'-dc","ipAddressPrivate":{"ipAddress":"'${ip_esxi}'"},"hostname":"'${name_esxi}'","credentials":{"username":"root","password":"'$(jq -c -r .generic_password $jsonFile)'"},"vSwitch":"vSwitch0"}'
      hostSpecs=$(echo ${hostSpecs} | jq '. += ['${hostSpec}']')
      rm -f ${iso_build_location}/ks_cust.cfg
      rm -f "${iso_location}-${esxi}.iso"
      if [[ ${esxi_trunk} == "true" ]] ; then
        sed -e "s/\${nested_esxi_root_password}/$(jq -c -r .generic_password $jsonFile)/" \
            -e "s/\${ip_mgmt}/${ip_esxi}/" \
            -e "s/\${netmask}/$(ip_netmask_by_prefix $(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -d"/" -f2) "   ++++++")/" \
            -e "s/\${vlan_id}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)/" \
            -e "s/\${dns_servers}/${ip_gw}/" \
            -e "s/\${ntp_servers}/${ip_gw}/" \
            -e "s/\${hostname}/${name_esxi}/" \
            -e "s/\${domain}/${domain}/" \
            -e "s/\${gateway}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" /nested-vcf/templates/ks_cust-trunk.cfg.template | tee ${iso_build_location}/ks_cust.cfg > /dev/null
      fi
      if [[ ${esxi_trunk} == "false" ]] ; then
        sed -e "s/\${nested_esxi_root_password}/$(jq -c -r .generic_password $jsonFile)/" \
            -e "s/\${ip_mgmt}/${ip_esxi}/" \
            -e "s/\${netmask}/$(ip_netmask_by_prefix $(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -d"/" -f2) "   ++++++")/" \
            -e "s/\${dns_servers}/${ip_gw}/" \
            -e "s/\${ntp_servers}/${ip_gw}/" \
            -e "s/\${hostname}/${name_esxi}/" \
            -e "s/\${domain}/${domain}/" \
            -e "s/\${gateway}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" /nested-vcf/templates/ks_cust-multi-nic.cfg.template | tee ${iso_build_location}/ks_cust.cfg > /dev/null
      fi
      echo "Building new ISO for ESXi ${esxi}" >> ${log_file}
      xorrisofs -relaxed-filenames -J -R -o "${iso_location}-${esxi}.iso" -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e efiboot.img -no-emul-boot ${iso_build_location}
      ds=$(jq -c -r .vsphere_underlay.datastore $jsonFile)
      dc=$(jq -c -r .vsphere_underlay.datacenter $jsonFile)
      echo "Uploading new ISO for ESXi ${esxi}" >> ${log_file}
      govc datastore.upload  --ds=${ds} --dc=${dc} "${iso_location}-${esxi}.iso" nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null 2>&1
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ISO ESXi ${esxi} uploaded" ${log_file} ${slack_webhook} ${google_webhook}
      if [[ ${esxi} -gt 4 ]] ; then
        cpu=$(jq -c -r .esxi.sizing_workload.cpu $jsonFile)
        memory=$(jq -c -r .esxi.sizing_workload.memory $jsonFile)
        disk_os_size=$(jq -c -r .esxi.sizing_workload.disk_os_size $jsonFile)
        disk_flash_size=$(jq -c -r .esxi.sizing_workload.disk_flash_size $jsonFile)
        disk_capacity_size=$(jq -c -r .esxi.sizing_workload.disk_capacity_size $jsonFile)
      else
        cpu=$(jq -c -r .esxi.sizing_mgmt.cpu $jsonFile)
        memory=$(jq -c -r .esxi.sizing_mgmt.memory $jsonFile)
        disk_os_size=$(jq -c -r .esxi.sizing_mgmt.disk_os_size $jsonFile)
        disk_flash_size=$(jq -c -r .esxi.sizing_mgmt.disk_flash_size $jsonFile)
        disk_capacity_size=$(jq -c -r .esxi.sizing_mgmt.disk_capacity_size $jsonFile)
      fi
      affinity_members="${affinity_members} ${name_esxi}"
      echo "Creating nested ESXi ${esxi}" >> ${log_file}
      govc vm.create -c ${cpu} -m ${memory} -disk ${disk_os_size} -disk.controller pvscsi -net ${net} -g vmkernel65Guest -net.adapter vmxnet3 -firmware efi -folder "${folder}" -on=false "${name_esxi}" > /dev/null 2>&1
      #govc device.cdrom.add -vm "${folder}/${name_esxi}" > /dev/null
      # adding a SATA controller
      token=$(/bin/bash /nested-vcf/bash/vcenter/create_vcenter_api_session.sh "${GOVC_USERNAME}" "" "${GOVC_PASSWORD}" "$(basename ${GOVC_URL})")
      vcenter_api 2 2 "GET" $token "" "$(basename ${GOVC_URL})" "api/vcenter/vm"
#      echo ${response_body} | jq . >> ${log_file}
      esxi_nested_vm_id=$(echo ${response_body} | jq -c -r --arg arg "${name_esxi}" '.[] | select(.name == $arg).vm')
#      echo "${esxi_nested_vm_id}" >> ${log_file}
      json_data='{"type": "AHCI"}'
      vcenter_api 2 2 "POST" $token "${json_data}" "$(basename ${GOVC_URL})" "api/vcenter/vm/${esxi_nested_vm_id}/hardware/adapter/sata"
      # adding a cdrom based on sata
      json_data='{"type": "SATA", "start_connected": true, "backing": {"iso_file": "['${GOVC_DATASTORE}'] 'nested-vcf/$(basename ${iso_location}-${esxi}.iso)'","type": "ISO_FILE"}}'
      vcenter_api 2 2 "POST" $token "${json_data}" "$(basename ${GOVC_URL})" "api/vcenter/vm/${esxi_nested_vm_id}/hardware/cdrom"
#      govc device.cdrom.insert -vm "${folder}/${name_esxi}" -device cdrom-3000 nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
      govc vm.change -vm "${folder}/${name_esxi}" -nested-hv-enabled > /dev/null 2>&1
      govc vm.disk.create -vm "${folder}/${name_esxi}" -name ${name_esxi}/disk1 -size ${disk_flash_size} > /dev/null 2>&1
      govc vm.disk.create -vm "${folder}/${name_esxi}" -name ${name_esxi}/disk2 -size ${disk_capacity_size} > /dev/null 2>&1
      if [[ ${esxi_trunk} == "true" ]] ; then
        net=$(jq -c -r .esxi.nics[1] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
      fi
      if [[ ${esxi_trunk} == "false" ]] ; then
        net=$(jq -c -r .esxi.nics[0] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
        net=$(jq -c -r .esxi.nics[1] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
        net=$(jq -c -r .esxi.nics[2] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
        net=$(jq -c -r .esxi.nics[3] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
        net=$(jq -c -r .esxi.nics[4] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
        net=$(jq -c -r .esxi.nics[5] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null 2>&1
      fi
      govc vm.power -on=true "${folder}/${name_esxi}" > /dev/null 2>&1
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: nested ESXi ${esxi} created" ${log_file} ${slack_webhook} ${google_webhook} &
    fi
  done
  # affinity rule
  if [[ $(jq -c -r .vsphere_underlay.affinity $jsonFile) == "true" ]] ; then
    echo '------------------------------------------------------------' >> ${log_file}
    govc cluster.rule.create -name "${folder}-affinity-rule" -enable -affinity ${affinity_members}
    echo "Affinity rules should have been configured: ${folder}-affinity-rule" >> ${log_file}
  fi
  #
  # json file creation
  #
  script_file="/home/ubuntu/bash/json_builder.sh"
  echo "running the following command from the gw: ${script_file} /home/ubuntu/json/${basename_sddc}_${operation}.json" >> ${log_file} 2>&1
  ssh -o StrictHostKeyChecking=no ubuntu@${ip_gw} "${script_file} /home/ubuntu/json/${basename_sddc}_${operation}.json" >> ${log_file}
  #
  # VCF Installer or Cloud Builder Deployment
  #
  wait
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Creation of a cloud builder or VCF Installer VM underlay infrastructure - This should take 10 minutes" | tee -a ${log_file}
  #
  if [[ ${cloud_builder_ova_url} != "null" ]]; then
    echo "Cloud Builder OVA downloaded" | tee -a ${log_file}
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Cloud Builder OVA downloaded" ${log_file} ${slack_webhook} ${google_webhook}
  fi
  if [[ ${vcf_installer_ova_url} != "null" ]]; then
    echo "VCF Installer OVA downloaded" | tee -a ${log_file}
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF Installer OVA downloaded" ${log_file} ${slack_webhook} ${google_webhook}
  fi
  #
  # Cloud builder use case
  #
  if [[ ${name_cb} != "null" ]]; then
    if [[ $(govc find -json vm | jq '[.[] | select(. == "vm/'${folder}'/'${name_cb}'")] | length') -eq 1 ]]; then
      echo "cloud Builder VM already exists" | tee -a ${log_file}
      exit
    else
      sed -e "s/\${CLOUD_BUILDER_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
          -e "s/\${name_cb}/${name_cb}/" \
          -e "s/\${ip_cb}/${ip_cb}/" \
          -e "s/\${netmask}/$(ip_netmask_by_prefix $(jq -c -r --arg arg "${cloud_builder_network_ref}" '.vsphere_underlay.networks[] | select( .ref == $arg).cidr' $jsonFile | cut -d"/" -f2) "   ++++++")/" \
          -e "s/\${ip_gw}/${ip_gw}/" \
          -e "s@\${network_ref}@${cloud_builder_network_ref}@" /nested-vcf/templates/options-cb.json.template | tee "/tmp/options-${name_cb}.json"
      #
      echo "Uploading Cloud Builder OVA" | tee -a ${log_file}
      govc import.ova --options="/tmp/options-${name_cb}.json" -folder "${folder}" "/root/$(basename ${cloud_builder_ova_url})" >/dev/null
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-Cloud_Builder VM created" ${log_file} ${slack_webhook} ${google_webhook}
      echo "Creating Cloud Builder VM" | tee -a ${log_file}
      govc vm.power -on=true "${name_cb}"
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-Cloud_Builder VM started" ${log_file} ${slack_webhook} ${google_webhook}
      count=1
      until $(curl --output /dev/null --silent --head -k https://${ip_cb})
      do
        echo "Attempt ${count}: Waiting for Cloud Builder VM at https://${ip_cb} to be reachable..." | tee -a ${log_file}
        sleep 30
        count=$((count+1))
        if [[ "${count}" -eq 30 ]]; then
          echo "ERROR: Unable to connect to Cloud Builder VM at https://${ip_cb} to be reachable after ${count} Attempts" | tee -a ${log_file}
          exit 1
        fi
      done
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: nested Cloud Builder VM configured and reachable" ${log_file} ${slack_webhook} ${google_webhook}
    fi
  fi
  #
  # VCF installer use case
  #
  if [[ ${name_vcf_installer} != "null" ]]; then
    if [[ $(govc find -json vm | jq '[.[] | select(. == "vm/'${folder}'/'${name_vcf_installer}'")] | length') -eq 1 ]]; then
      echo "VCF installer VM already exists" | tee -a ${log_file}
      exit
    else
      sed -e "s/\${VCF_INSTALLER_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
          -e "s/\${name_vcf_installer}/${name_vcf_installer}/" \
          -e "s/\${ip_vcf_installer}/${ip_vcf_installer}/" \
          -e "s/\${domain}/${domain}/" \
          -e "s/\${netmask}/$(ip_netmask_by_prefix $(jq -c -r --arg arg "${vcf_installer_network_ref}" '.vsphere_underlay.networks[] | select( .ref == $arg).cidr' $jsonFile | cut -d"/" -f2) "   ++++++")/" \
          -e "s/\${ip_gw}/${ip_gw}/" \
          -e "s@\${network_ref}@${vcf_installer_network_ref}@" /nested-vcf/templates/options-vcf-i.json.template | tee "/tmp/options-${name_vcf_installer}.json"
      #
      echo "Uploading VCF Installer OVA" | tee -a ${log_file}
      govc import.ova --options="/tmp/options-${name_vcf_installer}.json" -folder "${folder}" "/root/$(basename ${vcf_installer_ova_url})" >/dev/null
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF installer VM created" ${log_file} ${slack_webhook} ${google_webhook}
      echo "Creating VCF Installer VM" | tee -a ${log_file}
      govc vm.power -on=true "${name_vcf_installer}"
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF installer VM started" ${log_file} ${slack_webhook} ${google_webhook}
      count=1
      until $(curl --output /dev/null --silent --head -k https://${ip_vcf_installer})
      do
        echo "Attempt ${count}: Waiting for VCF installer VM at https://${ip_vcf_installer} to be reachable..." | tee -a ${log_file}
        sleep 30
        count=$((count+1))
        if [[ "${count}" -eq 30 ]]; then
          echo "ERROR: Unable to connect to VCF installer VM at https://${ip_vcf_installer} to be reachable after ${count} Attempts" | tee -a ${log_file}
          exit 1
        fi
      done
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF installer VM configured and reachable" ${log_file} ${slack_webhook} ${google_webhook}
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF installer VM: please patch it: ssh vcf@${ip_vcf_installer}" ${log_file} ${slack_webhook} ${google_webhook}
    fi
  fi
  #
  # ESX customization
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "ESXI customization  - This should take 2 minutes per nested ESXi" | tee -a ${log_file}
  for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
  do
    if [[ $(((${esxi}-1)/4+1)) -eq 1 ]] ; then
      name_esxi="${basename_sddc}-mgmt-esxi0${esxi}"
    fi
    if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
      name_esxi="${basename_sddc}-wld0$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4))"
    fi
    govc vm.power -s ${name_esxi}
    sleep 30
    govc vm.power -on ${name_esxi}
    script_file="/home/ubuntu/esxi/esxi_customization-$esxi.sh"
    test_remote_script_retry=15
    test_remote_script_pause=20
    log_message "running the following command from the gw: ${script_file}" ${log_file} ${slack_webhook} ${google_webhook}
    ssh -o StrictHostKeyChecking=no ubuntu@${ip_gw} "${script_file}" >> ${log_file} 2>&1 &
    test_remote_script ${log_file} ${test_remote_script_retry} ${test_remote_script_pause} "${ip_gw}" "${script_file}"
    if [ $? -eq 100 ]; then
      log_message "ERROR while running the following command from the gw: ${script_file} ${script_file%.*}.done after ${test_remote_script_retry} retries of ${test_remote_script_pause} seconds" ${log_file} ${slack_webhook} ${google_webhook}
    fi
#    ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "/bin/bash /home/ubuntu/esxi/esxi_customization-$esxi.sh"
    govc device.cdrom.eject -vm "${folder}/${name_esxi}" -device cdrom-3000 nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
    sleep 10
    govc device.cdrom.eject -vm "${folder}/${name_esxi}" -device cdrom-3000 nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
    govc datastore.rm nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: nested ESXi ${name_esxi} ready" ${log_file} ${slack_webhook} ${google_webhook}
  done
  govc datastore.rm nested-vcf
  #
  # VCF 9 - vcf_installer use case
  #
  if [[ ${name_vcf_installer} != "null" ]]; then
    echo '------------------------------------------------------------' | tee -a ${log_file}
    echo "VCF Installer configuration" | tee -a ${log_file}
    while [ ! -f "/root/vcfi-${ip_vcf_installer}-patched.json" ]; do
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: please patch vcf installer" ${log_file} ${slack_webhook} ${google_webhook}
        sleep 30
    done
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF installer VM patched" ${log_file} ${slack_webhook} ${google_webhook}
    #
    # Configuring VCF 9 deployment
    #
    while read item
    do
      script_file="$(echo ${item} | jq -c -r '.script_file')"
      test_remote_script_retry=$(echo ${item} | jq -c -r '.test_remote_script_retry')
      test_remote_script_pause=$(echo ${item} | jq -c -r '.test_remote_script_pause')
      log_message "running the following command from the gw: ${script_file} ${jsonFile_remote}" ${log_file} ${slack_webhook} ${google_webhook}
      ssh -o StrictHostKeyChecking=no ubuntu@${ip_gw} "${script_file} ${jsonFile_remote}" < /dev/null 2>/dev/null &
      test_remote_script ${log_file} ${test_remote_script_retry} ${test_remote_script_pause} "${ip_gw}" "${script_file}"
      if [ $? -eq 100 ]; then
        log_message "ERROR while running the following command from the gw: ${script_file} ${jsonFile_remote} after ${test_remote_script_retry} retries of ${test_remote_script_pause} seconds" ${log_file} ${slack_webhook} ${google_webhook}
      fi
    done < <(echo "${vcfi_scripts}" | jq -c -r .[])
  fi
  #
  # VCF - cloud builder use case
  #
  if [[ ${name_cb} != "null" ]]; then
    echo '------------------------------------------------------------' | tee -a ${log_file}
    echo "SDDC creation - This should take hours..." | tee -a ${log_file}
    if [[ $(jq -c -r .sddc.create_mgmt $jsonFile) == "true" ]] ; then
      validation_id=$(curl -s -k "https://${ip_cb}/v1/sddcs/validations" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d @/root/${basename_sddc}.json | jq -c -r .id)
      # validation json
      retry=60 ; pause=10 ; attempt=1
      while true ; do
        echo "attempt $attempt to verify SDDC JSON validation" | tee -a ${log_file}
        executionStatus=$(curl -k -s "https://${ip_cb}/v1/sddcs/validations/${validation_id}" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X GET -H 'Accept: application/json' | jq -c -r .executionStatus)
        if [[ ${executionStatus} == "COMPLETED" ]]; then
          resultStatus=$(curl -k -s "https://${ip_cb}/v1/sddcs/validations/${validation_id}" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X GET -H 'Accept: application/json' | jq -c -r .resultStatus)
          echo "SDDC JSON validation: ${resultStatus} after $attempt of ${pause} seconds"
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC JSON validation: ${resultStatus}" ${log_file} ${slack_webhook} ${google_webhook}
          if [[ ${resultStatus} != "SUCCEEDED" ]] ; then exit ; fi
          break
        else
          sleep $pause
        fi
        ((attempt++))
        if [ $attempt -eq $retry ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC JSON validation not finished after ${attempt} attempts of ${pause} seconds" ${log_file} ${slack_webhook} ${google_webhook}
          exit
        fi
      done
      sddc_id=$(curl -s -k "https://${ip_cb}/v1/sddcs" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d @/root/${basename_sddc}.json | jq -c -r .id)
      # validation_sddc creation
      echo "SDDC ${sddc_id} trying ${count_retry} times to apply" | tee -a ${log_file}
      retry=120 ; pause=300 ; attempt=1 ; count_retry=1
      while true ; do
        echo "attempt $attempt to verify SDDC ${sddc_id} creation"
        sddc_status=$(curl -k -s "https://${ip_cb}/v1/sddcs/${sddc_id}" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X GET -H 'Accept: application/json' | jq -c -r .status)
        if [[ ${sddc_status} != "IN_PROGRESS" ]]; then
          echo "SDDC ${sddc_id} creation ${sddc_status} after attempt $attempt of ${pause} seconds, go to https://${ip_cb}"
          if [[ ${sddc_status} != "COMPLETED_WITH_SUCCESS" ]]; then
            ((count_retry++))
            if [[ ${count_retry} == 3 ]]; then
              log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC ${sddc_id} Creation status: ${sddc_status}, go to https://${ip_cb}" ${log_file} ${slack_webhook} ${google_webhook}
              exit
            fi
            sleep 600
            echo "SDDC ${sddc_id} trying ${count_retry} times to apply after status ${sddc_status}" | tee -a ${log_file}
            retry=$(curl -k -s "https://${ip_cb}/v1/sddcs/${sddc_id}" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X PATCH -H 'Content-type: application/json' -d @/root/${basename_sddc}.json)
          fi
          if [[ ${sddc_status} == "COMPLETED_WITH_SUCCESS" ]]; then
            log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC ${sddc_id} Creation status: ${sddc_status}, go to https://${ip_cb}" ${log_file} ${slack_webhook} ${google_webhook}
            break
          fi
        else
          sleep $pause
        fi
        ((attempt++))
        if [ $attempt -eq $retry ]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC ${sddc_id} Creation not finished after ${attempt} attempts of ${pause} seconds" ${log_file} ${slack_webhook} ${google_webhook}
          exit
        fi
      done
    fi
    echo '------------------------------------------------------------' | tee -a ${log_file}
    echo "ESXi host commissioning - This should take minutes..." | tee -a ${log_file}
    if [[ $(jq -c -r .sddc.create_wld $jsonFile) == "true" ]] ; then
      for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
      do
        if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
          esxi_fqdn="${basename_sddc}-wld0$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4)).${domain}"
          ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "/home/ubuntu/sddc_manager/sddc_manager_commission_host.sh /home/ubuntu/json/$(basename ${jsonFile}) ${esxi_fqdn}" > ${log_file} 2>&1
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC ${sddc_id} ESXi host commissioning of ESXi host: ${esxi_fqdn}" ${log_file} ${slack_webhook} ${google_webhook}
        fi
      done
    fi
    sleep 120
    govc vm.power -off=true "${name_cb}" >> /dev/null 2>&1
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Powering off Cloud Builder VM" ${log_file} ${slack_webhook} ${google_webhook}
  fi
fi
#
#
# destroy use case
#
#
if [[ ${operation} == "destroy" ]] ; then
  if [[ ${name_cb} != "null" ]]; then
    echo '------------------------------------------------------------' | tee -a ${log_file}
    if [[ $(govc find -json vm | jq '[.[] | select(. == "vm/'${folder}'/'${name_cb}'")] | length') -eq 1 ]]; then
      govc vm.power -off=true "${folder}/${name_cb}"
      govc vm.destroy "${folder}/${name_cb}"
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-Cloud_Builder VM powered off and destroyed" ${log_file} ${slack_webhook} ${google_webhook}
    fi
  fi
  #
  #
  if [[ ${name_vcf_installer} != "null" ]]; then
    echo '------------------------------------------------------------'
    if [[ $(govc find -json vm | jq '[.[] | select(. == "vm/'${folder}'/'${name_vcf_installer}'")] | length') -eq 1 ]]; then
      govc vm.power -off=true "${folder}/${name_vcf_installer}"
      govc vm.destroy "${folder}/${name_vcf_installer}"
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-installer VM powered off and destroyed" ${log_file} ${slack_webhook} ${google_webhook}
    fi
  fi
  #
  #
  echo '------------------------------------------------------------'
  for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
  do
    if [[ $(((${esxi}-1)/4+1)) -eq 1 ]] ; then
      name_esxi="${basename_sddc}-mgmt-esxi0${esxi}"
    fi
    if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
      name_esxi="${basename_sddc}-wld0$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4))"
    fi
    echo "Deletion of a nested ESXi ${name_esxi} on the underlay infrastructure - This should take less than a minute" | tee -a ${log_file}
    if [[ $(govc find -json vm | jq '[.[] | select(. == "vm/'${folder}'/'${name_esxi}'")] | length') -eq 1 ]]; then
      govc vm.power -off=true "${folder}/${name_esxi}"
      govc vm.destroy "${folder}/${name_esxi}"
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: nested ESXi ${esxi} destroyed" ${log_file} ${slack_webhook} ${google_webhook}
    else
      echo "ERROR: unable to delete ESXi ${name_esxi}: it is already gone" | tee -a ${log_file}
    fi
  done
  #
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Deletion of a VM on the underlay infrastructure - This should take less than a minute" | tee -a ${log_file}
  if [[ ${list_gw} != "null" ]] ; then
    govc vm.power -off=true "${gw_name}"
    govc vm.destroy "${gw_name}"
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: external-gw ${gw_name} VM powered off and destroyed" ${log_file} ${slack_webhook} ${google_webhook}
  else
    echo "ERROR: unable to delete VM ${gw_name}: it already exists" | tee -a ${log_file}
  fi
  govc cluster.rule.remove -name "${folder}-affinity-rule"
  #
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Deletion of a folder on the underlay infrastructure - This should take less than a minute" | tee -a ${log_file}
  if $(echo ${list_folder} | jq -e '. | any(. == "./vm/'${folder}'")' >/dev/null ) ; then
    govc object.destroy /${vsphere_dc}/vm/${folder}
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vsphere external folder ${folder} removed" ${log_file} ${slack_webhook} ${google_webhook}
  else
    echo "ERROR: unable to delete folder ${folder}: it does not exist" | tee -a ${log_file}
  fi
fi
#
echo "Ending timestamp: $(date)" | tee -a ${log_file}
echo '------------------------------------------------------------' | tee -a ${log_file}