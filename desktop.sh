#!/bin/bash
#
source /nested-vcf/bash/download_file.sh
source /nested-vcf/bash/ip.sh
source /nested-vcf/bash/sddc_manager/sddc_manager_api.sh
source /nested-vcf/bash/vcenter/vcenter_api.sh
source /nested-vcf/bash/test_remote_script.sh
#
log_file=${2}
rm -f /root/govc.error
jsonFile="${1}"
if [ -s "${jsonFile}" ]; then
  jq . ${jsonFile} > /dev/null
else
  echo "ERROR: ${jsonFile} file is not present" >> ${log_file}
  exit 255
fi
operation=$(jq -c -r .operation $jsonFile)
desktop_ova_url=$(jq -c -r '.desktop.ova_url // ""' $jsonFile)
desktop_ip=$(jq -c -r '.desktop.ip // ""' $jsonFile)
desktop_network_ref=$(jq -c -r '.desktop.network_ref // ""' $jsonFile)
desktop_name=$(jq -c -r '.desktop.name // "desktop-vm"' $jsonFile)
ip_gw=$(jq -c -r '.desktop.ip_gw // ""' $jsonFile)
folder=$(jq -c -r .vsphere_underlay.folder $jsonFile)
source /nested-vcf/bash/govc/load_govc_external.sh
govc about
list_folder=$(govc find -json . -type f)
list_desktop_name=$(govc find -json vm -name "${desktop_name}")
if [[ ${operation} == "apply" ]] ; then
  #
  echo "Creation of a folder on the underlay infrastructure - This should take less than a minute" >> ${log_file}
  if $(echo ${list_folder} | jq -e '. | any(. == "./vm/'${folder}'")' >/dev/null ) ; then
    echo "folder already exists" >> ${log_file}
  else
    govc folder.create /${vsphere_dc}/vm/${folder} > /dev/null 2>&1
  fi
  #
  # student desktop
  # ova download
  if [[ ${list_desktop_name} != "null" ]] ; then
    echo "VM already exists" >> ${log_file}
  else
    download_file_from_url_to_location "${desktop_ova_url}" "/root/$(basename ${desktop_ova_url})" "Desktop OVA"
    sed -e "s#\${desktop_mode}#vcf-auto#" \
        -e "s@\${vcf_gw_ip}@${ip_gw}@" \
        -e "s@\${network_ref}@${desktop_network_ref}@" \
        -e "s@\${desktop_name}@${desktop_name}@" \
        -e "s/\${ntp_servers}/${ip_gw}/" /nested-vcf/templates/options-student-desktop.json.template | tee "/tmp/options-student-desktop.json" > /dev/null
    govc import.ova --options="/tmp/options-student-desktop.json" -folder "${folder}" "/root/$(basename ${desktop_ova_url})" > /dev/null 2>&1
    govc vm.power -on=true "${desktop_name}" > /dev/null 2>&1
  fi
fi
#
#
# destroy use case
#
#
if [[ ${operation} == "destroy" ]] ; then
  echo '------------------------------------------------------------' | tee -a ${log_file}
  echo "Deletion of a VM on the underlay infrastructure - This should take less than a minute" | tee -a ${log_file}
  if [[ ${list_desktop_name} != "null" ]] ; then
    govc vm.power -off=true "${desktop_name}"
    govc vm.destroy "${desktop_name}"
  else
    echo "ERROR: unable to delete VM ${desktop_name}: it does not exist" | tee -a ${log_file}
  fi
  #
  #
  #
fi

