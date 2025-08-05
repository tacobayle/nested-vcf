#!/bin/bash
#
source /home/ubuntu/sddc_manager/sddc_manager_api.sh
#
jsonFile=${1}
ip_sddc_manager="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.manager.ip ${jsonFile})"
basename_sddc=$(jq -c -r .sddc.basename $jsonFile)
slack_webhook=$(jq -c -r .slack_webhook $jsonFile)
SDDC_MANAGER_PASSWORD=$(jq -c -r .GENERIC_PASSWORD $jsonFile)
DEPOT_USERNAME=$(jq -c -r .depot.username $jsonFile)
DEPOT_PASSWORD=$(jq -c -r .depot.password $jsonFile)
ssoDomain=$(jq -c -r .sddc.vcenter.ssoDomain ${jsonFile})
count=1
until $(curl --output /dev/null --silent --head -k https://${ip_sddc_manager})
do
  echo "Attempt ${count}: Waiting for SDDC Manager at https://${ip_sddc_manager} to be reachable..."
  sleep 10
  count=$((count+1))
    if [[ "${count}" -eq 60 ]]; then
      echo "ERROR: Unable to connect to SDDC Manager at https://${ip_sddc_manager}"
      if [ -z "${slack_webhook}" ] ; then echo "ignoring slack update" ; else curl -X POST -H 'Content-type: application/json' --data '{"text":"'$(date "+%Y-%m-%d,%H:%M:%S")', nested-'${basename_sddc}': Unable to connect to SDDC Manager at https://'${ip_sddc_manager}'"}' ${slack_webhook} >/dev/null 2>&1; fi
      exit
    fi
done
#
# token creation
#
/bin/bash /home/ubuntu/sddc_manager/create_api_session.sh "administrator@${ssoDomain}" "${SDDC_MANAGER_PASSWORD}" ${ip_sddc_manager} /tmp/token.json
#
# create online depot
#
sddc_manager_api 3 2 PUT '{"vmwareAccount" : {"username" : "'${DEPOT_USERNAME}'", "password" : "'${DEPOT_PASSWORD}'"}}' ${ip_sddc_manager} v1/system/settings/depot $(jq -c -r .accessToken /tmp/token.json)
#
# check if bundle exists
#
retry=60 ; pause=10 ; attempt=1
while true
do
  sddc_manager_api 3 2 GET '' ${ip_sddc_manager} v1/bundles $(jq -c -r .accessToken /tmp/token.json)
  bundles=$(echo ${response_body} | jq -c -r '.')
  bundles_count=$(echo ${bundles} | jq -c -r '.elements | length')
  if [[ bundles_count -gt 0 ]] ; then
    echo "bundles are populated"
    break
  fi
  if [ $attempt -eq $retry ]; then
    echo "Bundles are not populated after ${attempt} attempts of ${pause} seconds" | tee -a ${log_file}
    exit
  fi
  sleep ${pause}
  ((attempt++))
done
