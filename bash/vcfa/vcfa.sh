vcfa_api () {
  #
  fqdn_vcfa=${1}
  password=${2}
  vcfa_api_endpoint=${3}
  http_method=${4}
  json_data=${5}
  retry=${6}
  pause=${7}
  #
  vcfa_api_state="FAIL"
  token=$(curl -s -i -k --location https://${fqdn_vcfa}/cloudapi/1.0.0/sessions/provider --header 'Accept: application/json;version=40.0' --header "Authorization: Basic $(echo -n 'admin@system:'${password}'' | base64)" -X POST | awk -v 'IGNORECASE=1' '/x-vmware-vcloud-access-token:/ {print $2}' | tr -d '\r')
  #
  attempt=0
  while true ; do
    response=$(curl -k -s -X ${http_method} --write-out "\n%{http_code}" -H 'accept: application/json;version=9.0.0' -H "Content-Type: application/json" -H "Authorization: Bearer ${token}" -d "${json_data}" --location https://${fqdn_vcfa}/${vcfa_api_endpoint})
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ $response_code == 2[0-9][0-9] ]] ; then
      vcfa_api_state="SUCCESS"
      break
    else
      echo "  Retrying HTTP ${http_method} API call to https://${fqdn_vcfa}/${vcfa_api_endpoint}, http response code: ${response_code}, attempt: ${attempt}"
    fi
    if [ ${attempt} -eq ${retry} ]; then
      echo "  FAILED HTTP ${http_method} API call to https://${fqdn_vcfa}/${vcfa_api_endpoint}, response code was: ${response_code}"
      echo "${response_body}"
      break
    fi
    sleep ${pause}
    ((attempt++))
  done
}