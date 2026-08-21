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
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, Create VCF Installer API session" "${log_file}" "" ""
  /home/ubuntu/bash/sddc_manager/create_api_session.sh "admin@local" ''$(jq -c -r .generic_password $jsonFile)'' ${ip_vcf_installer} /tmp/token_vcfi.json
  #
  # Add the token for 9.0 use case
  #
  if [[ ${vcf_version_two_digit} == "9.0" ]]; then
    sddc_manager_api 3 2 PUT '{"vmwareAccount" : {"downloadToken" : "'${vcf_installer_token}'"}}' ${ip_vcf_installer} v1/system/settings/depot $(jq -c -r .accessToken /tmp/token_vcfi.json)
  fi
  #
  # Find the machineId for 9.1 use case and update the depot config with the obtained activation_code
  #
  if [[ ${vcf_version_two_digit} == "9.1" ]]; then
    #
    # Patch the VCF Installer appliance's lcm/domainmanager config before
    # driving its API further - doing this after already using the API
    # would mean the service restarts below interrupt in-flight calls.
    # Confirmed empirically (epc-vapp project, VCD-based nested lab): the
    # "vcf" account's sudo access is restricted to a single support-bundle
    # command (`sudo -l` only allows /opt/vmware/sddc-support/sos) - real
    # root access is via `su -` with the root password (= generic_password),
    # and `su` refuses to run without a real controlling terminal ("must be
    # run from a terminal"), so a plain ssh+heredoc can't drive its password
    # prompt - this needs expect instead.
    #
    export VCF_ROOT_PASSWORD="$(jq -c -r .generic_password $jsonFile)"
    export VCF_INSTALLER_IP="${ip_vcf_installer}"

    # Points lcm/domainmanager at the staging depot+license-service
    # infrastructure instead of production defaults - built here (real bash
    # variables, no escaping needed) and relayed through the ssh/expect
    # layers as base64, since the domainmanager line is a JSON blob full of
    # double quotes that would otherwise have to survive bash heredoc ->
    # Tcl string -> remote-shell quoting all at once. lcm_depot_host,
    # lcm_depot_metadata_dir, lcm_depot_vcenter_upgrade_info_dir, vvs_host,
    # vvs_lcm_bundle_path, vvs_interop_bundle_path,
    # vvs_vlcm_interop_vcg_bundle_path, vsan_hcl_host, packages_host need to
    # be defined in variables.sh alongside vcf_installer_bearer_url etc.
    lcm_patch_b64=$(printf '%s\n%s\n%s\n%s\n' \
      "lcm.depot.adapter.host=${lcm_depot_host}" \
      "lcm.depot.adapter.remote.vcfMetadataDir=${lcm_depot_metadata_dir}" \
      "lcm.depot.adapter.vCenterUpgradeInfoDir=${lcm_depot_vcenter_upgrade_info_dir}" \
      "lcm.access_token.broadcom.authorization.server.url=${vcf_installer_bearer_url}" \
      | base64 -w0)
    dm_override_json=$(printf '{"publicDepotHost":"%s","authorizationServer":"%s","publicVvsHost":"%s","publicVvsVcfLcmBundlePath":"%s","publicVvsVcfInteropBundlePath":"%s","publicVvsVlcmInteropVcgBundlePath":"%s","publicVsanHclHost":"%s","publicPackagesHost":"%s"}' \
      "${lcm_depot_host}" "${vcf_installer_bearer_url}" "${vvs_host}" "${vvs_lcm_bundle_path}" "${vvs_interop_bundle_path}" "${vvs_vlcm_interop_vcg_bundle_path}" "${vsan_hcl_host}" "${packages_host}")
    dm_patch_b64=$(printf 'lcm.depot.service.online.config.override=%s\n' "${dm_override_json}" | base64 -w0)
    export VCF_LCM_PATCH_B64="${lcm_patch_b64}"
    export VCF_DM_PATCH_B64="${dm_patch_b64}"

    # The staging depot host/URLs above only take effect once these
    # production defaults are cleared out of the way (remote.v2.rootDir/
    # port have no staging equivalent at all, so leaving them active
    # conflicts with the appended settings rather than being harmlessly
    # superseded) and cert checking is disabled (the staging depot doesn't
    # present a cert the default enableCertCheck=true would accept).
    # Confirmed by diffing a real patched appliance against its own
    # pre-patch backup. Static/structural, not deployment-specific, so
    # hardcoded here.
    lcm_sed_fix_b64=$(base64 -w0 <<'SED_FIX_EOF'
sed -i '/^lcm\.depot\.adapter\.host=dl\.broadcom\.com$/d;/^lcm\.depot\.adapter\.port=443$/d;/^lcm\.depot\.adapter\.remote\.v2\.rootDir=\/PROD$/d' /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties
sed -i 's/^lcm\.depot\.adapter\.certificateCheckEnabled=true$/lcm.depot.adapter.certificateCheckEnabled=false/' /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties
SED_FIX_EOF
)
    export VCF_LCM_SED_FIX_B64="${lcm_sed_fix_b64}"

    expect <<'VCFI_EXPECT_EOF'
set timeout 30
set password $env(VCF_ROOT_PASSWORD)
spawn ssh -tt -o StrictHostKeyChecking=no vcf@$env(VCF_INSTALLER_IP)
expect "*assword:" { send "$password\r" }
expect "*$ " { send "su -\r" }
expect "*assword:" { send "$password\r" }
expect "*# " { send "cp /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties.bck\r" }
expect "*# " { send "cp /etc/vmware/vcf/domainmanager/application-prod.properties /etc/vmware/vcf/domainmanager/application-prod.properties.bck\r" }
expect "*# " { send "echo $env(VCF_LCM_SED_FIX_B64) | base64 -d | bash\r" }
expect "*# " { send "echo $env(VCF_LCM_PATCH_B64) | base64 -d | tee -a /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties > /dev/null\r" }
expect "*# " { send "echo $env(VCF_DM_PATCH_B64) | base64 -d | tee -a /etc/vmware/vcf/domainmanager/application-prod.properties > /dev/null\r" }
expect "*# " {
  send "chown vcf_lcm:vcf /opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties\r"
}
expect "*# " { send "chown vcf_domainmanager:vcf /etc/vmware/vcf/domainmanager/application-prod.properties\r" }
expect "*# " {
  send "systemctl restart lcm.service\r"
}
expect "*# " { send "systemctl restart domainmanager\r" }
expect "*# " { send "exit\r" }
expect "*$ " { send "exit\r" }
expect eof
VCFI_EXPECT_EOF
    unset VCF_ROOT_PASSWORD VCF_LCM_PATCH_B64 VCF_DM_PATCH_B64 VCF_LCM_SED_FIX_B64
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: patched and restarted lcm/domainmanager services" "${log_file}" "${slack_webhook}" "${google_webhook}"

    # lcm/domainmanager just restarted - re-authenticate so the
    # machine-details call below uses a fresh session rather than the
    # token created (at the top of this script) before the restart.
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, Re-creating VCF Installer API session after patch/restart" "${log_file}" "" ""
    /home/ubuntu/bash/sddc_manager/create_api_session.sh "admin@local" ''$(jq -c -r .generic_password $jsonFile)'' ${ip_vcf_installer} /tmp/token_vcfi.json
    sddc_manager_api 3 2 GET '' ${ip_vcf_installer} v1/system/settings/depot/machine-details $(jq -c -r .accessToken /tmp/token_vcfi.json)
    vcfi_machineId=$(echo ${response_body} | jq -c -r '.machineId')
    if [ -z "$vcfi_machineId" ] || [ "$vcfi_machineId" == "null" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: vcfi_machineId is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
    fi
    sleep 3
    vcfi_access_token=$(curl --request POST \
          --url ${vcf_installer_bearer_url} \
          --header 'content-type: application/x-www-form-urlencoded' \
          --data client_id=${vcf_installer_client_id} \
          --data client_secret=${vcf_installer_client_secret} \
          --data grant_type=client_credentials | jq -c -r '.access_token')
    if [ -z "$vcfi_access_token" ] || [ "$vcfi_access_token" == "null" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: vcfi_access_token is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
    fi
    sleep 3
    vcfi_activation_code=$(curl --request POST \
      --url ${vcf_installer_token_url}/${vcf_installer_tenant_id}/${vcf_installer_token_url_suffix} \
      --header 'authorization: Bearer '${vcfi_access_token}'' \
      --header 'content-type: application/json' \
      --data '{
      "id": "'${vcfi_machineId}'",
      "name": "test123456"
      }' | jq -c -r '.activation_code')
    if [ -z "$vcfi_activation_code" ] || [ "$vcfi_activation_code" == "null" ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: vcfi_activation_code is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
    fi
    sleep 3
    sddc_manager_api 3 2 PUT '{"vmwareAccount" : {"downloadActivationCode" : "'${vcfi_activation_code}'"}}' ${ip_vcf_installer} v1/system/settings/depot $(jq -c -r .accessToken /tmp/token_vcfi.json)
  fi
  #
  # check that the depot bundle has been populated
  #
  retry_bundle=60 ; pause_bundle=10 ; attempt_bundle=1
  while true
  do
    sddc_manager_api 3 2 GET '' ${ip_vcf_installer} v1/bundles $(jq -c -r .accessToken /tmp/token_vcfi.json)
    bundles_count=$(echo ${response_body} | jq -c -r '.elements | length')
    if [[ ${bundles_count} -gt 0 ]] ; then
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
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: waiting 600 seconds" "${log_file}" "" ""
  sleep 600
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
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: Bundles are not downloaded after ${attempt_download} attempts of ${pause_download} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
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
  if [ -z "${sddc_validation_id}" ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: sddc_validation_id is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 100
  fi
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: sddc_validation_id: ${sddc_validation_id}" "${log_file}" "${slack_webhook}" "${google_webhook}"
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: waiting 300 seconds" "${log_file}" "" ""
  sleep 300
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
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: SDDC JSON validation item not SUCCEEDED - ${item}" "${log_file}" "${slack_webhook}" "${google_webhook}"
        done
        if [[ ${vcf_version_two_digit} == "9.1" ]]; then
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: v9.1 - ignoring the error" "${log_file}" "${slack_webhook}" "${google_webhook}"
        else
          log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, VCF-I: SDDC JSON validation not SUCCEEDED - exiting the automation" "${log_file}" "${slack_webhook}" "${google_webhook}"
          exit 100
        fi
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
  retry_build=180 ; pause_build=300 ; attempt_build=1 ; count_retry=1
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
log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: End of ${0%.*}.sh" "${log_file}" "${slack_webhook}" "${google_webhook}"
touch ${resultFile}