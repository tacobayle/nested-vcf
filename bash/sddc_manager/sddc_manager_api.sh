sddc_manager_api () {
  # $1 is the amount of retry
  # $2 is the time to pause between each retry
  # $3 type of HTTP method (GET, POST, PUT, PATCH)
  # $4 http data
  # $5 SDDC Manager IP or FQDN
  # $6 API endpoint
  # $7 Bearer
  retry=$1
  pause=$2
  attempt=0
  echo "HTTP ${3} API call to https://${5}/${6}"
  while true ; do
    response=$(curl -k -s -X ${3} --write-out "\n%{http_code}" -H 'Content-Type: application/json' -H 'Accept: application/json' -H "Authorization: Bearer ${7}" -d "${4}" https://${5}/${6})
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ ${response_code} == 2[0-9][0-9] ]] ; then
      echo "  HTTP ${3} API call to https://${5}/${6} was successful"
      break
    else
      echo "  Retrying HTTP ${3} API call to https://${5}/${6}, http response code: ${response_code}, attempt: ${attempt}"
    fi
    if [ ${attempt} -eq ${retry} ]; then
      echo "  FAILED HTTP ${3} API call to https://${5}/${6}, response code was: ${response_code}"
      echo "${response_body}"
      exit
    fi
    sleep ${pause}
    ((attempt++))
  done
}