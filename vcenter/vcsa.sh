#!/bin/bash
#
jsonFile="${1}"
resultFile="${2}"
rm -f ${resultFile}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/govc/load_govc_nested_env_wo_cluster.sh
#
load_govc_nested_env_wo_cluster
log_message "create portgroup ${basename_sddc}-pg-edge-overlay in vds ${basename_sddc}-vds-01 with vlan $(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "" "" ""
govc dvs.portgroup.add -dvs "${basename_sddc}-vds-01" -vlan "$(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "${basename_sddc}-pg-edge-overlay" > /dev/null
log_message "create portgroup ${basename_sddc}-pg-external in vds ${basename_sddc}-vds-01 with vlan $(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "" "" ""
govc dvs.portgroup.add -dvs "${basename_sddc}-vds-01" -vlan "$(jq -c -r --arg arg "EXTERNAL" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "${basename_sddc}-pg-external" > /dev/null
log_message "portgroups creation done" "" "${slack_webhook}" "${google_webhook}"
touch ${resultFile}
log_message "create content library update-cl-ubuntu" "" "" ""
govc library.create ${vsphere_cl_name}
govc library.import ${vsphere_cl_name} "/home/ubuntu/bin/$(basename ${ubuntu_ova_url})"