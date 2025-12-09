#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/vcenter/vcenter_api.sh
#
#
#
token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
vcenter_api 6 10 "GET" $token '' ${vcsa_fqdn} "rest/vcenter/datastore"
datastore_id=$(echo $response_body | jq -c -r --arg arg "${basename_sddc}-vsan" '.value[] | select(.name == $arg) | .datastore')
ValidCmThumbPrint=$(openssl s_client -connect $(echo ${content_library_subscription_url}  | cut -d"/" -f3):443 < /dev/null 2>/dev/null | openssl x509 -fingerprint -noout -in /dev/stdin | awk -F'Fingerprint=' '{print $2}')
json_data='
{
  "storage_backings":
  [
    {
      "datastore_id":"'${datastore_id}'",
      "type":"DATASTORE"
    }
  ],
  "type": "SUBSCRIBED",
  "version":"2",
  "subscription_info":
    {
      "authentication_method":"NONE",
      "ssl_thumbprint":"'${ValidCmThumbPrint}'",
      "automatic_sync_enabled": "true",
      "subscription_url": "'${content_library_subscription_url}'",
      "on_demand": "true"
    },
  "name": "content_library_supervisor"
}'
vcenter_api 3 3 "POST" $token "${json_data}" ${vcsa_fqdn} "api/content/subscribed-library"
content_library_id=$(echo $response_body | tr -d '"')
#
# Retrieve cluster id
#
token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/cluster"
cluster_id=$(echo $response_body | jq -r --arg cluster "${basename_sddc}-cluster" '.[] | select(.name == $cluster).cluster')
#
# Retrieve storage policy
#
token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/storage/policies"
storage_policy_id=$(echo $response_body | jq -r --arg policy "${supervisor_cluster_storage_policy_ref}" '.[] | select(.name == $policy) | .policy')
#
# Retrieve network id
#
token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/network"
network_supervisor_management=$(echo ${segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).display_name')
network_id=$(echo $response_body | jq -r --arg pg "${network_supervisor_management}" '.[] | select(.name == $pg).network')
#
# Supervisor cluster creation
#
json_data='{
    "control_plane": {
        "count": 1,
        "login_banner": "'${supervisor_cluster_name}'-banner",
        "network": {
            "backing": {
                "backing": "NETWORK_SEGMENT",
                "network_segment": {
                    "networks": [ "'${network_id}'" ]
                }
            },
            "ip_management": {
                "dhcp_enabled": false,
                "gateway_address": "'$(echo ${segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).gateway_address')'",
                "ip_assignments": [ {
                    "assignee": "NODE",
                    "ranges": [ {
                        "address": "'$(echo ${segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).supervisor_starting_ip')'",
                        "count": '$(echo ${segments_overlay} | jq -c -r '.[] | select( .supervisor_mgmt == true).supervisor_count')'
                    } ]
                } ]
            },
            "network": "managementnetwork0",
            "proxy": {
                "proxy_settings_source": "VC_INHERITED"
            },
            "services": {
                "dns": {
                    "search_domains": [ "'${domain}'" ],
                    "servers": [ "'${ip_gw}'" ]
                },
                "ntp": {
                    "servers": [ "'${ip_gw}'" ]
                }
            }
        },
        "size": "'${supervisor_cluster_size}'",
        "storage_policy": "'${storage_policy_id}'"
    },
    "name": "'${supervisor_cluster_name}'",
    "workloads": {
        "edge": {
            "provider": "NSX_VPC"
        },
        "network": {
            "ip_management": {
                "dhcp_enabled": false,
                "gateway_address": "",
                "ip_assignments": [ {
                    "assignee": "SERVICE",
                    "ranges": [ {
                        "address": "'${supervisor_cluster_service_address}'",
                        "count": '${supervisor_cluster_service_address_count}'
                    } ]
                } ]
            },
            "network": "workloadnetwork0",
            "network_type": "NSX_VPC",
            "nsx_vpc": {
                "default_private_cidrs": [ {
                    "address": "'${supervisor_cluster_vpc_private_cidr_address}'",
                    "prefix": '${supervisor_cluster_vpc_private_cidr_prefix}'
                } ],
                "nsx_project": "/orgs/default/projects/'${supervisor_cluster_project_ref}'",
                "vpc_connectivity_profile": "/orgs/default/projects/'${supervisor_cluster_project_ref}'/vpc-connectivity-profiles/'${supervisor_cluster_vpc_profile}'"
            },
            "services": {
                "dns": {
                    "search_domains": [ "'${domain}'" ],
                    "servers": [ "'${ip_gw}'" ]
                },
                "ntp": {
                    "servers": [ "'${ip_gw}'" ]
                }
            }
        },
        "storage": {
            "ephemeral_storage_policy": "'${storage_policy_id}'",
            "image_storage_policy": "'${storage_policy_id}'"
        }
    }
}'
token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
vcenter_api 3 3 "POST" $token "${json_data}" ${vcsa_fqdn} "api/vcenter/namespace-management/supervisors/${cluster_id}?action=enable_on_compute_cluster"
sleep 600
#
#
#
retry_tanzu_supervisor=121
pause_tanzu_supervisor=60
attempt_tanzu_supervisor=1
while true ; do
  token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
  vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/namespace-management/clusters"
  if [[ $(echo $response_body | jq -c -r .[0].config_status) == "RUNNING" && $(echo $response_body | jq -c -r .[0].kubernetes_status) == "READY" ]]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, supervisor config_status is $(echo $response_body | jq -c -r .[0].config_status) and kubernetes_status is $(echo $response_body | jq -c -r .[0].kubernetes_status) after ${attempt_tanzu_supervisor} attempts of ${pause_tanzu_supervisor} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
    break 2
  fi
  ((attempt_tanzu_supervisor++))
  if [ ${attempt_tanzu_supervisor} -eq ${retry_tanzu_supervisor} ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, Unable to get supervisor cluster config_status RUNNING and kubernetes_status READY after ${attempt_tanzu_supervisor} attempts of ${pause_tanzu_supervisor} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit
  fi
  sleep ${pause_tanzu_supervisor}
done
#
# Retrieve API server cluster endpoint
#
token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
vcenter_api 3 3 "GET" $token '' "${vcsa_fqdn}" "api/vcenter/namespace-management/clusters"
cluster_id=$(echo $response_body | jq -c -r .[0].cluster)
json_output_file="/home/ubuntu/vcenter/api_server_cluster_endpoint.json"
vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/namespace-management/clusters/${cluster_id}"
api_server_cluster_endpoint=$(echo $response_body | jq -c -r .api_server_cluster_endpoint)
if [ -z "${api_server_cluster_endpoint}" ] ; then exit 255 ; fi
echo '{"api_server_cluster_endpoint": "'${api_server_cluster_endpoint}'"}' | tee ${json_output_file}
#
# Init k8s config
#
export VCF_CLI_VSPHERE_PASSWORD=''${generic_password}''
vcf context create ${supervisor_cluster_name} --auth-type basic --username administrator@${ssoDomain} --endpoint=${api_server_cluster_endpoint} --insecure-skip-tls-verify
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${supervisor_cluster_name}/${supervisor_cluster_name}/" /home/ubuntu/templates/auth_supervisor_custer.sh.template | tee /home/ubuntu/vks/auth_supervisor_custer.sh > /dev/null
chmod u+x /home/ubuntu/vks/auth_supervisor_custer.sh
sed -e "s/\${generic_password}/${generic_password}/" \
    -e "s/\${api_server_cluster_endpoint}/${api_server_cluster_endpoint}/" \
    -e "s/\${ssoDomain}/${ssoDomain}/" /home/ubuntu/templates/auth_vks_context.sh.template | tee /home/ubuntu/vks/auth_vks_context.sh > /dev/null
chmod u+x /home/ubuntu/vks/auth_vks_context.sh

#
#
#
touch ${resultFile}