#!/bin/bash
#
source /nested-vcf/bash/download_file.sh
source /nested-vcf/bash/ip.sh
rm -f /root/govc.error
jsonFile_kube="${1}"
if [ -s "${jsonFile_kube}" ]; then
  jq . ${jsonFile_kube} > /dev/null
else
  echo "ERROR: ${jsonFile_kube} file is not present"
  exit 255
fi
jsonFile_local="/nested-vcf/json/variables.json"
basename_sddc=$(jq -c -r .sddc.basename $jsonFile_kube)
operation=$(jq -c -r .operation $jsonFile_kube)
jsonFile="/root/${basename_sddc}_${operation}.json"
jq -s '.[0] * .[1]' ${jsonFile_kube} ${jsonFile_local} | tee ${jsonFile}
#
#
operation=$(jq -c -r .operation $jsonFile)
#
if [[ ${operation} == "apply" ]] ; then log_file="/nested-vcf/log/$(basename "$0" | cut -f1 -d'.')_${operation}.stdout" ; fi
if [[ ${operation} == "destroy" ]] ; then log_file="/nested-vcf/log/$(basename "$0" | cut -f1 -d'.')_${operation}.stdout" ; fi
if [[ ${operation} != "apply" && ${operation} != "destroy" ]] ; then echo "ERROR: Unsupported operation" ; exit 255 ; fi
#
rm -f ${log_file}
#
source /nested-vcf/bash/variables.sh
#
echo "Starting timestamp: $(date)" | tee -a ${log_file}
source /nested-vcf/bash/govc/load_govc_external.sh
govc about
if [ $? -ne 0 ] ; then touch /root/govc.error ; fi
list_folder=$(govc find -json . -type f)
list_gw=$(govc find -json vm -name "${gw_name}")
#
echo '------------------------------------------------------------' | tee ${log_file}
if [[ ${operation} == "apply" ]] ; then
  echo "Creation of a folder on the underlay infrastructure - This should take less than a minute" | tee -a ${log_file}
  if $(echo ${list_folder} | jq -e '. | any(. == "./vm/'${folder}'")' >/dev/null ) ; then
    echo "ERROR: unable to create folder ${folder}: it already exists" | tee -a ${log_file}
  else
    govc folder.create /${vsphere_dc}/vm/${folder} | tee -a ${log_file}
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': vsphere external folder '${folder}' created"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  fi
  #
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Creation of an external gw on the underlay infrastructure - This should take 10 minutes" | tee -a ${log_file}
  # ova download
  ova_url=$(jq -c -r .gw.ova_url $jsonFile)
  download_file_from_url_to_location "${ova_url}" "/root/$(basename ${ova_url})" "Ubuntu OVA"
  if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': Ubuntu OVA downloaded"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  #
  if [[ ${list_gw} != "null" ]] ; then
    echo "ERROR: unable to create VM ${gw_name}: it already exists" | tee -a ${log_file}
  else
    network_ref=$(jq -c -r .gw.network_ref $jsonFile)
    prefix=$(jq -c -r --arg arg "${network_ref}" '.vsphere_underlay.networks[] | select( .ref == $arg).cidr' $jsonFile | cut -d"/" -f2)
    default_gw=$(jq -c -r --arg arg "${network_ref}" '.vsphere_underlay.networks[] | select( .ref == $arg).gw' $jsonFile)
    ntp_masters=$(jq -c -r .gw.ntp_masters $jsonFile)
    forwarders_netplan=$(jq -c -r '.gw.dns_forwarders | join(",")' $jsonFile)
    forwarders_bind=$(jq -c -r '.gw.dns_forwarders | join(";")' $jsonFile)
    networks=$(jq -c -r .sddc.vcenter.networks $jsonFile)
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
        -e "s/\${ip_gw}/${ip_gw}/" \
        -e "s/\${prefix}/${prefix}/" \
        -e "s/\${default_gw}/${default_gw}/" \
        -e "s/\${ntp_masters}/${ntp_masters}/" \
        -e "s/\${forwarders_netplan}/${forwarders_netplan}/" \
        -e "s/\${domain}/${domain}/g" \
        -e "s/\${reverse_mgmt}/${reverse_mgmt}/g" \
        -e "s/\${reverse_vm_network}/${reverse_vm_network}/g" \
        -e "s/\${ips_esxi}/$(echo ${ips_esxi} | jq -c -r .)/" \
        -e "s@\${directories}@$(jq -c -r '.directories' $jsonFile)@" \
        -e "s/\${packages}/$(jq -c -r '.apt_packages' $jsonFile)/" \
        -e "s/\${basename_sddc}/${basename_sddc}/" \
        -e "s/\${basename_nsx_manager}/${basename_nsx_manager}/" \
        -e "s/\${basename_avi_ctrl}/${basename_avi_ctrl}/" \
        -e "s/\${ip_nsx_vip}/${ip_nsx_vip}/" \
        -e "s/\${ips_nsx}/$(echo ${ips_nsx} | jq -c -r .)/" \
        -e "s/\${ip_avi_vip}/${ip_avi_vip}/" \
        -e "s/\${ips_avi}/$(echo ${ips_avi} | jq -c -r .)/" \
        -e "s/\${ip_sddc_manager}/${ip_sddc_manager}/" \
        -e "s/\${ip_vcsa}/${ip_vcsa}/" \
        -e "s@\${networks}@${networks}@" \
        -e "s@\${ip_gw_last_octet}@${ip_gw_last_octet}@" \
        -e "s/\${forwarders_bind}/${forwarders_bind}/" \
        -e "s/\${hostname}/${gw_name}/" /nested-vcf/templates/${template_userdata_file} | tee /root/${gw_name}_userdata.yaml > /dev/null
    #
    sed -e "s#\${public_key}#$(awk '{printf "%s\\n", $0}' /root/.ssh/id_rsa.pub | awk '{length=$0; print substr($0, 1, length-2)}')#" \
        -e "s@\${base64_userdata}@$(base64 /root/${gw_name}_userdata.yaml -w 0)@" \
        -e "s/\${EXTERNAL_GW_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
        -e "s@\${network_ref}@${network_ref}@" \
        -e "s/\${gw_name}/${gw_name}/" /nested-vcf/templates/options-gw.json.template | tee "/tmp/options-${gw_name}.json"
    #
    govc import.ova --options="/tmp/options-${gw_name}.json" -folder "${folder}" "/root/$(basename ${ova_url})" | tee -a ${log_file}
    govc vm.change -vm "${folder}/${gw_name}" -c $(jq -c -r .gw.cpu $jsonFile) -m $(jq -c -r .gw.memory $jsonFile)
    govc vm.disk.change -vm "${folder}/${gw_name}" -size $(jq -c -r .gw.disk $jsonFile)
    if [[ ${esxi_trunk} == "true" ]] ; then
      nic_to_esxi=$(jq -c -r .esxi.nics[0] $jsonFile)
      govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3 | tee -a ${log_file}
    fi
    if [[ ${esxi_trunk} == "false" ]] ; then
      nic_to_esxi=$(jq -c -r .esxi.nics[0] $jsonFile)
      govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3 | tee -a ${log_file}
      nic_to_esxi=$(jq -c -r .esxi.nics[1] $jsonFile)
      govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3 | tee -a ${log_file}
      nic_to_esxi=$(jq -c -r .esxi.nics[2] $jsonFile)
      govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3 | tee -a ${log_file}
      nic_to_esxi=$(jq -c -r .esxi.nics[3] $jsonFile)
      govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3 | tee -a ${log_file}
      nic_to_esxi=$(jq -c -r .esxi.nics[4] $jsonFile)
      govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3 | tee -a ${log_file}
      nic_to_esxi=$(jq -c -r .esxi.nics[5] $jsonFile)
      govc vm.network.add -vm "${folder}/${gw_name}" -net "${nic_to_esxi}" -net.adapter vmxnet3 | tee -a ${log_file}
    fi
    govc vm.power -on=true "${gw_name}" | tee -a ${log_file}
    echo "   +++ Updating /etc/hosts..." | tee -a ${log_file}
    contents=$(cat /etc/hosts | grep -v ${ip_gw})
    echo "${contents}" | tee /etc/hosts > /dev/null
    contents="${ip_gw} gw"
    echo "${contents}" | tee -a /etc/hosts > /dev/null
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': external-gw '${gw_name}' VM created"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
    # ssh check
    retry=60 ; pause=10 ; attempt=1
    while true ; do
      echo "attempt $attempt to verify gw ${gw_name} is ready" | tee -a ${log_file}
      ssh -o StrictHostKeyChecking=no "ubuntu@${ip_gw}" -q >/dev/null 2>&1
      if [[ $? -eq 0 ]]; then
        echo "Gw ${gw_name} is reachable."
        #if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': external-gw '${gw_name}' VM reachable"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
        ssh -o StrictHostKeyChecking=no "ubuntu@${ip_gw}" "test -f /tmp/cloudInitDone.log" 2>/dev/null
        if [[ $? -eq 0 ]]; then
          echo "Gw ${gw_name} is ready." | tee -a ${log_file}
          if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': external-gw '${gw_name}' VM reachable and configured"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
          scp -o StrictHostKeyChecking=no /nested-vcf/bash/sddc_manager/create_api_session.sh ubuntu@${ip_gw}:/home/ubuntu/sddc_manager/create_api_session.sh
          scp -o StrictHostKeyChecking=no /nested-vcf/bash/sddc_manager/sddc_manager_api.sh ubuntu@${ip_gw}:/home/ubuntu/sddc_manager/sddc_manager_api.sh
          scp -o StrictHostKeyChecking=no /nested-vcf/bash/sddc_manager/sddc_manager_depot.sh ubuntu@${ip_gw}:/home/ubuntu/sddc_manager/sddc_manager_depot.sh
          scp -o StrictHostKeyChecking=no /nested-vcf/bash/sddc_manager/sddc_manager_commission_host.sh ubuntu@${ip_gw}:/home/ubuntu/sddc_manager/sddc_manager_commission_host.sh
          scp -o StrictHostKeyChecking=no ${jsonFile} ubuntu@${ip_gw}:/home/ubuntu/json/
          for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
          do
            ip_esxi="$(echo ${ips_esxi} | jq -r .[$(expr ${esxi} - 1)])"
            if [[ $(((${esxi}-1)/4+1)) -eq 1 ]] ; then
              name_esxi="${basename_sddc}-mgmt-esxi0${esxi}"
            fi
            if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
              name_esxi="${basename_sddc}-wld0$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4))"
            fi
            sed -e "s/\${ip_esxi}/${ip_esxi}/" \
                -e "s/\${nested_esxi_root_password}/$(jq -c -r .generic_password $jsonFile)/" /nested-vcf/templates/esxi_cert.expect.template | tee /root/cert-esxi-$esxi.expect > /dev/null
            scp -o StrictHostKeyChecking=no /root/cert-esxi-$esxi.expect ubuntu@${ip_gw}:/home/ubuntu/cert-esxi-$esxi.expect
            #
            sed -e "s/\${ip_esxi}/${ip_esxi}/" \
                -e "s@\${SLACK_WEBHOOK_URL}@${SLACK_WEBHOOK_URL}@" \
                -e "s/\${esxi}/${esxi}/" \
                -e "s/\${name_esxi}/${name_esxi}/" \
                -e "s/\${basename_sddc}/${basename_sddc}/" \
                -e "s/\${ESXI_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" /nested-vcf/templates/esxi_customization.sh.template | tee /root/esxi_customization-$esxi.sh > /dev/null
            scp -o StrictHostKeyChecking=no /root/esxi_customization-$esxi.sh ubuntu@${ip_gw}:/home/ubuntu/esxi_customization-$esxi.sh
          done
          break
        else
          echo "Gw ${gw_name}: cloud init is not finished." | tee -a ${log_file}
        fi
      fi
      ((attempt++))
      if [ $attempt -eq $retry ]; then
        echo "Gw ${gw_name} is unreachable after $attempt attempt" | tee -a ${log_file}
        exit
      fi
      sleep $pause
    done
  fi
  names="${gw_name}"
  #
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Creation of an ESXi hosts on the underlay infrastructure - This should take 10 minutes" | tee -a ${log_file}
  iso_url=$(jq -c -r .esxi.iso_url $jsonFile)
  download_file_from_url_to_location "${iso_url}" "/root/$(basename ${iso_url})" "ESXi ISO"
  if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': ISO ESXI downloaded"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  #
  iso_mount_location="/tmp/esxi_cdrom_mount"
  iso_build_location="/tmp/esxi_cdrom"
  boot_cfg_location="efi/boot/boot.cfg"
  iso_location="/tmp/esxi"
  xorriso -ecma119_map lowercase -osirrox on -indev "/root/$(basename ${iso_url})" -extract / ${iso_mount_location}
  echo "Copying source ESXi ISO to Build directory" | tee -a ${log_file}
  rm -fr ${iso_build_location}
  mkdir -p ${iso_build_location}
  cp -r ${iso_mount_location}/* ${iso_build_location}
  rm -fr ${iso_mount_location}
  echo "Modifying ${iso_build_location}/${boot_cfg_location}" | tee -a ${log_file}
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
      echo "ERROR: unable to create nested ESXi ${name_esxi}: it already exists" | tee -a ${log_file}
    else
      net=$(jq -c -r .esxi.nics[0] $jsonFile)
      ip_esxi="$(echo ${ips_esxi} | jq -r .[$(expr ${esxi} - 1)])"
      hostSpec='{"association":"'${folder}'-dc","ipAddressPrivate":{"ipAddress":"'${ip_esxi}'"},"hostname":"'${name_esxi}'","credentials":{"username":"root","password":"'$(jq -c -r .generic_password $jsonFile)'"},"vSwitch":"vSwitch0"}'
      hostSpecs=$(echo ${hostSpecs} | jq '. += ['${hostSpec}']')
      echo "Building custom ESXi ISO for ESXi${esxi}"
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
      echo "Building new ISO for ESXi ${esxi}"
      xorrisofs -relaxed-filenames -J -R -o "${iso_location}-${esxi}.iso" -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e efiboot.img -no-emul-boot ${iso_build_location}
      ds=$(jq -c -r .vsphere_underlay.datastore $jsonFile)
      dc=$(jq -c -r .vsphere_underlay.datacenter $jsonFile)
      govc datastore.upload  --ds=${ds} --dc=${dc} "${iso_location}-${esxi}.iso" nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
      if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': ISO ESXi '${esxi}' uploaded "}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
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
      names="${names} ${name_esxi}"
      govc vm.create -c ${cpu} -m ${memory} -disk ${disk_os_size} -disk.controller pvscsi -net ${net} -g vmkernel65Guest -net.adapter vmxnet3 -firmware efi -folder "${folder}" -on=false "${name_esxi}" > /dev/null
      govc device.cdrom.add -vm "${folder}/${name_esxi}" > /dev/null
      govc device.cdrom.insert -vm "${folder}/${name_esxi}" -device cdrom-3000 nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
      govc vm.change -vm "${folder}/${name_esxi}" -nested-hv-enabled > /dev/null
      govc vm.disk.create -vm "${folder}/${name_esxi}" -name ${name_esxi}/disk1 -size ${disk_flash_size} > /dev/null
      govc vm.disk.create -vm "${folder}/${name_esxi}" -name ${name_esxi}/disk2 -size ${disk_capacity_size} > /dev/null
      if [[ ${esxi_trunk} == "true" ]] ; then
        net=$(jq -c -r .esxi.nics[1] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null
      fi
      if [[ ${esxi_trunk} == "false" ]] ; then
        net=$(jq -c -r .esxi.nics[1] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null
        net=$(jq -c -r .esxi.nics[2] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null
        net=$(jq -c -r .esxi.nics[3] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null
        net=$(jq -c -r .esxi.nics[4] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null
        net=$(jq -c -r .esxi.nics[5] $jsonFile)
        govc vm.network.add -vm "${folder}/${name_esxi}" -net ${net} -net.adapter vmxnet3 > /dev/null
      fi
      govc vm.power -on=true "${folder}/${name_esxi}" > /dev/null
      if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': nested ESXi '${esxi}' created"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
    fi
  done
  # affinity rule
  if [[ $(jq -c -r .vsphere_underlay.affinity $jsonFile) == "true" ]] ; then
    govc cluster.rule.create -name "${folder}-affinity-rule" -enable -affinity ${names}
  fi
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Cloud Builder JSON file creation  - This should take 1 minute" | tee -a ${log_file}
  hostSpecs="[]"
  hosts_validation_json="[]"
  for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
  do
    if [[ $(((${esxi}-1)/4+1)) -eq 1 ]] ; then
      name_esxi="${basename_sddc}-mgmt-esxi0${esxi}"
      ip_esxi="$(echo ${ips_esxi} | jq -r .[$(expr ${esxi} - 1)])"
      hostSpec='{"association":"'${folder}'-dc","ipAddressPrivate":{"ipAddress":"'${ip_esxi}'"},"hostname":"'${name_esxi}'","credentials":{"username":"root","password":"'$(jq -c -r .generic_password $jsonFile)'"},"vSwitch":"vSwitch0"}'
      hostSpecs=$(echo ${hostSpecs} | jq '. += ['${hostSpec}']')
    fi
    if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
      name_esxi="${basename_sddc}-wld0$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4))"
      ip_esxi="$(echo ${ips_esxi} | jq -r .[$(expr ${esxi} - 1)])"
      host_validation_json='{"fqdn":"'${name_esxi}'.'${domain}'","username":"root","password" :"'$(jq -c -r .generic_password $jsonFile)'","storageType":"VSAN","vvolStorageProtocolType":null,"networkPoolId" : "58d74167-ee80-4eb8-90d9-cdfb3c1cd9f3","networkPoolName":"engineering-networkpool","sshThumbprint":null,"sslThumbprint":null}'
      hosts_validation_json=$(echo ${hosts_validation_json} | jq '. += ['${host_validation_json}']')
    fi
  done
  nsxtManagers="[]"
  for nsx_count in $(seq 1 $(echo ${ips_nsx} | jq -c -r '. | length'))
  do
    nsxtManager='{"hostname":"'${basename_sddc}''${basename_nsx_manager}''${nsx_count}'","ip":"'$(echo ${ips_nsx} | jq -c -r '.['$(expr '${nsx_count}' - 1)']')'"}'
    nsxtManagers=$(echo ${nsxtManagers} | jq '. += ['${nsxtManager}']')
  done
  if [[ ${esxi_trunk} == "true" ]] ; then
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
        -e "s/\${hostSpecs}/$(echo ${hostSpecs} | jq -c -r .)/" /nested-vcf/templates/sddc_cb_v5_trunk.json.template | tee /root/${basename_sddc}_cb.json > /dev/null
  fi
  if [[ ${esxi_trunk} == "false" ]] ; then
    sed -e "s/\${basename_sddc}/${basename_sddc}/" \
        -e "s/\${SDDC_MANAGER_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
        -e "s/\${ip_sddc_manager}/${ip_sddc_manager}/" \
        -e "s/\${basename_sddc}/${basename_sddc}/" \
        -e "s/\${ip_gw}/${ip_gw}/" \
        -e "s/\${domain}/${domain}/" \
        -e "s@\${subnet_mgmt}@$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
        -e "s/\${gw_mgmt}/$(jq -c -r --arg arg "MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
        -e "s@\${subnet_vmotion}@$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
        -e "s/\${gw_vmotion}/$(jq -c -r --arg arg "VMOTION" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
        -e "s/\${ending_ip_vmotion}/${ending_ip_vmotion}/" \
        -e "s/\${starting_ip_vmotion}/${starting_ip_vmotion}/" \
        -e "s@\${subnet_vsan}@$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
        -e "s/\${gw_vsan}/$(jq -c -r --arg arg "VSAN" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
        -e "s/\${ending_ip_vsan}/${ending_ip_vsan}/" \
        -e "s/\${starting_ip_vsan}/${starting_ip_vsan}/" \
        -e "s@\${subnet_vm_mgmt}@$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile)@" \
        -e "s/\${gw_vm_mgmt}/$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')${ip_gw_last_octet}/" \
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
        -e "s/\${hostSpecs}/$(echo ${hostSpecs} | jq -c -r .)/" /nested-vcf/templates/sddc_cb_v5_multi_nic.json.template | tee /root/${basename_sddc}_cb.json > /dev/null
  fi
  sed -e "s/\${basename_sddc}/${basename_sddc}/" \
      -e "s/\${domain}/${domain}/" /nested-vcf/templates/index.html.template | tee /root/index.html > /dev/null
  scp -o StrictHostKeyChecking=no /root/index.html ubuntu@${ip_gw}:/home/ubuntu/index.html
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo mv /home/ubuntu/index.html /var/www/html/index.html" | tee -a ${log_file}
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "chown root /var/www/html/index.html" | tee -a ${log_file}
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "chgrp root /var/www/html/index.html" | tee -a ${log_file}
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo cat /var/lib/bind/db.${domain} | grep avi | sudo tee /var/www/html/avi_raw.html" | tee -a ${log_file}
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "while read -r line; do echo \"\$line<br>\" ; done < /var/www/html/avi_raw.html | sudo tee /var/www/html/avi.html" | tee -a ${log_file}
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo cat /var/lib/bind/db.${domain} | grep wld | sudo tee /var/www/html/esxi_raw.html" | tee -a ${log_file}
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "while read -r line; do echo \"$line<br>\" ; done < /var/www/html/esxi_raw.html | sudo tee /var/www/html/esxi.html" | tee -a ${log_file}
  scp -o StrictHostKeyChecking=no /root/${basename_sddc}_cb.json ubuntu@${ip_gw}:/home/ubuntu/${basename_sddc}_cb.json
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "sudo mv /home/ubuntu/${basename_sddc}_cb.json /var/www/html/${basename_sddc}_cb.json" | tee -a ${log_file}
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "chown root /var/www/html/${basename_sddc}_cb.json" | tee -a ${log_file}
  ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "chgrp root /var/www/html/${basename_sddc}_cb.json" | tee -a ${log_file}
  if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': Details for cloud deployment available at http://'${ip_gw}'/"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Creation of a cloud builder VM underlay infrastructure - This should take 10 minutes" | tee -a ${log_file}
  ip_cb=$(jq -c -r .cloud_builder.ip $jsonFile)
  ip_gw=$(jq -c -r .gw.ip $jsonFile)
  ova_url=$(jq -c -r .cloud_builder.ova_url $jsonFile)
  network_ref=$(jq -c -r .cloud_builder.network_ref $jsonFile)
  #
  download_file_from_url_to_location "${ova_url}" "/root/$(basename ${ova_url})" "VFC-Cloud_Builder OVA"
  if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': Cloud Builder OVA downloaded"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  if [[ $(govc find -json vm | jq '[.[] | select(. == "vm/'${folder}'/'${name_cb}'")] | length') -eq 1 ]]; then
    echo "cloud Builder VM already exists" | tee -a ${log_file}
  else
    sed -e "s/\${CLOUD_BUILDER_PASSWORD}/$(jq -c -r .generic_password $jsonFile)/" \
        -e "s/\${name_cb}/${name_cb}/" \
        -e "s/\${ip_cb}/${ip_cb}/" \
        -e "s/\${netmask}/$(ip_netmask_by_prefix $(jq -c -r --arg arg "${network_ref}" '.vsphere_underlay.networks[] | select( .ref == $arg).cidr' $jsonFile | cut -d"/" -f2) "   ++++++")/" \
        -e "s/\${ip_gw}/${ip_gw}/" \
        -e "s@\${network_ref}@${network_ref}@" /nested-vcf/templates/options-cb.json.template | tee "/tmp/options-${name_cb}.json"
    #
    govc import.ova --options="/tmp/options-${name_cb}.json" -folder "${folder}" "/root/$(basename ${ova_url})" >/dev/null
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': VCF-Cloud_Builder VM created"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
    govc vm.power -on=true "${name_cb}" | tee -a ${log_file}
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': VCF-Cloud_Builder VM started"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
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
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': nested Cloud Builder VM configured and reachable"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  fi
  #
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
    govc vm.power -s ${name_esxi} | tee -a ${log_file}
    sleep 30
    govc vm.power -on ${name_esxi} | tee -a ${log_file}
    ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "/bin/bash /home/ubuntu/esxi_customization-$esxi.sh"
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': nested ESXi '${name_esxi}' ready"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
    govc device.cdrom.eject -vm "${folder}/${name_esxi}" -device cdrom-3000 nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
    sleep 10
    govc device.cdrom.eject -vm "${folder}/${name_esxi}" -device cdrom-3000 nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
    govc datastore.rm nested-vcf/$(basename ${iso_location}-${esxi}.iso) > /dev/null
  done
  govc datastore.rm nested-vcf
  #
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "SDDC creation - This should take hours..." | tee -a ${log_file}
  if [[ $(jq -c -r .sddc.create_mgmt $jsonFile) == "true" ]] ; then
    if [[ $(curl -s -k "https://${ip_cb}/v1/system/appliance-info" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X GET -H 'Content-Type: application/json' -H 'Accept: application/json' | jq -c -r .version | cut -d'.' -f1) == "9" ]]; then
      echo "VCF 9 has been detected" | tee -a ${log_file}
      /nested-vcf/bash/sddc_manager/create_api_session.sh "admin@local" "$(jq -c -r .generic_password $jsonFile)" ${ip_cb} /tmp/token_vcfi.json
      source /nested-vcf/bash/sddc_manager/sddc_manager_api.sh
      sddc_manager_api 3 2 PUT '{"vmwareAccount" : {"username" : "'${DEPOT_USERNAME}'", "password" : "'${DEPOT_PASSWORD}'"}}' ${ip_cb} v1/system/settings/depot $(jq -c -r .accessToken /tmp/token_vcfi.json)
    else
      echo "VCF 9 has not been detected" | tee -a ${log_file}
      validation_id=$(curl -s -k "https://${ip_cb}/v1/sddcs/validations" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d @/root/${basename_sddc}_cb.json | jq -c -r .id)
      # validation json
      retry=60 ; pause=10 ; attempt=1
      while true ; do
        echo "attempt $attempt to verify SDDC JSON validation" | tee -a ${log_file}
        executionStatus=$(curl -k -s "https://${ip_cb}/v1/sddcs/validations/${validation_id}" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X GET -H 'Accept: application/json' | jq -c -r .executionStatus)
        if [[ ${executionStatus} == "COMPLETED" ]]; then
          resultStatus=$(curl -k -s "https://${ip_cb}/v1/sddcs/validations/${validation_id}" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X GET -H 'Accept: application/json' | jq -c -r .resultStatus)
          echo "SDDC JSON validation: ${resultStatus} after $attempt of ${pause} seconds" | tee -a ${log_file}
          if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC JSON validation: '${resultStatus}'"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
          if [[ ${resultStatus} != "SUCCEEDED" ]] ; then exit ; fi
          break
        else
          sleep $pause
        fi
        ((attempt++))
        if [ $attempt -eq $retry ]; then
          echo "SDDC JSON validation not finished after $attempt attempts of ${pause} seconds" | tee -a ${log_file}
          if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC JSON validation not finished after '${attempt}' attempts of '${pause}' seconds"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
          exit
        fi
      done
      sddc_id=$(curl -s -k "https://${ip_cb}/v1/sddcs" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' -d @/root/${basename_sddc}_cb.json | jq -c -r .id)
      # validation_sddc creation
      echo "SDDC ${sddc_id} trying ${count_retry} times to apply" | tee -a ${log_file}
      retry=120 ; pause=300 ; attempt=1 ; count_retry=1
      while true ; do
        echo "attempt $attempt to verify SDDC ${sddc_id} creation" | tee -a ${log_file}
        sddc_status=$(curl -k -s "https://${ip_cb}/v1/sddcs/${sddc_id}" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X GET -H 'Accept: application/json' | jq -c -r .status)
        if [[ ${sddc_status} != "IN_PROGRESS" ]]; then
          echo "SDDC ${sddc_id} creation ${sddc_status} after attempt $attempt of ${pause} seconds, go to https://${ip_cb}" | tee -a ${log_file}
          if [[ ${sddc_status} != "COMPLETED_WITH_SUCCESS" ]]; then
            ((count_retry++))
            if [[ ${count_retry} == 3 ]]; then
              if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC '${sddc_id}' Creation status: '${sddc_status}', go to https://'${ip_cb}'"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
              exit
            fi
            sleep 600
            echo "SDDC ${sddc_id} trying ${count_retry} times to apply after status ${sddc_status}" | tee -a ${log_file}
            retry=$(curl -k -s "https://${ip_cb}/v1/sddcs/${sddc_id}" -u "admin:$(jq -c -r .generic_password $jsonFile)" -X PATCH -H 'Content-type: application/json' -d @/root/${basename_sddc}_cb.json)
          fi
          if [[ ${sddc_status} == "COMPLETED_WITH_SUCCESS" ]]; then
            if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC '${sddc_id}' Creation status: '${sddc_status}', go to https://'${ip_cb}'"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
            break
          fi
        else
          sleep $pause
        fi
        ((attempt++))
        if [ $attempt -eq $retry ]; then
          echo "SDDC ${sddc_id} creation not finished after $attempt attempt of ${pause} seconds" | tee -a ${log_file}
          if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC '${sddc_id}' Creation not finished after '${attempt}' attempts of '${pause}' seconds"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
          exit
        fi
      done
    fi
  fi
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "ESXi host commissioning - This should take minutes..." | tee -a ${log_file}
  if [[ $(jq -c -r .sddc.create_wld $jsonFile) == "true" ]] ; then
    for esxi in $(seq 1 $(echo ${ips_esxi} | jq -c -r '. | length'))
    do
      if [[ $(((${esxi}-1)/4+1)) -gt 1 ]] ; then
        esxi_fqdn="${basename_sddc}-wld0$(((${esxi}-1)/4))-esxi0$((${esxi}-(((${esxi}-1)/4))*4)).${domain}"
        ssh -o StrictHostKeyChecking=no -t ubuntu@${ip_gw} "/home/ubuntu/sddc_manager/sddc_manager_commission_host.sh /home/ubuntu/json/$(basename ${jsonFile}) ${esxi_fqdn}" > ${log_file} 2>&1
        echo "ESXi host commissioning of ESXi host: ${esxi_fqdn}" | tee -a ${log_file}
        if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC '${sddc_id}' ESXi host commissioning of ESXi host: '${esxi_fqdn}'"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
      fi
    done
  fi
  govc vm.power -off=true "${name_cb}" >> /dev/null 2>&1
  echo "Powering off Cloud Builder VM" | tee -a ${log_file}
  if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': Powering off Cloud Builder VM"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
fi
#
#
#
#
#
if [[ ${operation} == "destroy" ]] ; then
  echo '------------------------------------------------------------' | tee -a ${log_file}
  if [[ $(govc find -json vm | jq '[.[] | select(. == "vm/'${folder}'/'${name_cb}'")] | length') -eq 1 ]]; then
    govc vm.power -off=true "${folder}/${name_cb}" | tee -a ${log_file}
    govc vm.destroy "${folder}/${name_cb}" | tee -a ${log_file}
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': VCF-Cloud_Builder VM powered off and destroyed"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  fi
  #
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
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
      if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': nested ESXi '${esxi}' destroyed"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
    else
      echo "ERROR: unable to delete ESXi ${name_esxi}: it is already gone" | tee -a ${log_file}
    fi
  done
  #
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Deletion of a VM on the underlay infrastructure - This should take less than a minute" | tee -a ${log_file}
  if [[ ${list_gw} != "null" ]] ; then
    govc vm.power -off=true "${gw_name}" | tee -a ${log_file}
    govc vm.destroy "${gw_name}" | tee -a ${log_file}
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': external-gw '${gw_name}' VM powered off and destroyed"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  else
    echo "ERROR: unable to delete VM ${gw_name}: it already exists" | tee -a ${log_file}
  fi
  govc cluster.rule.remove -name "${folder}-affinity-rule"
  #
  #
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Deletion of a folder on the underlay infrastructure - This should take less than a minute" | tee -a ${log_file}
  if $(echo ${list_folder} | jq -e '. | any(. == "./vm/'${folder}'")' >/dev/null ) ; then
    govc object.destroy /${vsphere_dc}/vm/${folder} | tee -a ${log_file}
    if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': vsphere external folder '${folder}' removed"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
  else
    echo "ERROR: unable to delete folder ${folder}: it does not exist" | tee -a ${log_file}
  fi
fi
#
echo "Ending timestamp: $(date)" | tee -a ${log_file}
echo '------------------------------------------------------------' | tee -a ${log_file}