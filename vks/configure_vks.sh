#!/bin/bash
#
jsonFile="${1}"
resultFile="${2}"
rm -f ${resultFile}
source /home/ubuntu/bash/variables.sh
source /home/ubuntu/bash/log_message.sh
source /home/ubuntu/bash/vcenter/vcenter_api.sh
#
# Retrieve API server cluster endpoint
#
token=$(/bin/bash /home/ubuntu/bash/vcenter/create_vcenter_api_session.sh "${vsphere_nested_username}" "${ssoDomain}" "${generic_password}" "${vcsa_fqdn}")
vcenter_api 3 3 "GET" $token '' "${vcsa_fqdn}" "api/vcenter/namespace-management/clusters"
cluster_id=$(echo $response_body | jq -c -r .[0].cluster)
json_output_file="/home/ubuntu/vcenter/api_server_cluster_endpoint.json"
vcenter_api 3 3 "GET" $token '' ${vcsa_fqdn} "api/vcenter/namespace-management/clusters/${cluster_id}"
api_server_cluster_endpoint=$(echo $response_body | jq -c -r .api_server_cluster_endpoint)
if [ -z "${api_server_cluster_endpoint}" ] ; then exit 255 ; fi
echo '{"api_server_cluster_endpoint": "'${api_server_cluster_endpoint}'"}' | tee ${json_output_file}
#
# to be resumed.
#
export VCF_CLI_VSPHERE_PASSWORD=xxx
vcf-cli-linux_amd64 context create sup-admin-01 --username administrator@vsphere.local --endpoint=192.168.240.4 --insecure-skip-tls-verify