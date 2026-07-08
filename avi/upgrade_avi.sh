#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/avi/avi_api.sh
#
#
#
date_index=$(date '+%Y%m%d%H%M%S')
avi_cookie_file="/tmp/$(basename $0 | cut -d"." -f1)_${date_index}_cookie.txt"
fqdn=${ip_avi}
username='admin'
password=''${generic_password}''
#
# VCF 9.1 to retrieve avi_version
#
if [[ ${vcf_version_two_digit} == "9.1" ]]; then
  #
  # retrieving version from sddcm
  #
  sddcm="${basename_sddc}-sddcm.${domain}"
  sddcmuser="${vsphere_nested_username}@${ssoDomain}"
  sddcmpass=''${generic_password}''
  loginpayload=$(printf '{"username" : "%s","password": "%s"}' $sddcmuser $sddcmpass)
  sddcm_token=$(curl -s -H 'Content-Type:application/json' https://$sddcm/v1/tokens -d "$loginpayload" -k | jq -c -r .'accessToken')
  if [ -z "$sddcm_token" ] || [ "$sddcm_token" == "null" ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, avi config: sddcm_token is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 100
  fi
  avi_version=$(curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X GET "https://$sddcm/v1/bundles" | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .version' | cut -d"-" -f1)
fi
#
# API auth
#
curl_login=$(curl -s -k -X POST -H "Content-Type: application/json" \
                                -d "{\"username\": \"${username}\", \"password\": \"${password}\"}" \
                                -c ${avi_cookie_file} https://${fqdn}/login)
csrftoken=$(cat ${avi_cookie_file} | grep csrftoken | awk '{print $7}')
if [ -z "$csrftoken" ] || [ "$csrftoken" == "null" ]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, avi config: csrftoken is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
  exit 100
fi
avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "*" "${avi_version}" "" "${fqdn}" "api/version/controller"
current_version=$(echo ${response_body} | jq -c -r '.[0].version' | cut -d")" -f1 | tr '(' '-')
target_version=$(basename "${avi_pkg_url}" .pkg | cut -d"-" -f2-3)
if [[ ${current_version} == ${target_version} ]]; then
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, Avi no upgrade required" "${log_file}" "" ""
else
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, Avi upgrade required" "${log_file}" "" ""
  if [ -f "/home/ubuntu/avi/$(basename ${avi_pkg_url})" ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, starts upgrade from ${current_version} to ${target_version}" "${log_file}" "${slack_webhook}" "${google_webhook}"
    avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "" "${fqdn}" "api/image" "/home/ubuntu/avi/$(basename ${avi_pkg_url})"
    image_uuid=$(echo ${response_body} | jq -c -r '.uuid')
    sleep 10
    json_data='
    {
      "image_uuid": "'${image_uuid}'",
      "system": true,
      "skip_warnings": true,
      "dryrun": false,
      "prechecks_only": false,
      "se_group_options":
        {
          "action_on_error": "CONTINUE_UPGRADE_OPS_ON_ERROR"
        }
    }'
    # {"image_uuid":"image-cea104fb-4c43-4ebb-8aed-5c8ca52aa62f","controller_patch_uuid":"","se_patch_uuid":"","system":true,"skip_warnings":false,"dryrun":false,"prechecks_only":false,"se_group_options":{"action_on_error":"CONTINUE_UPGRADE_OPS_ON_ERROR"}}
    avi_api 2 2 "POST" "${avi_cookie_file}" "${csrftoken}" "admin" "${avi_version}" "${json_data}" "${fqdn}" "api/upgrade"
    echo "waiting for 1200 seconds"
    sleep 1200
    # test ctrl https
    retry=10 ; pause=60 ; attempt=1
    while true
    do
      test=$(curl -k -o /dev/null -s --write-out "\n%{http_code}" https://${fqdn}/api/initial-data)
      if [[ ${test} -eq 200 ]]; then
        echo "ctrl ${fqdn} is now ready"
        break
      fi
      ((attempt++))
      if [ ${attempt} -eq ${retry} ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, unable to reach https after ${retry} retries of ${pause} seconds after upgrade" "${log_file}" "${slack_webhook}" "${google_webhook}"
        exit 255
      fi
      sleep ${pause}
    done
    curl_login=$(curl -s -k -X POST -H "Content-Type: application/json" \
                                    -d "{\"username\": \"${username}\", \"password\": \"${password}\"}" \
                                    -c ${avi_cookie_file} https://${fqdn}/login)
    csrftoken=$(cat ${avi_cookie_file} | grep csrftoken | awk '{print $7}')
    #
    avi_api 2 2 "GET" "${avi_cookie_file}" "${csrftoken}" "*" "${avi_version}" "" "${fqdn}" "api/upgradestatusinfo"
    failed_items=$(echo ${response_body} | jq -c -r '.results[] | select(.version != null and (.version | startswith("'${target_version}'")) and .state.state != "UPGRADE_FSM_COMPLETED")')
    if [ -n "$failed_items" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, Avi has not been upgraded to ${target_version}" "${log_file}" "${slack_webhook}" "${google_webhook}"
      echo "$failed_items"
      exit 255
    else
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, Avi has been upgraded to ${target_version}" "${log_file}" "${slack_webhook}" "${google_webhook}"
    fi
  else
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, cannot upgrade Avi because /home/ubuntu/avi/$(basename ${avi_pkg_url}) does not exist" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 255
  fi
fi
#
#
#
touch ${resultFile}