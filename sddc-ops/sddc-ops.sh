#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
#
#
#
vcf_ops_token=$(curl -s -k -X 'POST' \
        'https://'${basename_sddc}'-ops01.'${domain}'/suite-api/api/auth/token/acquire?_no_links=true' \
        -H 'accept: application/json' \
        -H 'Content-Type: application/json' \
        -d '{
              "username": "admin",
              "authSource": "local",
              "password": "'${generic_password}'"
            }' \
        | jq -c -r '.token')
if [ -z "$vcf_ops_token" ] || [ "$vcf_ops_token" == "null" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-Ops: vcf_ops_token is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
  exit 255
fi