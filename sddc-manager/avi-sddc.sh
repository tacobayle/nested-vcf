#!/bin/bash
#
jsonFile="${1}"
resultFile="${0%.*}.done"
log_file="${0%.*}.log"
touch ${log_file}
source /home/ubuntu/bash/variables.sh


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

sddcm="${basename_sddc}-sddc-manager.${domain}"
sddcmuser="${vsphere_nested_username}@${ssoDomain}"
sddcmpass=''${generic_password}''
export SSHPASS='${generic_password}'
pvcfile="/home/ubuntu/sddc-manager/pvc.json"
sigfile="/home/ubuntu/sddc-manager/pvc.sig"
ovapath="/home/ubuntu/sddc-manager/$(basename ${avi_ova_url_sddc_manager})"
avi_product_version="${avi_product_version_sddc_manager}"
log "INFO" "Creating folder to store pvc files and Avi binary"
sshpass -e ssh -o StrictHostKeyChecking=no vcf@$sddcm 'mkdir -p /home/vcf/avi'
log "INFO" "Copying pvc files and Avi binary to SDDC manager"
sshpass -e scp -o StrictHostKeyChecking=no $pvcfile $sigfile $ovapath vcf@$sddcm:/home/vcf/avi
loginpayload=$(printf '{"username" : "%s","password": "%s"}' $sddcmuser $sddcmpass)
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