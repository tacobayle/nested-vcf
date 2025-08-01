#!/bin/bash
#
jsonFile=${1}
source /home/ubuntu/bash/variables.sh
#
# check NSX Manager
#
retry=10
pause=60
attempt=0
while [[ "$(curl -u admin:${generic_password} -k -s -o /dev/null -w '%{http_code}' https://${ip_nsx_vip}/api/v1/cluster/status)" != "200" ]]; do
  echo "waiting for NSX Manager API to be ready"
  sleep ${pause}
  ((attempt++))
  if [ ${attempt} -eq ${retry} ]; then
    echo "FAILED to get NSX Manager API to be ready after ${retry}"
    exit 255
  fi
done
#
# https://docs.vmware.com/en/VMware-NSX/4.1/administration/GUID-4ABD4548-4442-405D-AF04-6991C2022137.html
#
retry=10
pause=60
attempt=0
while [[ "$(curl -u admin:${generic_password} -k -s  https://${ip_nsx_vip}/api/v1/cluster/status | jq -r .detailed_cluster_status.overall_status)" != "STABLE" ]]; do
  echo "waiting for NSX Manager API to be STABLE"
  sleep ${pause}
  ((attempt++))
  if [ ${attempt} -eq ${retry} ]; then
    echo "FAILED to get NSX Manager API to be STABLE after ${retry}"
    exit 255
  fi
done
echo "NSX Manager ready at https://${ip_nsx_vip}"
if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', '${basename_sddc}': NSX Manager ready at https://'${ip_nsx_vip}'"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
#
# Transport Zones
#
echo ${nsx_config_transport_zones} | jq -c -r .[] | while read zone
do
  json_data=$(echo ${zone} | jq -c -r '.')
  if [[ ${kind} == "vsphere-nsx-vpc-avi" ]]; then
    json_data=$(echo ${json_data} | jq '. += {"is_default": true}')
  fi
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" ${generic_password} \
        "api/v1/transport-zones" \
        "POST" \
        "${json_data}"
done
#
# create ip pools and subnets
#
echo ${nsx_config_ip_pools} | jq -c -r .[] | while read item
do
  item=$(echo ${item} | jq -c -r '. += {"gateway": "'${ip_gw_edge_overlay}'"}')
  item=$(echo ${item} | jq -c -r '. += {"start": "'${ip_start_nsx_edge_overlay}'"}')
  item=$(echo ${item} | jq -c -r '. += {"end": "'${ip_end_nsx_edge_overlay}'"}')
  item=$(echo ${item} | jq -c -r '. += {"cidr": "'${cidr_edge_overlay}'"}')
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" ${generic_password} \
              "policy/api/v1/infra/ip-pools/$(echo ${item} | jq -c -r '.display_name')" \
              "PATCH" \
              "{\"display_name\": \"$(echo ${item} | jq -c -r '.display_name')\"}"
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" ${generic_password} \
              "policy/api/v1/infra/ip-pools/$(echo ${item} | jq -c -r '.display_name')/ip-subnets/$(echo ${item} | jq -c -r '.display_name')-subnet" \
              "PATCH" \
              "{\"display_name\": \"$(echo ${item} | jq -c -r '.display_name')-subnet\",
                \"resource_type\": \"$(echo ${item} | jq -c -r '.resource_type')\",
                \"cidr\": \"$(echo ${item} | jq -c -r '.cidr')\",
                \"gateway_ip\": \"$(echo ${item} | jq -c -r '.gateway')\",
                \"allocation_ranges\": [
                  {
                    \"start\": \"$(echo ${item} | jq -c -r '.start')\",
                    \"end\": \"$(echo ${item} | jq -c -r '.end')\"
                  }
                ]
              }"
done
#
# create segments
#
echo ${nsx_config_segments} | jq -c -r .[] | while read item
do
  #
  # retrieve transport_zone_path
  #
  file_json_output="/tmp/tz.json"
  json_key="tz_path"
  /bin/bash /home/ubuntu/nsx/retrieve_object_path.sh "${ip_nsx_vip}" "${generic_password}" \
              "policy/api/v1/infra/sites/default/enforcement-points/default/transport-zones" \
              "$(echo ${item} | jq -c -r '.transport_zone')" \
              "${file_json_output}" \
              "${json_key}"

  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "policy/api/v1/infra/segments/$(echo ${item} | jq -c -r '.display_name')" \
              "PUT" \
              "{\"display_name\": \"$(echo ${item} | jq -c -r '.display_name')\",
                \"description\": \"$(echo ${item} | jq -c -r '.description')\",
                \"vlan_ids\": $(echo ${item} | jq -c -r '.vlan_ids'),
                \"transport_zone_path\": \"$(jq -c -r '.'${json_key}'' ${file_json_output})\"
              }"
done