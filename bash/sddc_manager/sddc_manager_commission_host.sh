#!/bin/bash
#
source /home/ubuntu/sddc_manager/sddc_manager_api.sh
#
jsonFile=${1}
esxi_fqdn=${2}
ip_sddc_manager="$(jq -c -r --arg arg "VM_MANAGEMENT" '.sddc.vcenter.networks[] | select( .type == $arg).cidr' $jsonFile | awk -F'0/' '{print $1}')$(jq -c -r .sddc.manager.ip ${jsonFile})"
basename_sddc=$(jq -c -r .sddc.basename $jsonFile)
slack_webhook=$(jq -c -r .slack_webhook $jsonFile)
SDDC_MANAGER_PASSWORD=$(jq -c -r .GENERIC_PASSWORD $jsonFile)
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
# get network pool id
#
sddc_manager_api 3 2 GET '' ${ip_sddc_manager} v1/network-pools $(jq -c -r .accessToken /tmp/token.json)
pool_id=$(echo $response_body | jq -c -r --arg arg "${basename_sddc}-mgmt-pool" '.elements[] | select( .name == $arg).id')
#
# validate host
#
sddc_manager_api 3 2 POST '[ { "fqdn" : "'${esxi_fqdn}'", "username" : "root", "password" : "'${SDDC_MANAGER_PASSWORD}'", "storageType" : "VSAN", "vvolStorageProtocolType" : null, "networkPoolId" : "'${pool_id}'", "networkPoolName" : "${basename_sddc}-mgmt-pool", "sshThumbprint" : null, "sslThumbprint" : null}] ' ${ip_sddc_manager} v1/hosts/validations $(jq -c -r .accessToken /tmp/token.json)
validation_id=$(echo $response_body | jq -c -r .id)
#
# Wait for validation to be done
#
retry_local=10
pause_local=30
attempt_local=1
while true ; do
  echo "attempt ${attempt_local} to get host validation spec"
  sddc_manager_api 3 2 GET '' ${ip_sddc_manager} v1/hosts/validations/${validation_id} $(jq -c -r .accessToken /tmp/token.json)
  if [[ $(echo $response_body | jq -c -r .executionStatus) == "COMPLETED" && $(echo $response_body | jq -c -r .resultStatus) == "SUCCEEDED" ]]; then
    echo "host validation .executionStatus is COMPLETED and .resultStatus is SUCCEEDED after ${attempt_local} attempts of ${pause_local} seconds"
    break 2
  fi
  ((attempt_local++))
  if [ ${attempt_local} -eq ${retry_local} ]; then
    echo "Unable to get host validation after ${attempt_local} attempts of ${pause_local} seconds"
    exit
  fi
  sleep ${pause_local}
done
#
# Commission host
#
sddc_manager_api 3 2 POST '[ { "fqdn" : "'${esxi_fqdn}'", "username" : "root", "password" : "'${SDDC_MANAGER_PASSWORD}'", "storageType" : "VSAN", "vvolStorageProtocolType" : null, "networkPoolId" : "'${pool_id}'", "networkPoolName" : "${basename_sddc}-mgmt-pool", "sshThumbprint" : null, "sslThumbprint" : null}] ' ${ip_sddc_manager} v1/hosts $(jq -c -r .accessToken /tmp/token.json)
task_id=$(echo $response_body | jq -c -r .id)
#
# Wait for HOST ready
#
retry_local=10
pause_local=30
attempt_local=1
while true ; do
  echo "attempt ${attempt_local} to get host ready"
  sddc_manager_api 3 2 GET '' ${ip_sddc_manager} v1/tasks/${task_id} $(jq -c -r .accessToken /tmp/token.json)
  if [[ $(echo $response_body | jq -c -r .status) == "Successful" ]]; then
    echo "host commissioning .status is Successful after ${attempt_local} attempts of ${pause_local} seconds"
    break 2
  fi
  ((attempt_local++))
  if [ ${attempt_local} -eq ${retry_local} ]; then
    echo "Unable to get host commissioned after ${attempt_local} attempts of ${pause_local} seconds"
    exit
  fi
  sleep ${pause_local}
done