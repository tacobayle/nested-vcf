#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh


# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local LOG_FILE="${log_file}"
    echo -e "${timestamp} [${level}] ${message}" >> "${LOG_FILE}"

    case $level in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} ${message}"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} ${message}"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING]${NC} ${message}"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} ${message}"
            ;;
        *)
            echo -e "[${level}] ${message}"
            ;;
    esac
}

sddcm="${basename_sddc}-sddcm.${domain}"
sddcmuser="${vsphere_nested_username}@${ssoDomain}"
sddcmpass=''${generic_password}''
loginpayload=$(printf '{"username" : "%s","password": "%s"}' $sddcmuser $sddcmpass)

if [[ ${vcf_version_two_digit} == "9.0" ]]; then
  #
  # VCF 9.0 use case
  #
  export SSHPASS=''${generic_password}''
  pvcfile="/home/ubuntu/sddc-manager/pvc.json"
  sigfile="/home/ubuntu/sddc-manager/pvc.sig"
  ovapath="/home/ubuntu/sddc-manager/$(basename ${avi_ova_url_sddc_manager})"
  avi_product_version="${avi_product_version_sddc_manager}"
  log "INFO" "Creating folder to store pvc files and Avi binary"
  sshpass -e ssh -o StrictHostKeyChecking=no vcf@$sddcm 'mkdir -p /home/vcf/avi'
  log "INFO" "Copying pvc files and Avi binary to SDDC manager"
  sshpass -e scp -o StrictHostKeyChecking=no $pvcfile $sigfile $ovapath vcf@$sddcm:/home/vcf/avi
  response=$(curl -s -H 'Content-Type:application/json' https://$sddcm/v1/tokens -d "$loginpayload" -k)
  TOKEN=$(echo $response | grep -o '"accessToken": *"[^"]*' | sed 's/"accessToken":"//')
  response=$(curl -s -k -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X PATCH "https://$sddcm/v1/product-version-catalogs" \
  --header 'X-Allow-Overwrite: True' \
  --header 'Content-Type: application/json' \
  --data '{
              "productVersionCatalogFilePath": "/home/vcf/avi/pvc.json",
              "signatureFilePath": "/home/vcf/avi/pvc.sig"
          }')
  task_id=$(echo $response | grep -o '"taskId": *"[^"]*' | sed 's/"taskId":"//')
  # Poll on the task using /v1/product-version-catalogs/upload-tasks/{task_id} API
  while true; do
      response=$(curl -s -k -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X GET "https://$sddcm/v1/product-version-catalogs/upload-tasks/$task_id")
      log "$response"
      status=$(echo $response | grep -o '"status": *"[^"]*' | sed 's/"status":"//')
      # Check if the status is success/failure/in-progress
      if [[ "$status" == "SUCCEEDED" ]]; then
          log "SUCCESS" "Product version catalogs successfully updated for AVI"
          break
      elif [[ "$status" == "FAILED" ]]; then
          log "ERROR" "$response"
          exit 1
      fi

      echo "Checking Product version catalogs update status in 5 seconds..."
      sleep 5
  done
  # Upload Avi bundle to SDDC manager
  # POST /v1/product-binaries
  ova_upload_payload=$(printf '{"productType": "NSX_ALB", "productVersion": %s, "imageType": "INSTALL", "folderPath": "/home/vcf/avi"}' "$avi_product_version")
  response=$(curl -s -k -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -X POST "https://$sddcm/v1/product-binaries" \
  --header 'Content-Type: application/json' \
  --data "$ova_upload_payload")
  TASK_ID=$(echo $response | grep -o '"id": *"[^"]*' | sed 's/"id":"//')
  if [[ "$TASK_ID" != "" ]]; then
      log "SUCCESS" "AVI OVA UPLOAD STARTED: $response"
  else
      ERROR_MSG=$(echo $response | grep -o '"errorCode": *"[^"]*' | sed 's/"errorCode":"//')
      if [[ "$ERROR_MSG" != "" ]]; then
          log "ERROR" "AVI OVA UPLOAD FAILED: $response"
      fi
      exit 1
  fi
  #
  # VCF 9.1 use case
  #
elif [[ ${vcf_version_two_digit} == "9.1" ]]; then
  sddcm_token=$(curl -s -H 'Content-Type:application/json' https://$sddcm/v1/tokens -d "$loginpayload" -k | jq -c -r .'accessToken')
  if [ -z "$sddcm_token" ] || [ "$sddcm_token" == "null" ]; then
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, sddcm: sddcm_token is undefined or null" "${log_file}" "${slack_webhook}" "${google_webhook}"
    exit 255
  fi
  #
  # find avi bundle id
  #
  avi_bundle_id=$(curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X GET "https://$sddcm/v1/bundles" | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .id')
  if [[ $(curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X GET "https://$sddcm/v1/bundles" | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .downloadStatus') != "SUCCESSFUL" ]]; then
    curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X PATCH "https://$sddcm/v1/bundles/${avi_bundle_id}" -d '{"bundleDownloadSpec": {"downloadNow": true}}'
    sleep 120
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, sddcm: waiting 120 seconds" "${log_file}" "" ""
  fi
  #
  # verify avi bundle is downloaded
  #
  retry_download=30 ; pause_download=10 ; attempt_download=1
  while true
  do
    if [[ $(curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X GET "https://$sddcm/v1/bundles" | jq -c -r --arg arg "NSX_ALB" '.elements[] | select(.components[0].description == $arg) | .downloadStatus') == "SUCCESSFUL" ]]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, sddcm: Avi bundle downloaded" "${log_file}" "${slack_webhook}" "${google_webhook}"
      break
    fi
    if [ $attempt_download -eq $retry_download ]; then
      log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, sddcm: Avi bundle is not downloaded after ${attempt_download} attempts of ${pause_download} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
      exit 100
    fi
    sleep ${pause_download}
    ((attempt_download++))
  done
  #
  # deploy Avi cluster or standalone and patching sddcm only for standalone single node
  #
  nsx_id=$(curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X GET "https://$sddcm/v1/domains" | jq -c -r '.elements[0].nsxtCluster.id')
  if [[ $(echo ${ips_avi} | jq -c -r '. | length') -eq 3 ]]; then
    curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X POST "https://$sddcm/v1/alb-clusters" \
      -d '{"adminPassword": "'${generic_password}'",
           "bundleId": "'${avi_bundle_id}'",
           "clusterFqdn": "'${basename_sddc}-avi.${domain}'",
           "clusterName": "cluster-1",
           "formFactor": "SMALL",
           "nodes": [{"ipAddress": "'$(echo ${ips_avi} | jq -c -r '.[0]')'"}, {"ipAddress": "'$(echo ${ips_avi} | jq -c -r '.[1]')'"}, {"ipAddress": "'$(echo ${ips_avi} | jq -c -r '.[2]')'"}],
           "nsxIds": ["'${nsx_id}'"],
           "vcfopsAdminPassword": "'${generic_password}'"
          }'
  else
    /bin/bash /home/ubuntu/sddc-manager/patch_sddcm.sh -u vcf -P ''${generic_password}'' -r ''${generic_password}'' -H ${basename_sddc}-sddcm.${domain}
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, sddcm: waiting 180 seconds" "${log_file}" "" ""
    sleep 180
    curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X POST "https://$sddcm/v1/alb-clusters" \
      -d '{"adminPassword": "'${generic_password}'",
           "bundleId": "'${avi_bundle_id}'",
           "clusterFqdn": "'${basename_sddc}-avi.${domain}'",
           "clusterName": "cluster-1",
           "formFactor": "SMALL",
           "nodes": [{"ipAddress": "'$(echo ${ips_avi} | jq -c -r '.[0]')'"}],
           "nsxIds": ["'${nsx_id}'"],
           "vcfopsAdminPassword": "'${generic_password}'"
          }'
    sleep 1800
    log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, sddcm: waiting 1800 seconds" "${log_file}" "" ""
    sddcm_token=$(curl -s -H 'Content-Type:application/json' https://$sddcm/v1/tokens -d "$loginpayload" -k | jq -c -r .'accessToken')
    retry_download=60 ; pause_download=10 ; attempt_download=1
    while true
    do
      if [[ $(curl -s -k -H "Authorization: Bearer $sddcm_token" -H "Content-Type: application/json" -X GET "https://$sddcm/v1/alb-clusters" | jq -c -r '.elements[0].deploymentStatus') == "ACTIVE" ]]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, sddcm: Avi ctrl deployed" "${log_file}" "${slack_webhook}" "${google_webhook}"
        break
      fi
      if [ $attempt_download -eq $retry_download ]; then
        log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}, sddcm: Avi ctrl deployed is not deployed after ${attempt_download} attempts of ${pause_download} seconds" "${log_file}" "${slack_webhook}" "${google_webhook}"
        exit 100
      fi
      sleep ${pause_download}
      ((attempt_download++))
  done
  fi
else
  log_message "$(date "+%Y-%m-%d,%H:%M:%S"), nested-${basename_sddc}: Avi ctrl binary not deployed manually because of VCF version: ${vcf_version_two_digit}" "${log_file}" "${slack_webhook}" "${google_webhook}"
fi
#
#
#
touch ${resultFile}