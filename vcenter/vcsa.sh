#!/bin/bash
#
jsonFile=${1}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/govc/load_govc_nested_env_wo_cluster.sh
#
load_govc_nested_env_wo_cluster
echo "create portgroup "${basename_sddc}-pg-edge-overlay" in vds "${basename_sddc}-vds-01" with vlan $(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)"
govc dvs.portgroup.add -dvs "${basename_sddc}-vds-01" -vlan "$(jq -c -r --arg arg "EDGE_OVERLAY" '.sddc.vcenter.networks[] | select( .type == $arg).vlan_id' $jsonFile)" "${basename_sddc}-pg-edge-overlay" > /dev/null
