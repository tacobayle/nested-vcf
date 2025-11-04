#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/vcenter/vcenter_api.sh
file_path="/home/ubuntu/nsx"
#
# check NSX Manager
#
retry=10
pause=60
attempt=0
while [[ "$(curl -u admin:${generic_password} -k -s -o /dev/null -w '%{http_code}' https://${ip_nsx_vip}/api/v1/cluster/status)" != "200" ]]; do
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: waiting for NSX Manager API to be ready" "${log_file}" "" ""
  sleep ${pause}
  ((attempt++))
  if [ ${attempt} -eq ${retry} ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: FAILED to get NSX Manager API to be ready after ${retry}" "${log_file}" "${slack_webhook}" "${google_webhook}"
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
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: waiting for NSX Manager API to be STABLE" "${log_file}" "" ""
  sleep ${pause}
  ((attempt++))
  if [ ${attempt} -eq ${retry} ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: FAILED to get NSX Manager API to be STABLE after ${retry}" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 255
  fi
done
log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: NSX Manager ready at https://${ip_nsx_vip}" "${log_file}" "${slack_webhook}" "${google_webhook}"
#
# uplink profile for edge
#
echo ${nsx_config_uplink_profiles} | jq -c -r .[] | while read item
do
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "policy/api/v1/infra/host-switch-profiles/$(echo ${item} | jq -c -r '.display_name')" \
              "PUT" \
              "${item}"
done
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
#
# Update Host transport node profile with VLAN Transport Zone
#
api_endpoint="policy/api/v1/infra/host-transport-node-profiles"
/bin/bash "${file_path}/get_object.sh" "${ip_nsx_vip}" "${generic_password}" \
            "${api_endpoint}" "${file_path}/$(basename ${api_endpoint}).json"
json_data=$(jq -c -r .results[0] "${file_path}/$(basename ${api_endpoint}).json")
api_endpoint="policy/api/v1/infra/sites/default/enforcement-points/default/transport-zones"
json_key="id"
/bin/bash /home/ubuntu/nsx/retrieve_object_id.sh "${ip_nsx_vip}" "${generic_password}" \
            "${api_endpoint}" \
            "$(echo ${nsx_config_transport_zones} | jq -c -r .[0].display_name)" \
            "${file_path}/$(basename ${api_endpoint}).json" \
            "${json_key}"
transport_zone_id="/infra/sites/default/enforcement-points/default/transport-zones/$(jq -c -r .${json_key} ${file_path}/$(basename ${api_endpoint}).json)"
json_data=$(echo ${json_data} | jq '.host_switch_spec.host_switches[0].transport_zone_endpoints += [{"transport_zone_id": "'${transport_zone_id}'", "transport_zone_profile_ids": []}]')
/bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
            "policy/api/v1/infra/host-transport-node-profiles/$(echo ${json_data} | jq -c -r '.id')" \
            "PUT" \
            "$(echo ${json_data} | jq -c -r .)"
#
# Edge node creation
#
# Get compute manager id
api_endpoint="api/v1/fabric/compute-managers"
/bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
            "api/v1/fabric/compute-managers" \
            "${file_path}/$(basename ${api_endpoint}).json"
vc_id=$(jq -c -r --arg arg1 "${basename_sddc}-vcsa.${domain}" '.results[] | select(.display_name == $arg1).id' ${file_path}/$(basename ${api_endpoint}).json)
# vCenter API session creation to retrieve various things
token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${basename_sddc}-vcsa.${domain}")
vcenter_api 2 2 "GET" ${token} '' "${basename_sddc}-vcsa.${domain}" "api/vcenter/datastore"
storage_id=$(echo ${response_body} | jq -r .[0].datastore)
vcenter_api 2 2 "GET" ${token} "" "${basename_sddc}-vcsa.${domain}" "api/vcenter/network"
management_network_id=$(echo ${response_body} | jq -c -r --arg arg1 "${basename_sddc}-pg-mgmt" '.[] | select(.name == $arg1).network')
data_network_ids="[]"
data_network_ids=$(echo ${data_network_ids} | jq '. += ["'$(echo ${response_body} | jq -c -r --arg arg1 "${basename_sddc}-pg-edge-overlay" '.[] | select(.name == $arg1).network')'"]')
data_network_ids=$(echo ${data_network_ids} | jq '. += ["'$(echo ${response_body} | jq -c -r --arg arg1 "${basename_sddc}-pg-external" '.[] | select(.name == $arg1).network')'"]')
vcenter_api 2 2 "GET" ${token} "" "${basename_sddc}-vcsa.${domain}" "api/vcenter/cluster"
cluster=$(echo ${response_body} | jq -c -r --arg arg1 "${basename_sddc}-cluster" '.[] | select(.name == $arg1).cluster')
vcenter_api 2 2 "GET" ${token} "" "${basename_sddc}-vcsa.${domain}" "api/vcenter/cluster/${cluster}"
compute_id=$(echo ${response_body} | jq -c -r '.resource_pool')
#
edge_ids="[]"
for edge_index in $(seq 1 $(echo ${nsx_config_ips_edge} | jq -r '. | length'))
do
  edge_name="${nsx_config_edge_node_basename}${edge_index}"
  edge_fqdn="${nsx_config_edge_node_basename}${edge_index}.${domain}"
  ip_edge="${cidr_mgmt_three_octets}.$(echo ${nsx_config_ips_edge} | jq -r .[$(expr ${edge_index} - 1)])"
  host_switch_count=0
  json_data='{"host_switch_spec": {"host_switches": [], "resource_type": "StandardHostSwitchSpec"}}'
  echo ${json_data} | jq . | tee /tmp/tmp.json
  echo ${nsx_config_edge_node_host_switch_spec_host_switches} | jq -c -r .[] | while read item
  do
    json_data=$(jq -r -c '.host_switch_spec.host_switches |= .+ ['${item}']' /tmp/tmp.json)
    json_data=$(echo ${json_data} | jq '.host_switch_spec.host_switches['${host_switch_count}'] += {"host_switch_profile_ids": []}')
    json_data=$(echo ${json_data} | jq '.host_switch_spec.host_switches['${host_switch_count}'] += {"transport_zone_endpoints": []}')
    echo ${json_data} | jq . | tee /tmp/tmp.json
    echo ${item} | jq -c -r .host_switch_profile_names[] | while read host_switch_profile_name
    do
      api_endpoint="api/v1/host-switch-profiles"
      /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                  "${api_endpoint}" \
                  "${file_path}/$(basename ${api_endpoint}).json"
      host_switch_profile_id=$(jq -c -r --arg arg1 "${host_switch_profile_name}" '.results[] | select(.display_name == $arg1).id' ${file_path}/$(basename ${api_endpoint}).json)
      json_data=$(jq '.host_switch_spec.host_switches['${host_switch_count}'].host_switch_profile_ids += [{"key": "UplinkHostSwitchProfile", "value": "'${host_switch_profile_id}'"}]' /tmp/tmp.json)
      echo ${json_data} | jq . | tee /tmp/tmp.json
    done
    echo ${item} | jq -c -r .transport_zone_names[] | while read tz
    do
      api_endpoint="api/v1/transport-zones"
      /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                  "${api_endpoint}" \
                  "${file_path}/$(basename ${api_endpoint}).json"
      transport_zone_id=$(jq -c -r --arg arg1 "${tz}" '.results[] | select(.display_name == $arg1).id' ${file_path}/$(basename ${api_endpoint}).json)
      json_data=$(jq '.host_switch_spec.host_switches['${host_switch_count}'].transport_zone_endpoints += [{"transport_zone_id": "'${transport_zone_id}'"}]' /tmp/tmp.json)
      echo ${json_data} | jq . | tee /tmp/tmp.json
    done
    if $(echo ${item} | jq -e '. | has("ip_pool_name")') ; then
      api_endpoint="api/v1/infra/ip-pools"
      /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                  "${api_endpoint}" \
                  "${file_path}/$(basename ${api_endpoint}).json"
      ip_pool_id=$(jq -c -r --arg arg1 "$(echo ${json_data} | jq -r '.host_switch_spec.host_switches['${host_switch_count}'].ip_pool_name')" '.results[] | select(.display_name == $arg1).realization_id' ${file_path}/$(basename ${api_endpoint}).json)
      json_data=$(jq '.host_switch_spec.host_switches['${host_switch_count}'] += {"ip_assignment_spec": {"ip_pool_id": "'${ip_pool_id}'", "resource_type": "StaticIpPoolSpec"}}' /tmp/tmp.json)
      json_data=$(echo ${json_data} | jq 'del (.host_switch_spec.host_switches['${host_switch_count}'].ip_pool_name)')
      echo ${json_data} | jq . | tee /tmp/tmp.json
    fi
    json_data=$(jq 'del (.host_switch_spec.host_switches['${host_switch_count}'].host_switch_profile_names)' /tmp/tmp.json)
    json_data=$(echo ${json_data} | jq 'del (.host_switch_spec.host_switches['${host_switch_count}'].transport_zone_names)')
    echo ${json_data} | jq . | tee /tmp/tmp.json
    host_switch_count=$((host_switch_count+1))
  done
  json_data=$(jq '. +=  {"maintenance_mode": "DISABLED"}' /tmp/tmp.json)
  json_data=$(echo ${json_data} | jq '. +=  {"display_name":"'${edge_name}'"}')
  json_data=$(echo ${json_data} | jq '. +=  {"node_deployment_info": {
                                               "resource_type":"EdgeNode",
                                               "deployment_type": "VIRTUAL_MACHINE",
                                               "deployment_config": {
                                                 "vm_deployment_config": {
                                                   "vc_id": "'${vc_id}'",
                                                   "compute_id": "'${compute_id}'",
                                                   "storage_id": "'${storage_id}'",
                                                   "management_network_id": "'${management_network_id}'",
                                                   "management_port_subnets": [
                                                     {
                                                       "ip_addresses": ["'${ip_edge}'"],
                                                       "prefix_length": '${mgmt_prefix_length}'
                                                      }
                                                   ],
                                                   "default_gateway_addresses": ["'${ip_gw_mgmt}'"],
                                                   "data_network_ids": '$(echo ${data_network_ids} | jq -r -c .)',
                                                   "reservation_info": {
                                                     "memory_reservation" : {"reservation_percentage": 100 },
                                                     "cpu_reservation": {
                                                       "reservation_in_shares": "HIGH_PRIORITY",
                                                       "reservation_in_mhz": 0
                                                     }
                                                   },
                                                   "resource_allocation": {
                                                     "cpu_count": '${nsx_config_edge_node_cpu}',
                                                     "memory_allocation_in_mb": '${nsx_config_edge_node_memory}'
                                                   },
                                                   "placement_type": "VsphereDeploymentConfig"
                                                 },
                                                 "form_factor": "MEDIUM",
                                                 "node_user_settings": {
                                                   "cli_username": "admin",
                                                   "root_password": "'${generic_password}'",
                                                   "cli_password": "'${generic_password}'"
                                                 }
                                               },
                                               "node_settings": {
                                                 "hostname": "'${edge_fqdn}'",
                                                 "allow_ssh_root_login": true
                                               }}}')
  api_endpoint="api/v1/transport-nodes"
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "${api_endpoint}" \
              "POST" \
              $(echo ${json_data} | jq -c -r .)
  edge_ids=$(echo ${edge_ids} | jq '. += ["'$(jq -r .id /home/ubuntu/nsx/response_body.json)'"]')
done
#
# Check the status of Nodes (including transport node and edge nodes but filtered with edge_ids
#
log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: pausing for 600 seconds" "${log_file}" "" ""
sleep 600
retry=240 ; pause=20 ; attempt=0
for item in $(echo ${edge_ids} | jq -c -r '.[]')
do
  while true ; do
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: attempt ${attempt} to get node id ${item} ready" "${log_file}" "" ""
    api_endpoint="policy/api/v1/transport-nodes/state"
    /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                "${api_endpoint}" \
                "${file_path}/$(basename ${api_endpoint}).json"
    for edge in $(seq 0 $(($(jq -c -r '.results | length' "${file_path}/$(basename ${api_endpoint}).json")-1)))
    do
      if [[ $(jq -c -r '.results['$edge'].transport_node_id' "${file_path}/$(basename ${api_endpoint}).json") == ${item} ]] && [[ $(jq -c -r '.results['$edge'].state' "${file_path}/$(basename ${api_endpoint}).json") == "success" ]] ; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: new edge node id ${item} state is success after ${attempt} attempts of ${pause} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
        break 2
      fi
    done
    ((attempt++))
    if [ ${attempt} -eq ${retry} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Unable to get node id ${item} ready after ${attempt} of ${pause} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 1
    fi
    sleep ${pause}
  done
done
#
# edge cluster creation
#
json_data="[]"
edge_cluster_count=0
echo ${json_data} | jq . | tee /tmp/tmp.json
echo ${nsx_config_edge_clusters} | jq -c -r .[] | while read item
do
  json_data=$(jq '.['${edge_cluster_count}'] += {"display_name": "'$(echo ${item} | jq -c -r .display_name)'"}' /tmp/tmp.json)
  echo ${json_data} | jq . | tee /tmp/tmp.json
  echo ${item} | jq -c -r .members[].display_name | while read display_name
  do
    api_endpoint="api/v1/transport-nodes"
    /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                "${api_endpoint}" \
                "${file_path}/$(basename ${api_endpoint}).json"
    transport_node_id=$(jq -c -r --arg arg1 "${display_name}" '.results[] | select(.display_name == $arg1).id' ${file_path}/$(basename ${api_endpoint}).json)
    json_data=$(jq '.['${edge_cluster_count}'].members += [{"transport_node_id": "'${transport_node_id}'"}]' /tmp/tmp.json)
    echo ${json_data} | jq . | tee /tmp/tmp.json
  done
  edge_cluster_count=$((edge_cluster_count+1))
done
jq -c -r .[] /tmp/tmp.json | while read item
do
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "api/v1/edge-clusters" \
              "POST" \
              ${item}
done
#
# tier 0 creation
#
echo ${nsx_config_tier0s} | jq -c -r .[] | while read item
do
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "policy/api/v1/infra/tier-0s/$(echo ${item} | jq -r -c .display_name)" \
              "PUT" \
              "{\"display_name\": \"$(echo ${item} | jq -r -c .display_name)\", \"ha_mode\": \"$(echo ${item} | jq -r -c .ha_mode)\"}"
done
#
# tier 0 edge cluster association
#
echo ${nsx_config_tier0s} | jq -c -r .[] | while read item
do
  api_endpoint="api/v1/edge-clusters"
  /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "api/v1/edge-clusters" \
              "${file_path}/$(basename ${api_endpoint}).json"
  edge_cluster_id=$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .edge_cluster_name)" '.results[] | select(.display_name == $arg1).id' ${file_path}/$(basename ${api_endpoint}).json)
  json_data="{\"edge_cluster_path\": \"/infra/sites/default/enforcement-points/default/edge-clusters/${edge_cluster_id}\"}"
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "policy/api/v1/infra/tier-0s/$(echo ${item} | jq -r -c .display_name)/locale-services/default" \
              "PUT" \
              "${json_data}"
done
#
# tier 0 interface config.
#
echo ${nsx_config_tier0s} | jq -c -r .[] | while read item
do
  if [[ $(echo ${item} | jq 'has("interfaces")') == "true" ]] ; then
    echo ${item} | jq -c -r .interfaces[] | while read iface
    do
      json_data="{\"subnets\" : [ {\"ip_addresses\": [\"${cidr_external_three_octets}.${nsx_tier0_starting_ip}\"], \"prefix_len\" : ${external_prefix_length}}]}"
      nsx_tier0_starting_ip=$((nsx_tier0_starting_ip+1))
      json_data=$(echo ${json_data} | jq '. += {"display_name": "'$(echo ${iface} | jq -r .display_name)'"}')
      api_endpoint="policy/api/v1/infra/segments"
      /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                  "${api_endpoint}" \
                  "${file_path}/$(basename ${api_endpoint}).json"
      segment_path=$(jq -c -r --arg arg1 "$(echo ${iface} | jq -r -c .segment_name)" '.results[] | select(.display_name == $arg1).path' ${file_path}/$(basename ${api_endpoint}).json)
      json_data=$(echo ${json_data} | jq '. += {"segment_path": "'${segment_path}'"}')
      api_endpoint="api/v1/edge-clusters"
      /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                  "${api_endpoint}" \
                  "${file_path}/$(basename ${api_endpoint}).json"
      edge_cluster_id=$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .edge_cluster_name)" '.results[] | select(.display_name == $arg1).id' ${file_path}/$(basename ${api_endpoint}).json)
      edge_node_id=$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .edge_cluster_name)" --arg arg2 "$(echo ${iface} | jq -r -c .edge_name)" '.results[] | select(.display_name == $arg1).members[] | select(.display_name == $arg2).member_index' ${file_path}/$(basename ${api_endpoint}).json)
      json_data=$(echo ${json_data} | jq '. += {"edge_path": "/infra/sites/default/enforcement-points/default/edge-clusters/'${edge_cluster_id}'/edge-nodes/'${edge_node_id}'"}')
      /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
                  "policy/api/v1/infra/tier-0s/$(echo ${item} | jq -r -c .display_name)/locale-services/default/interfaces/$(echo ${iface} | jq -r -c .display_name)" \
                  "PATCH" \
                  "${json_data}"
    done
  fi
done
#
# tier 0 static routes config.
#
echo ${nsx_config_tier0s} | jq -c -r .[] | while read item
do
  if [[ $(echo ${item} | jq 'has("static_routes")') == "true" ]] ; then
    echo ${item} | jq -c -r .static_routes[] | while read route
    do
      route=$(echo ${route} | jq -c -r '.next_hops[0] += {"ip_address": "'${ip_gw_external}'"}')
      /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
                  "policy/api/v1/infra/tier-0s/$(echo ${item} | jq -r -c .display_name)/static-routes/$(echo ${route} | jq -r -c .display_name)" \
                  "PATCH" \
                  "${route}"
    done
  fi
done
#
# tier 0 ha-vip config.
#
echo ${nsx_config_tier0s} | jq -c -r .[] | while read item
do
  json_data="{\"display_name\": \"default\", \"ha_vip_configs\": []}"
  echo ${json_data} | jq . | tee /tmp/tmp.json
  if [[ $(echo ${item} | jq 'has("ha_vips")') == "true" ]] ; then
    api_endpoint="api/v1/edge-clusters"
    /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                "${api_endpoint}" \
                "${file_path}/$(basename ${api_endpoint}).json"
    edge_cluster_id=$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .edge_cluster_name)" '.results[] | select(.display_name == $arg1).id' "${file_path}/$(basename ${api_endpoint}).json")
    json_data=$(jq '. += {"edge_cluster_path": "/infra/sites/default/enforcement-points/default/edge-clusters/'$edge_cluster_id'"}' /tmp/tmp.json)
    echo ${json_data} | jq . | tee /tmp/tmp.json
    echo ${item} | jq -c -r .ha_vips[] | while read vip
    do
      interfaces="[]"
      echo ${vip} | jq -c -r .interfaces[] | while read iface
      do
        interfaces=$(echo ${interfaces} | jq -c -r '. += ["/infra/tier-0s/'$(echo ${item} | jq -r -c .display_name)'/locale-services/default/interfaces/'${iface}'"]')
        echo ${interfaces} | jq . | tee /tmp/nsx_interfaces.json
      done
      json_data=$(jq -c -r '.ha_vip_configs += [{"enabled": true, "vip_subnets": [{"ip_addresses": [ "'${cidr_external_three_octets}.${nsx_tier0_tier0_vip_starting_ip}'" ], "prefix_len": '${external_prefix_length}'}], "external_interface_paths": '$(jq -c -r . /tmp/nsx_interfaces.json)'}]' /tmp/tmp.json)
      echo ${json_data} | jq . | tee /tmp/tmp.json
      nsx_tier0_tier0_vip_starting_ip=$((nsx_tier0_tier0_vip_starting_ip+1))
    done
    /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
                "policy/api/v1/infra/tier-0s/$(echo ${item} | jq -r -c .display_name)/locale-services/default" \
                "PATCH" \
                "$(jq -c -r . /tmp/tmp.json)"
  fi
done
#
# create dhcp servers
#
echo ${nsx_config_dhcp_servers} | jq -c -r .[] | while read item
do
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "policy/api/v1/infra/dhcp-server-configs/$(echo ${item} | jq -c -r '.display_name')" \
              "PUT" \
              "${item}"
done
#
# create tier1s
#
echo ${nsx_config_tier1s} | jq -c -r .[] | while read item
do
  api_endpoint="policy/api/v1/infra/tier-0s"
  /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "${api_endpoint}" \
              "${file_path}/$(basename ${api_endpoint}).json"
  tier0_path=$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .tier0)" '.results[] | select(.display_name == $arg1).path' "${file_path}/$(basename ${api_endpoint}).json")
  api_endpoint="policy/api/v1/infra/dhcp-server-configs"
  /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "${api_endpoint}" \
              "${file_path}/$(basename ${api_endpoint}).json"
  dhcp_config_path=$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .dhcp_server)" '.results[] | select(.display_name == $arg1).path' "${file_path}/$(basename ${api_endpoint}).json")
  if $(echo ${item} | jq -e '.edge_cluster_name' > /dev/null) ; then
    api_endpoint="api/v1/edge-clusters"
    /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
                "${api_endpoint}" \
                "${file_path}/$(basename ${api_endpoint}).json"
    edge_cluster_path="/infra/sites/default/enforcement-points/default/edge-clusters/$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .edge_cluster_name)" '.results[] | select(.display_name == $arg1).id' "${file_path}/$(basename ${api_endpoint}).json")"
  else
    edge_cluster_path=""
  fi
  json_data='{
                "display_name": "'$(echo ${item} | jq -c -r .display_name)'",
                "tier0_path": "'${tier0_path}'",
                "dhcp_config_paths": ["'${dhcp_config_path}'"],
                "route_advertisement_types": '$(echo ${item} | jq -c -r .route_advertisement_types)'
             }'
  if $(echo ${item} | jq -e '.ha_mode' > /dev/null) ; then
    json_data=$(echo ${json_data} | jq '. += {"ha_mode": "'$(echo ${item} | jq -c -r .ha_mode)'"}')
  fi
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "policy/api/v1/infra/tier-1s/$(echo ${item} | jq -r -c .display_name)" \
              "PUT" \
              "${json_data}"
  if [[ ${edge_cluster_path} != "" ]] ; then
    json_data='
      {
        "display_name": "default",
        "edge_cluster_path": "'${edge_cluster_path}'"
      }'
    /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
                "policy/api/v1/infra/tier-1s/$(echo ${item} | jq -r -c .display_name)/locale-services/default" \
                "PUT" \
                "${json_data}"
  fi
done
#
# create segments
#
echo ${nsx_segments_overlay} | jq -c -r .[] | while read item
do
  api_endpoint="policy/api/v1/infra/tier-1s"
  /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "${api_endpoint}" \
              "${file_path}/$(basename ${api_endpoint}).json"
  connectivity_path=$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .tier1)" '.results[] | select(.display_name == $arg1).path' "${file_path}/$(basename ${api_endpoint}).json")
  #
  api_endpoint="policy/api/v1/infra/sites/default/enforcement-points/default/transport-zones"
  /bin/bash /home/ubuntu/nsx/get_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "${api_endpoint}" \
              "${file_path}/$(basename ${api_endpoint}).json"
  transport_zone_path="$(jq -c -r --arg arg1 "$(echo ${item} | jq -r -c .transport_zone)" '.results[] | select(.display_name == $arg1).path' "${file_path}/$(basename ${api_endpoint}).json")"
  json_data='
    {
      "display_name": "'$(echo ${item} | jq -r -c .display_name)'",
      "connectivity_path": "'${connectivity_path}'",
      "transport_zone_path": "'${transport_zone_path}'",
      "subnets": [
        {
          "gateway_address": "'$(echo ${item} | jq -r -c .gateway_address)'",
          "dhcp_ranges": '$(echo ${item} | jq -r -c .dhcp_ranges)',
          "dhcp_config": {
            "options": {
              "others": [
                {
                  "code": 42,
                  "values": ["'${ip_gw}'"]
                }
              ]
            },
            "resource_type": "SegmentDhcpV4Config",
            "dns_servers": ["'${ip_gw}'"]
          }
        }
      ]
    }'
  /bin/bash /home/ubuntu/nsx/set_object.sh "${ip_nsx_vip}" "${generic_password}" \
              "policy/api/v1/infra/segments/$(echo ${item} | jq -r -c .display_name)" \
              "PUT" \
              "${json_data}"
done
#
#
#
log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of the NSX config." "${log_file}" "${slack_webhook}" "${google_webhook}"
touch ${resultFile}