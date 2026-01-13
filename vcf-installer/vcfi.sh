#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/sddc_manager/sddc_manager_api.sh
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
#
if [[ ${name_vcf_installer} != "null" ]]; then
  log_message "Create VCF Installer API session" "${log_file}" "" ""
  /home/ubuntu/bash/sddc_manager/create_api_session.sh "admin@local" ''$(jq -c -r .generic_password $jsonFile)'' ${ip_vcf_installer} /tmp/token_vcfi.json
  sddc_manager_api 3 2 PUT '{"vmwareAccount" : {"downloadToken" : "'${vcf_installer_token}'"}}' ${ip_vcf_installer} v1/system/settings/depot $(jq -c -r .accessToken /tmp/token_vcfi.json)
  retry_bundle=60 ; pause_bundle=10 ; attempt_bundle=1
  while true
  do
    sddc_manager_api 3 2 GET '' ${ip_vcf_installer} v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
    bundles_count=$(echo ${response_body} | jq -c -r '.elements | length')
    if [[ bundles_count -gt 0 ]] ; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: bundles are populated" "${log_file}" "" ""
      sleep 30
      break
    fi
    if [ $attempt_bundle -eq $retry_bundle ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: Bundles are not populated after ${attempt_bundle} attempts of ${pause_bundle} seconds" "${log_file}" "" ""
      exit
    fi
    sleep ${pause_bundle}
    ((attempt_bundle++))
  done
  sddc_manager_api 3 2 GET '' ${ip_vcf_installer} v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
  depots_ids=$(echo ${response_body} | jq --arg arg ${vcf_version} '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.version | startswith($arg))) | .id]')
  depots_to_download=$(echo ${response_body} | jq --arg arg ${vcf_version} '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.version | startswith($arg))) | .id ] | length')
  echo ${depots_ids} | jq -c -r .[] | while read depot_id
  do
    sddc_manager_api 3 2 PATCH '{"bundleDownloadSpec":{"downloadNow":true}}' ${ip_vcf_installer} v1/bundles/${depot_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: patching bundle ${depot_id} to download it" "${log_file}" "" ""
  done
  sleep 240
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: waiting 240 seconds" "${log_file}" "" ""
  #
  # download bundles
  #
  retry_download=60 ; pause_download=20 ; attempt_download=1
  while true
  do
    sddc_manager_api 3 2 GET '' ${ip_vcf_installer} v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
    depot_downloaded=$(echo ${response_body} | jq --arg arg ${vcf_version} '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.downloadStatus == "SUCCESSFUL") and (.version | startswith($arg))) ] | length')
    if [[ ${depot_downloaded} == ${depots_to_download} ]]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: all bundles downloaded" "${log_file}" "${slack_webhook}" "${google_webhook}"
      break
    else
      log_message "${depot_downloaded} on ${depots_to_download} bundles have been downloaded" "${log_file}" "" ""
    fi
    if [ $attempt_download -eq $retry_download ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: Bundles are not downloaded after ${attempt_download} attempts of ${pause_download} seconds" "${log_file}" "" ""
      exit
    fi
    sleep ${pause_download}
    ((attempt_download++))
  done
  #
  # validation json
  #
  sddc_manager_api 3 2 POST "@/home/ubuntu/json/${basename_sddc}.json" ${ip_vcf_installer} v1/sddcs/validations $(jq -c -r .accessToken /tmp/token_vcfi.json)
  sddc_validation_id=$(echo ${response_body} | jq -c -r .id)
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: sddc_validation_id: ${sddc_validation_id}" "${log_file}" "${slack_webhook}" "${google_webhook}"
  retry_validation=60 ; pause_validation=10 ; attempt_validation=1
  while true ; do
    log_message "attempt $attempt_validation to verify SDDC JSON validation" "${log_file}" "" ""
    sddc_manager_api 3 2 GET "" ${ip_vcf_installer} v1/sddcs/validations/${sddc_validation_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
    executionStatus=$(echo ${response_body} | jq -c -r .executionStatus)
    echo "Execution Status is: ${executionStatus}"
    if [[ ${executionStatus} == "COMPLETED" ]]; then
      sddc_manager_api 3 2 GET "" ${ip_vcf_installer} v1/sddcs/validations/${sddc_validation_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
      resultStatus=$(echo ${response_body} | jq -c -r .resultStatus)
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: SDDC JSON validation finished, result: ${resultStatus} after ${attempt_validation} attempt of ${pause_validation} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
      if [[ ${resultStatus} != "SUCCEEDED" ]] ; then
        echo ${response_body} | jq -c -r '[.validationChecks[] | select( .resultStatus != "SUCCEEDED").errorResponse.nestedErrors.[].message]' | jq -c -r .[] | while read item
        do
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: SDDC JSON validation not ERROR - ${item}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        done
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: SDDC JSON validation not SUCCEEDED - exiting the automation" "${log_file}" "${slack_webhook}" "${google_webhook}"
        exit
      fi
      break
    else
      sleep ${pause_validation}
    fi
    ((attempt_validation++))
    if [ $attempt_validation -eq $retry_validation ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC JSON validation not finished after $attempt_validation attempts of ${pause_validation} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit
    fi
  done
  #
  # sddc build
  #
  sddc_manager_api 3 2 POST "@/home/ubuntu/json/${basename_sddc}.json" ${ip_vcf_installer} v1/sddcs $(jq -c -r .accessToken /tmp/token_vcfi.json)
  sddc_id=$(echo ${response_body} | jq -c -r .id)
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: starting building sddc id ${sddc_id}" "${log_file}" "${slack_webhook}" "${google_webhook}"
  # validation_sddc creation
  retry_build=120 ; pause_build=300 ; attempt_build=1 ; count_retry=1
  while true ; do
    /home/ubuntu/bash/sddc_manager/create_api_session.sh "admin@local" ''$(jq -c -r .generic_password $jsonFile)'' ${ip_vcf_installer} /tmp/token_vcfi.json
    log_message "attempt $attempt_build to verify SDDC ${sddc_id} creation" "${log_file}" "" ""
    sddc_manager_api 3 2 GET "" ${ip_vcf_installer} v1/sddcs/${sddc_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
    sddc_status=$(echo ${response_body} | jq -c -r .status)
    if [[ ${sddc_status} != "IN_PROGRESS" ]]; then
      log_message "SDDC ${sddc_id} creation ${sddc_status} after attempt ${attempt_build} of ${pause_build} seconds, go to https://${ip_vcf_installer}" "${log_file}" "" ""
      if [[ ${sddc_status} != "COMPLETED_WITH_SUCCESS" ]]; then
        ((count_retry++))
        if [[ ${count_retry} == 3 ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC ${sddc_id} Creation status: ${sddc_status}, go to https://${ip_vcf_installer} - exiting the automation" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit
        fi
        sleep 600
        log_message "SDDC ${sddc_id} trying ${count_retry} times to apply after status ${sddc_status}" "${log_file}" "" ""
        sddc_manager_api 3 2 PATCH "" ${ip_vcf_installer} v1/sddcs/${sddc_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
      fi
      if [[ ${sddc_status} == "COMPLETED_WITH_SUCCESS" ]]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC ${sddc_id} Creation status: ${sddc_status}, go to https://${ip_vcf_installer}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        break
      fi
    else
      sleep ${pause_build}
    fi
    ((attempt_build++))
    if [ ${attempt_build} -eq ${retry_build} ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: SDDC ${sddc_id} Creation status: ${sddc_status}, go to https://${ip_vcf_installer} - exiting the automation" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit
    fi
  done
fi
touch ${resultFile}