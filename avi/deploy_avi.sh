#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/vcenter/vcenter_api.sh
source /home/ubuntu/bash/load_govc_env_with_cluster.sh
source /home/ubuntu/bash/ip_netmask_by_prefix.sh
#
# GOVC check
#
load_govc_env_with_cluster
govc about
if [ $? -ne 0 ] ; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: unable to connect to vCenter" "${log_file}" "${slack_webhook}" "${google_webhook}"
  exit
fi
#
# folder creation
#
list_folder=$(govc find -json . -type f)
if $(echo ${list_folder} | jq -e '. | any(. == "./vm/'${folder_avi}'")' >/dev/null ) ; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: unable to create folder ${folder_avi}: it already exists" "${log_file}" "" ""
else
  govc folder.create /${vcsa_mgmt_dc}/vm/${folder_avi}
fi
#
# avi ctrl creation
#
list_vm=$(govc find -json -type m -name "${avi_ctrl_name}")
if [[ ${list_vm} != "null" ]] ; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: ERROR: unable to create VM ${avi_ctrl_name}: it already exists" "${log_file}" "" ""
  exit
else
  netmask_avi=$(ip_netmask_by_prefix $(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | cut -d"/" -f2) "   ++++++")
  #
  # Avi options
  #
  avi_options=$(jq -c -r '.' /home/ubuntu/json/avi_spec.json)
  avi_options=$(echo ${avi_options} | jq '. += {"IPAllocationPolicy": "fixedPolicy"}')
  avi_options=$(echo ${avi_options} | jq '.PropertyMapping[0] += {"Value": "'${ip_avi}'"}')
  avi_options=$(echo ${avi_options} | jq '.PropertyMapping[1] += {"Value": "'${netmask_avi}'"}')
  avi_options=$(echo ${avi_options} | jq '.PropertyMapping[2] += {"Value": "'${ip_gw_vm_management}'"}')
  avi_options=$(echo ${avi_options} | jq '.PropertyMapping[11] += {"Value": "'${avi_ctrl_name}'"}')
  avi_options=$(echo ${avi_options} | jq '.NetworkMapping[0] += {"Network": "'${network_vm_management_name}'"}')
  avi_options=$(echo ${avi_options} | jq '. += {"Name": "'${avi_ctrl_name}'"}')
  echo ${avi_options} | jq -c -r '.' | tee /home/ubuntu/json/options-${avi_ctrl_name}.json
  #
  # Avi Creation
  #
  govc import.ova --options="/home/ubuntu/json/options-${avi_ctrl_name}.json" -folder "${folder_avi}" "/home/ubuntu/bin/$(basename ${avi_ova_url})" > /dev/null
  govc vm.power -on=true "${avi_ctrl_name}" > /dev/null
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Avi ctrl deployed" "${log_file}" "${slack_webhook}" "${google_webhook}"
fi
touch ${resultFile}
exit