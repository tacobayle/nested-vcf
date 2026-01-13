vcenter_api () {
  # $1 is the amount of retry
  # $2 is the time to pause between each retry
  # $3 type of HTTP method (GET, POST, PUT, PATCH)
  # $4 vCenter token
  # $5 http data
  # $6 vCenter FQDN
  # $7 API endpoint
  retry=$1
  pause=$2
  attempt=0
  # echo "HTTP $3 API call to https://$6/$7"
  while true ; do
    response=$(curl -k -s -X $3 --write-out "\n%{http_code}" -H "vmware-api-session-id: $4" -H "Content-Type: application/json" -d "$5" https://$6/$7)
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
    if [[ $response_code == 2[0-9][0-9] ]] ; then
      echo "  HTTP $3 API call to https://$6/$7 was successful"
      break
    else
      echo "  Retrying HTTP $3 API call to https://$6/$7, http response code: $response_code, attempt: $attempt"
    fi
    if [ $attempt -eq $retry ]; then
      echo "  FAILED HTTP $3 API call to https://$6/$7, response code was: $response_code"
      echo "$response_body"
      exit 255
    fi
    sleep $pause
    ((attempt++))
  done
}