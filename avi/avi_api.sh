avi_api () {
  # $1 is the amount of retry
  # $2 is the time to pause between each retry
  # $3 type of HTTP method (GET, POST, PUT, PATCH, DELETE)
  # $4 cookie file
  # $5 http header X-CSRFToken:
  # $6 http header X-Avi-Tenant:
  # $7 http header X-Avi-Version:
  # $8 http data
  # $9 ALB Controller IP
  # $10 API endpoint
  retry=$1
  pause=$2
  attempt=0
  echo "  HTTP ${3} API call to https://${9}/${10}"
  while true ; do
    response=$(curl -k -s -X "${3}" --write-out "\n\n%{http_code}" -b "${4}" -H "X-CSRFToken: ${5}" -H "X-Avi-Tenant: ${6}" -H "X-Avi-Version: ${7}" -H "Content-Type: application/json" -H "Referer: https://${9}" -d "${8}" https://${9}/${10})
#    sleep 2
    response_body=$(sed '$ d' <<< "$response")
    response_code=$(tail -n1 <<< "$response")
#    echo $response_body
#    echo $response_code
    if [[ $response_code == 2[0-9][0-9] ]] ; then
      echo "    API call was successful"
      break
    else
      echo "    API call, http response code: $response_code, attempt: $attempt"
    fi
    if [ $attempt -eq $retry ]; then
      echo "    FAILED HTTP ${3} API call to https://${9}/${10}, response code was: $response_code"
      echo "$response_body"
      exit 255
    fi
    sleep $pause
    ((attempt++))
  done
}