#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/vcfa/vcfa.sh
#
# Retrieve NSX Manager id and name
#
vcfa_api_endpoint="cloudapi/v1/nsxManagers"
http_method="GET"
json_data=''
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
nsx_manager_id=$(echo ${response_body} | jq -c -r '.values[0].id')
nsx_manager_name=$(echo ${response_body} | jq -c -r '.values[0].name')
#
# Retrieve Supervisor id and name
#
vcfa_api_endpoint="cloudapi/v1/supervisors"
http_method="GET"
json_data=''
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
supervisor_id=$(echo ${response_body} | jq -c -r '.values[0].supervisorId')
supervisor_name=$(echo ${response_body} | jq -c -r '.values[0].name')
#
# configure regions
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    vcfa_api_endpoint="cloudapi/v1/regions"
    http_method="POST"
    json_data='
    {
      "name": "'$(echo $item | jq -c -r '.name')'",
      "description": "",
      "nsxManager": {
        "name": "'${nsx_manager_name}'",
        "id": "'${nsx_manager_id}'"
      },
      "supervisors": [
        {
          "name": "'${supervisor_name}'",
          "id": "'${supervisor_id}'"
        }
      ],
      "storagePolicies": [
        "'${default_storage_class}'"
      ]
    }'
    vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
    if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
  fi
done < <(echo "${vcf_a_regions}" | jq -c -r .[])
#
# Create external IP space for the external connection
#
while read item
do
  if [ -n "$item" ] && [ "$item" != "null" ]; then
    #
    # Retrieve region id
    #
    vcfa_api_endpoint="cloudapi/v1/regions"
    http_method="GET"
    json_data=''
    vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
    if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
    region_id=$(echo ${response_body} | jq -c -r --arg arg "'$(echo ${item} | jq -c -r '.region_ref')'" '.values[] | select(.name == $arg) | .id')
    #
    # Create external IP space for the external connection
    #
    vcfa_api_endpoint="cloudapi/v1/ipSpaces"
    http_method="POST"
    json_data='
    {
      "name": "'$(echo ${item} | jq -c -r '.name')'",
      "id": "'$(echo ${item} | jq -c -r '.name')'",
      "description":"",
      "internalScopeCidrBlocks": [
        {
           "cidr": "'$(echo ${item} | jq -c -r '.cidr')'"
        }
      ],
      "ipAddressRanges":[],
      "reservedIpAddressRanges":[],
      "providerVisibilityOnly":false,
      "defaultQuota":
        {
          "maxSubnetSize":1,
          "maxCidrCount":-1,
          "maxIpCount":-1
        },
      "regionRef": {
        "id": "'${region_id}'"
      }
    }'
    echo $json_data | jq .
    #{"name":"test-ip-space","description":"","regionRef":{"id":"urn:vcloud:region:f8c8ad0d-0d1c-4825-b152-7da5aa09bc8f"},"internalScopeCidrBlocks":[{"cidr":"192.168.250.0/24"}],"ipAddressRanges":[],"reservedIpAddressRanges":[],"providerVisibilityOnly":false,"defaultQuota":{"maxSubnetSize":1,"maxCidrCount":-1,"maxIpCount":-1}}
    vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
    if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
  fi
done < <(echo "${vcf_a_ip_spaces}" | jq -c -r .[])
#
# Create external connection for the org
#
vcfa_api_endpoint="cloudapi/v1/providerGateways"
http_method="POST"
json_data='{"name":"test-ui-ext","description":"","orgRef":null,"backingRef":{"id":"t0-01","name":"t0-01"},"backingType":"NSX_TIER0","regionRef":{"id":"urn:vcloud:region:f8c8ad0d-0d1c-4825-b152-7da5aa09bc8f"},"inboundRemoteNetworks":null,"natConfig":null,"allowAdvertisingPrivateIpBlocks":false,"ipSpaceRefs":[{"id":"urn:vcloud:ipSpace:0625fa89-a15f-457c-b065-91b7e6b72a42","name":"test-ui"}]}'
echo $json_data | jq .
#{"name":"test3","description":"","regionRef":{"id":"urn:vcloud:region:4fa7269f-c0d2-45cb-a498-8226d10be9a9"},"internalScopeCidrBlocks":[{"cidr":"192.168.246.0/24"}],"ipAddressRanges":[],"reservedIpAddressRanges":[],"providerVisibilityOnly":false,"defaultQuota":{"maxSubnetSize":1,"maxCidrCount":-1,"maxIpCount":-1}}
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
#
# configure org
#
vcfa_api_endpoint="cloudapi/1.0.0/orgs"
http_method="POST"
json_data='
{
  "name": "org-1",
  "displayName": "org-1",
  "isClassicTenant":false,
  "isEnabled": true
}'
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
#
# Retrieve org id
#
vcfa_api_endpoint="cloudapi/1.0.0/orgs"
http_method="GET"
json_data=''
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
org_id=$(echo ${response_body} | jq -c -r --arg arg "org-1" '.values[] | select(.name == $arg) | .id')
#
# Create virtual dc
#
vcfa_api_endpoint="cloudapi/v1/virtualDatacenters"
http_method="POST"
json_data='{"name":"org-1_region-1","org":{"id":"'${org_id}'"},"region":{"id":"'${region_id}'"},"supervisors":[{"name":"'${supervisor_name}'","id":"'${supervisor_id}'"],"zoneResourceAllocation":[{"zone":{"id":"'${zone_id}'","name":"'${zone_name}'"},"resourceAllocation":{"cpuLimitMHz":100000,"cpuReservationMHz":0,"memoryLimitMiB":65536,"memoryReservationMiB":0}}],"isFullAllocation":false,"description":null}'
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
#
# Retrieve DC id
#
vcfa_api_endpoint="cloudapi/v1/virtualDatacenters"
http_method="GET"
json_data=''
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
virtual_dc_id=$(echo ${response_body} | jq -c -r --arg arg "org-1_region-1" '.values[] | select(.name == $arg) | .id')
#
# Retrieve VM classes
#
vcfa_api_endpoint="cloudapi/v1/virtualMachineClasses"
http_method="GET"
json_data=''
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
vm_classes=$(echo ${response_body} | jq -c -r '[.values[] | {id, name}]')
#
# Assign VM class
#
vcfa_api_endpoint="cloudapi/v1/virtualDatacenters/${virtual_dc_id}/virtualMachineClasses"
http_method="PUT"
json_data='{"values":[{"name":"best-effort-2xlarge","id":"urn:vcloud:virtualMachineClass:d6e968bf-f0d5-571b-bfca-448e988fbec8"},{"name":"best-effort-4xlarge","id":"urn:vcloud:virtualMachineClass:f51b6c68-27cc-50ac-83c4-0947e01817e7"},{"name":"best-effort-8xlarge","id":"urn:vcloud:virtualMachineClass:a10e4a78-f863-5aa2-af22-79e652c43dd2"},{"name":"best-effort-large","id":"urn:vcloud:virtualMachineClass:9612fd4a-b323-5922-ba7d-b256b641d6de"},{"name":"best-effort-medium","id":"urn:vcloud:virtualMachineClass:5fc7cc53-a615-5270-bb44-b4c0e599ba91"},{"name":"best-effort-small","id":"urn:vcloud:virtualMachineClass:1353aa86-5cf5-5c5b-912d-fa15e2baab26"},{"name":"best-effort-xlarge","id":"urn:vcloud:virtualMachineClass:569fe32c-9439-596b-b24b-dfde86c8a9ad"},{"name":"best-effort-xsmall","id":"urn:vcloud:virtualMachineClass:7b7212fa-9ce3-544b-8125-209222ac5473"},{"name":"guaranteed-2xlarge","id":"urn:vcloud:virtualMachineClass:f0bf73db-f9e5-56d4-bff4-8982b0c2b5a7"},{"name":"guaranteed-4xlarge","id":"urn:vcloud:virtualMachineClass:623d616f-f4c0-5663-b1d9-8647d561ecfe"},{"name":"guaranteed-8xlarge","id":"urn:vcloud:virtualMachineClass:67c50440-675f-52a9-a045-74a04975e7d7"},{"name":"guaranteed-large","id":"urn:vcloud:virtualMachineClass:faf2998c-fa58-5436-83bb-c3062d1ef167"},{"name":"guaranteed-medium","id":"urn:vcloud:virtualMachineClass:8eb595ab-8b5a-5605-8932-fb48da28ca14"},{"name":"guaranteed-small","id":"urn:vcloud:virtualMachineClass:42b4529d-cda3-5264-81dd-b87859366d52"},{"name":"guaranteed-xlarge","id":"urn:vcloud:virtualMachineClass:9522173b-0e03-56b5-8483-a44e2544fb8c"},{"name":"guaranteed-xsmall","id":"urn:vcloud:virtualMachineClass:35593c48-dabe-5663-b187-925e090c3b3e"}]}'
json_data='{"values":'${vm_classes}'}'
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
#
# Retrieve Storage Policy
#
vcfa_api_endpoint="cloudapi/v1/regionStoragePolicies"
http_method="GET"
json_data=''
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
storage_policy_id=$(echo ${response_body} | jq -c -r --arg arg "sddc01-cluster vSAN Storage Policy" '.values[] | select(.name == $arg) | .id')
#
# Assign Storage Policies
#
vcfa_api_endpoint="cloudapi/v1/virtualDatacenters/${virtual_dc_id}/virtualDatacenterStoragePolicies"
http_method="PUT"
json_data='{"values":[{"regionStoragePolicy":{"id":"'${storage_policy_id}'"},"storageLimitMiB":102400,"virtualDatacenter":{"id":"'${virtual_dc_id}}'"}}]}'
json_data='{"values":'${vm_classes}'}'
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
#
# Regionnal Network Settings
#
vcfa_api_endpoint="cloudapi/v1/regionalNetworkingSettings"
http_method="POST"
json_data='{"orgRef":{"name":"'${org-name}'","id":"'${org_id}'"},"regionRef":{"name":"'${region_name}'","id":"'${region_id}'"},"providerGatewayRef":{"name":"'${provider_gw_name}'","id":"'${provider_gw_id}'"},"serviceEdgeClusterRef":{"name":"'${edge_cluster_name}'","id":"'${edge_cluster_id}'"},"defaultVpcPrivateSubnetCidrOverride":"172.30.0.0/16","projectTgwPrivateSubnetCidrOverride":"172.31.0.0/16"}'
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi
#
# [ fa56ae4e-7538-4f63-a66a-f6b07ee08c75 ] Provider Gateway test-ui must be backed by a shared Gateway Connection. Please edit and save Provider Gateway test-ui to generate a shared Gateway Connection.
#
#
# Assign a user to the VCF-A org
#
vcfa_api_endpoint="cloudapi/1.0.0/users"
http_method="POST"
json_data='{"username":"nicolas.bayle@broadcom.com","password":"sGN#FBiN@UKY1!67","roleEntityRefs":[{"id":"urn:vcloud:role:e18297e0-91c7-5a16-91c8-2b6584abf9b9","name":"Organization Administrator"}],"providerType":"LOCAL"}'
vcfa_api ${fqdn_vcfa} ${generic_password} ${vcfa_api_endpoint} ${http_method} "${json_data}" 2 2
if [[ ${vcfa_api_state} == "FAIL" ]]; then log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: VCF-A API ${http_method} call to ${fqdn_vcfa}/${vcfa_api_endpoint} FAILED" "${log_file}" "${slack_webhook}" "${google_webhook}"; fi

