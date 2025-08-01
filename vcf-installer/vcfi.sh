#!/bin/bash
#
jsonFile="${1}"
source /home/ubuntu/bash/sddc_manager/sddc_manager_api.sh
source /home/ubuntu/bash/variables.sh
#
if [[ ${name_vcf_installer} != "null" ]]; then
  echo "Create VCF Installer API session"
  /home/ubuntu/bash/sddc_manager/create_api_session.sh "admin@local" ''$(jq -c -r .generic_password $jsonFile)'' ${ip_vcf_installer} /tmp/token_vcfi.json
  sddc_manager_api 3 2 PUT '{"vmwareAccount" : {"downloadToken" : "'${vcf_installer_token}'"}}' ${ip_vcf_installer} v1/system/settings/depot $(jq -c -r .accessToken /tmp/token_vcfi.json)
  retry=60 ; pause=10 ; attempt=1
  while true
  do
    sddc_manager_api 3 2 GET '' ${ip_vcf_installer} v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
    bundles_count=$(echo ${response_body} | jq -c -r '.elements | length')
    if [[ bundles_count -gt 0 ]] ; then
      echo "bundles are populated"
      sleep 30
      break
    fi
    if [ $attempt -eq $retry ]; then
      echo "Bundles are not populated after ${attempt} attempts of ${pause} seconds"
      exit
    fi
    sleep ${pause}
    ((attempt++))
  done
  sddc_manager_api 3 2 GET '' ${ip_vcf_installer} v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
  depots_ids=$(echo ${response_body} | jq '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.version | startswith("9"))) | .id]')
  depots_to_download=$(echo ${response_body} | jq '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.version | startswith("9"))) | .id ] | length')
  echo ${depots_ids} | jq -c -r .[] | while read depot_id
  do
    sddc_manager_api 3 2 PATCH '{"bundleDownloadSpec":{"downloadNow":true}}' ${ip_vcf_installer} v1/bundles/${depot_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
    echo "patching bundle ${depot_id} to download it"
  done
  sleep 240
  retry=60 ; pause=10 ; attempt=1
  while true
  do
    sddc_manager_api 3 2 GET '' ${ip_vcf_installer} v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
    depot_downloaded=$(echo ${response_body} | jq '[.elements[] | select ((.components[0].imageType == "INSTALL") and (.downloadStatus == "SUCCESSFUL") and (.version | startswith("9"))) ] | length')
    if [[ ${depot_downloaded} == ${depots_to_download} ]]; then
      echo "all bundles downloaded"
      if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': VCF installer all bundles downloaded"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
      break
    else
      echo "${depot_downloaded} on ${depots_to_download} bundles have been downloaded"
    fi
    if [ $attempt -eq $retry ]; then
      echo "Bundles are not downloaded after ${attempt} attempts of ${pause} seconds"
      exit
    fi
    sleep ${pause}
    ((attempt++))
  done
  # validation json
  sddc_manager_api 3 2 POST "@/home/ubuntu/json/${basename_sddc}.json" ${ip_vcf_installer} v1/sddcs/validations $(jq -c -r .accessToken /tmp/token_vcfi.json)
  sddc_validation_id=$(echo ${response_body} | jq -c -r .id)
  retry=60 ; pause=10 ; attempt=1
  while true ; do
    echo "attempt $attempt to verify SDDC JSON validation"
    sddc_manager_api 3 2 GET "" ${ip_vcf_installer} v1/sddcs/validations/${sddc_validation_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
    executionStatus=$(echo ${response_body} | jq -c -r .executionStatus)
    if [[ ${executionStatus} == "COMPLETED" ]]; then
      sddc_manager_api 3 2 GET "" ${ip_vcf_installer} v1/sddcs/validations/${sddc_validation_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
      resultStatus=$(echo ${response_body} | jq -c -r .resultStatus)
      echo "SDDC JSON validation: ${resultStatus} after $attempt of ${pause} seconds"
      if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC JSON validation: '${resultStatus}'"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
      if [[ ${resultStatus} != "SUCCEEDED" ]] ; then exit ; fi
      break
    else
      sleep $pause
    fi
    ((attempt++))
    if [ $attempt -eq $retry ]; then
      echo "SDDC JSON validation not finished after $attempt attempts of ${pause} seconds"
      if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC JSON validation not finished after '${attempt}' attempts of '${pause}' seconds"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
      exit
    fi
  done
  # sddc build
  echo "starting sddc build"
  sddc_manager_api 3 2 POST "@/home/ubuntu/json/${basename_sddc}.json" ${ip_vcf_installer} v1/sddcs $(jq -c -r .accessToken /tmp/token_vcfi.json)
  sddc_id=$(echo ${response_body} | jq -c -r .id)
  # validation_sddc creation
  echo "SDDC ${sddc_id} trying ${count_retry} times to apply"
  retry=120 ; pause=300 ; attempt=1 ; count_retry=1
  while true ; do
    echo "attempt $attempt to verify SDDC ${sddc_id} creation"
    sddc_manager_api 3 2 GET "" ${ip_vcf_installer} v1/sddcs/${sddc_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
    sddc_status=$(echo ${response_body} | jq -c -r .status)
    if [[ ${sddc_status} != "IN_PROGRESS" ]]; then
      echo "SDDC ${sddc_id} creation ${sddc_status} after attempt $attempt of ${pause} seconds, go to https://${ip_vcf_installer}"
      if [[ ${sddc_status} != "COMPLETED_WITH_SUCCESS" ]]; then
        ((count_retry++))
        if [[ ${count_retry} == 3 ]]; then
          echo "nested-'${basename_sddc}': SDDC '${sddc_id}' Creation status: '${sddc_status}', go to https://'${ip_vcf_installer}'"
          if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC '${sddc_id}' Creation status: '${sddc_status}', go to https://'${ip_vcf_installer}'"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
          exit
        fi
        sleep 600
        echo "SDDC ${sddc_id} trying ${count_retry} times to apply after status ${sddc_status}"
        sddc_manager_api 3 2 PATCH "" ${ip_vcf_installer} v1/sddcs/${sddc_id} $(jq -c -r .accessToken /tmp/token_vcfi.json)
      fi
      if [[ ${sddc_status} == "COMPLETED_WITH_SUCCESS" ]]; then
        echo "nested-'${basename_sddc}': SDDC '${sddc_id}' Creation status: '${sddc_status}', go to https://'${ip_vcf_installer}'"
        if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC '${sddc_id}' Creation status: '${sddc_status}', go to https://'${ip_cb}'"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
        break
      fi
    else
      sleep $pause
    fi
    ((attempt++))
    if [ $attempt -eq $retry ]; then
      echo "SDDC ${sddc_id} creation not finished after $attempt attempt of ${pause} seconds"
      if [ -z "${SLACK_WEBHOOK_URL}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': SDDC '${sddc_id}' Creation not finished after '${attempt}' attempts of '${pause}' seconds"}' ${SLACK_WEBHOOK_URL} >/dev/null 2>&1; fi
      exit
    fi
  done
fi