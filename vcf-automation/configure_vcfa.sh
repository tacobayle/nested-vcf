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
# configure region
#
vcfa_api_endpoint="cloudapi/v1/regions"
http_method="POST"
json_data='
{
  "name": "region-1",
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
#
# configure org
#
vcfa_api_endpoint="cloudapi/1.0.0/orgs"
http_method="POST"
json_data='
{
  "name": "org-1",
  "displayName": "org-1"
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

