#!/bin/bash
#
# $1 is the username
# $2 is the SSO domain
# $3 is the password
# $4 is the vCenter FQDN
#
#
# Tested with vSphere6.5, vSphere7 and vSphere8
#
retry=10
pause=20
attempt=0
url_vpshere6_5="rest/com/vmware/cis/session"
url_vpshere="api/session"
url=$url_vpshere
while true ; do
  if [[ $2 == '' ]]; then
    response=$(curl -k -s --write-out "\n%{http_code}" -X POST -u "$1:$3" https://$4/$url -H "Content-Type: application/json")
  else
    response=$(curl -k -s --write-out "\n%{http_code}" -X POST -u "$1@$2:$3" https://$4/$url -H "Content-Type: application/json")
  fi
  http_code=$(tail -n1 <<< "$response")
  content=$(sed '$ d' <<< "$response")
  if [[ $http_code == 20[0-9] ]] ; then
    if [[ $url == $url_vpshere6_5 ]] ; then
      token=$(echo $content | jq .value | tr -d \")
      if [[ ${#token} -eq 32 ]] ; then
        echo $token
        break
      fi
    fi
    if [[ $url == $url_vpshere ]] ; then
      token=$(echo $content | tr -d \")
      if [[ ${#token} -eq 32 ]] ; then
        echo $token
        break
      fi
    fi
  fi
  if [ $attempt -eq $retry ]; then
    echo "  FAILED to create vCenter API session failed, http_response_code: $http_code"
    exit 255
  fi
  if [[ $url == $url_vpshere ]] ; then
    url=$url_vpshere6_5
  else
    url=$url_vpshere
  fi
  sleep $pause
  ((attempt++))
done
