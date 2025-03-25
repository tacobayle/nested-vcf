#!/bin/bash
#
# $1 is the username
# $2 is the password
# $3 is the sddc_manager FQDN or IP
# $4 is the file to store the json result
#
retry=3
pause=5
attempt=0
while true ; do
  response=$(curl -k -s --write-out "\n%{http_code}" -X POST -d '{"username" : "'${1}'", "password" : "'${2}'"}' https://${3}/v1/tokens -H "Content-Type: application/json" -H "Accept: application/json")
  http_code=$(tail -n1 <<< "$response")
  content=$(sed '$ d' <<< "$response")
  if [[ $http_code == 200 ]] ; then
    echo ${content} | jq . -c -r | tee ${4}
    break
  fi
  if [ ${attempt} -eq ${retry} ]; then
    echo "FAILED to get SDDC Manager API token after ${attempt} attempts of ${pause} seconds, http_response_code: ${http_code}"
    exit
  fi
  sleep ${pause}
  ((attempt++))
done