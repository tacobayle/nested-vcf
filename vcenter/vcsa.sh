#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/govc/load_govc_nested_env_wo_cluster.sh
load_govc_nested_env_wo_cluster
#
# port group
#
log_message "create portgroup ${basename_sddc}-pg-edge-overlay in vds ${basename_sddc}-vds-01 with vlan $(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "${log_file}" "" ""
govc dvs.portgroup.add -dvs "${basename_sddc}-vds-01" -vlan "$(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "${basename_sddc}-pg-edge-overlay" > /dev/null 2>&1
log_message "create portgroup ${basename_sddc}-pg-external in vds ${basename_sddc}-vds-01 with vlan $(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "${log_file}" "" ""
govc dvs.portgroup.add -dvs "${basename_sddc}-vds-01" -vlan "$(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "${basename_sddc}-pg-external" > /dev/null 2>&1
#
#
#
touch ${resultFile}
#
# content library
#
#log_message "create content library update-cl-ubuntu" "${log_file}" "" ""
#govc library.create ${vsphere_cl_name} > /dev/null 2>&1
#govc library.import ${vsphere_cl_name} "/home/ubuntu/bin/$(basename ${ubuntu_ova_url})" > /dev/null 2>&1
#touch ${resultFile}