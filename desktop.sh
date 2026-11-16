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
jsonFile="${1}"
if [ -s "${jsonFile}" ]; then
  jq . ${jsonFile} > /dev/null
else
  echo "ERROR: ${jsonFile} file is not present" >> ${log_file}
  exit 255
fi
desktop_ova_url=$(jq -c -r '.desktop.ova_url // ""' $jsonFile)
desktop_ip=$(jq -c -r '.desktop.ip // ""' $jsonFile)
desktop_network_ref=$(jq -c -r '.desktop.network_ref // ""' $jsonFile)
desktop_name=$(jq -c -r '.desktop.name // "desktop-vm"' $jsonFile)
ip_gw=$(jq -c -r '.desktop.ip_gw // "desktop-vm"' $jsonFile)
source /nested-vcf/bash/govc/load_govc_external.sh
govc about
if [[ ${operation} == "apply" ]] ; then
  #
  echo "Creation of a folder on the underlay infrastructure - This should take less than a minute" >> ${log_file}
  if $(echo ${list_folder} | jq -e '. | any(. == "./vm/'${folder}'")' >/dev/null ) ; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: unable to create folder ${folder}: it already exists" ${log_file} ${slack_webhook} ${google_webhook}
  else
    govc folder.create /${vsphere_dc}/vm/${folder} > /dev/null 2>&1
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: vsphere external folder ${folder} created" ${log_file} ${slack_webhook} ${google_webhook}
  fi
  #
  # student desktop
  # ova download
  if [[ ${list_desktop_name} != "null" ]] ; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: unable to create VM ${desktop_name}: it already exists" ${log_file} ${slack_webhook} ${google_webhook}
  else
    download_file_from_url_to_location "${desktop_ova_url}" "/root/$(basename ${desktop_ova_url})" "Desktop OVA"
    sed -e "s#\${desktop_mode}#vcf-auto#" \
        -e "s@\${vcf_gw_ip}@${ip_gw}@" \
        -e "s@\${network_ref}@${desktop_network_ref}@" \
        -e "s@\${desktop_name}@${desktop_name}@" \
        -e "s/\${ntp_servers}/${ip_gw}/" /nested-vcf/templates/options-student-desktop.json.template | tee "/tmp/options-student-desktop.json" > /dev/null
    govc import.ova --options="/tmp/options-student-desktop.json" -folder "${folder}" "/root/$(basename ${desktop_ova_url})" > /dev/null 2>&1
    govc vm.power -on=true "$(basename ${desktop_ova_url})" > /dev/null 2>&1
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
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ${desktop_name} VM powered off and destroyed" ${log_file} ${slack_webhook} ${google_webhook}
  else
    echo "ERROR: unable to delete VM ${desktop_name}: it does not exist" | tee -a ${log_file}
  fi
  #
  #
  #
fi

